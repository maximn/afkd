#!/bin/bash
set -e

# Every directory this script writes into, created up front. Which of them
# already exist depends on what the deployment mounts where: /root/.config is a
# volume in production and absent on a bare `docker run`, and /root/.ssh comes
# from the image today but would be shadowed by a volume mounted over it. A
# missing directory turns one of the redirects below into a fatal error under
# `set -e`, and an entrypoint that dies never reaches `exec sshd`.
mkdir -p /root/.config /root/.claude /root/.ssh /root/dev

# Persist SSH host keys across redeployments.
if [ ! -f /root/.config/ssh_host_ed25519_key ]; then
  ssh-keygen -A
  cp /etc/ssh/ssh_host_*_key* /root/.config/
else
  cp /root/.config/ssh_host_*_key* /etc/ssh/
fi

# Claude Code config symlink
ln -sf /root/.claude/.claude.json /root/.claude.json

# SSH authorized keys. Password auth is off, so no keys means no way in and a
# container that looks healthy while being unreachable. Fail loudly instead.
if [ -z "${SSH_PUBLIC_KEYS}" ]; then
  echo "error: SSH_PUBLIC_KEYS is empty - nothing could log in. Set it to one public key per line." >&2
  exit 1
fi
printf '%s\n' "${SSH_PUBLIC_KEYS}" > /root/.ssh/authorized_keys
chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys

# Git config
git config --global user.name "${GIT_USER_NAME:-Novak}"
git config --global user.email "${GIT_USER_EMAIL:-your@email.com}"

# GitHub SSH key (via GITHUB_SSH_KEY env var)
if [ -n "${GITHUB_SSH_KEY}" ]; then
  # This has flip-flopped between base64 and raw four times (see 246779d,
  # 68e6a7f, f39b1d7): each form works in one Coolify setup and breaks the
  # other, and the docs have been out of sync with the code since 45350b9.
  # Accept both and stop guessing. CRs are stripped because Coolify can hand
  # back CRLF, which makes openssl fail with an opaque libcrypto error (ce7058e).
  # umask so the key is never briefly world-readable between write and chmod.
  if printf '%s' "${GITHUB_SSH_KEY}" | grep -q -- '-----BEGIN'; then
    (umask 077; printf '%s\n' "${GITHUB_SSH_KEY}" | sed 's/\r$//' > /root/.ssh/github_ed25519)
  else
    (umask 077; printf '%s' "${GITHUB_SSH_KEY}" | tr -d '\r\n' | base64 -d > /root/.ssh/github_ed25519 2>/dev/null) || true
  fi

  # A bad key must not stop sshd from coming up - you need a way in to fix it.
  if grep -q -- '-----BEGIN' /root/.ssh/github_ed25519 2>/dev/null; then
    # ssh rejects a key file whose last line has no trailing newline
    if [ -n "$(tail -c1 /root/.ssh/github_ed25519)" ]; then
      echo >> /root/.ssh/github_ed25519
    fi
    chmod 600 /root/.ssh/github_ed25519
    gh_key_ok=1
  else
    echo "warning: GITHUB_SSH_KEY is neither a PEM private key nor base64-encoded one; skipping GitHub SSH setup" >&2
    rm -f /root/.ssh/github_ed25519
    gh_key_ok=0
  fi
fi

if [ "${gh_key_ok:-0}" = "1" ]; then
  # Unguarded this is fatal under `set -e`: ssh-keyscan exits 1 when github.com
  # does not resolve, which happens on any boot that wins a race with the
  # network. Losing known_hosts costs you git-over-ssh; aborting here costs you
  # sshd, and with it every way back into the box.
  ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts 2>/dev/null \
    || echo "warning: could not reach github.com to record its host key; git over ssh may prompt" >&2
  cat > /root/.ssh/config <<'SSHCFG'
Host github.com
  IdentityFile /root/.ssh/github_ed25519
  IdentitiesOnly yes
SSHCFG
  chmod 600 /root/.ssh/config
fi

# Forward container env vars to SSH sessions. Values can hold spaces, quotes
# or newlines (an API key with a $, a multiline token), so each one is emitted
# with %q rather than by line-parsing `env` -- one unquoted value would
# otherwise corrupt itself and every export after it. bash's %q output is
# valid zsh, including the $'...' form it uses for newlines.
#
# Written under a umask like the GitHub key above: this file holds GH_TOKEN and
# every agent API key, and a plain redirect creates it 0644 and leaves it that
# way until the chmod. The chmod stays for the case where the file already
# exists, since a redirect truncates it without touching its mode.
(umask 077
  for name in GH_TOKEN OPENAI_API_KEY ANTHROPIC_API_KEY \
              "${!CODEX_@}" "${!CLAUDE_@}"; do
    [ -n "${!name+x}" ] || continue
    printf 'export %s=%q\n' "$name" "${!name}"
  done > /root/.zshenv
)
chmod 600 /root/.zshenv

# Claude Code default settings
if [ ! -f /root/.claude/settings.json ]; then
  cat > /root/.claude/settings.json <<'SETTINGS'
{
  "permissions": {
    "allow": ["Bash", "Read", "Edit", "Write", "Grep", "Glob", "WebSearch"],
    "deny": ["Bash(rm -rf:*)", "Bash(git push --force:*)", "Bash(git reset --hard:*)"],
    "defaultMode": "auto"
  },
  "alwaysThinkingEnabled": true
}
SETTINGS
fi

# Agent lifecycle notifications. Merged on every boot rather than seeded once,
# so the wiring stays declarative and follows NTFY_URL changes. This is what
# lets a detached session page a phone instead of needing someone attached.
if [ -n "${NTFY_URL}" ]; then
  ntfy_auth=""
  if [ -n "${NTFY_TOKEN}" ]; then
    ntfy_auth="-H \"Authorization: Bearer ${NTFY_TOKEN}\""
  fi
  needs_you="jq -r '.message // \"needs attention\"' | curl -s ${ntfy_auth} -H 'Title: Claude needs you' -H 'Priority: high' -H 'Tags: warning' --data-binary @- '${NTFY_URL}'"
  finished="curl -s ${ntfy_auth} -H 'Title: Claude finished' -H 'Tags: white_check_mark' -d 'turn complete' '${NTFY_URL}'"

  # A notification-config failure must never stop sshd from coming up.
  if jq --arg needs_you "${needs_you}" --arg finished "${finished}" \
       '.hooks.Notification = [{"hooks":[{"type":"command","command":$needs_you}]}]
        | .hooks.Stop       = [{"hooks":[{"type":"command","command":$finished}]}]' \
       /root/.claude/settings.json > /tmp/settings.json 2>/dev/null; then
    mv /tmp/settings.json /root/.claude/settings.json
  else
    echo "warning: could not merge notification hooks into settings.json" >&2
    rm -f /tmp/settings.json
  fi
fi

# nofile is raised through Coolify's Custom Docker Options, a hand-pasted field
# that is lost whenever the app is recreated. A JetBrains backend then hits
# EMFILE partway through indexing while the healthcheck (sshd is up) stays
# green, so print the limit actually in effect where the container log shows it.
fd_limit="$(ulimit -n)"
case "$fd_limit" in
  '' | *[!0-9]*) echo "nofile limit: ${fd_limit}" ;;  # "unlimited"
  *)
    if [ "$fd_limit" -lt 4096 ]; then
      echo "warning: nofile limit is ${fd_limit} - too low for a JetBrains backend. Check Custom Docker Options." >&2
    else
      echo "nofile limit: ${fd_limit}"
    fi
    ;;
esac

exec /usr/sbin/sshd -D
