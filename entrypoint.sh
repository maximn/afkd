#!/bin/bash
# -u, because every guard in this file keys off an environment variable and a
# typo'd name reads as "unset": the guard then silently skips the thing it was
# written to protect. Every genuinely optional input below is spelled ${VAR:-}
# to say out loud that it may be absent, which makes a bare ${TYPO} an error
# rather than an empty string.
#
# -o pipefail changes nothing here today -- the pipelines that remain are
# either an `if` condition or explicitly guarded -- and is set so that the next
# pipeline added does not quietly report only its last command. Same reasoning
# as the SHELL line in the Dockerfile.
set -euo pipefail

# Every directory this script writes into, created up front. Which of them
# already exist depends on what the deployment mounts where: /root/.config is a
# volume in production and absent on a bare `docker run`. A missing directory
# turns one of the redirects below into a fatal error under `set -e`, and an
# entrypoint that dies never reaches `exec sshd`.
mkdir -p /root/.config /root/.claude /root/dev

# Everything the deployment hands over at boot -- forwarded tokens, the GitHub
# key -- is written here rather than into home. It is rebuilt from the
# environment on every boot, so unsetting a value on the deployment removes it
# from the box, and home (a volume, which keeps whatever lands in it) never
# holds a secret it did not put there itself.
RUNTIME_DIR=/run/remote-claude
install -d -m 700 "$RUNTIME_DIR"

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
if [ -z "${SSH_PUBLIC_KEYS:-}" ]; then
  echo "error: SSH_PUBLIC_KEYS is empty - nothing could log in. Set it to one public key per line." >&2
  exit 1
fi
# Root-owned and outside home, the only file sshd reads keys from
# (AuthorizedKeysFile in the drop-in). An authorized_keys in home would
# outlive the key's removal from SSH_PUBLIC_KEYS for as long as the volume
# under it does.
install -d -m 755 /etc/ssh/authorized_keys
(umask 022; printf '%s\n' "${SSH_PUBLIC_KEYS}" > /etc/ssh/authorized_keys/root)
chmod 644 /etc/ssh/authorized_keys/root

# Git identity. Deliberately no fallback: these used to default to the name and
# email of this repo's author, so every deployment but one committed under an
# identity that had never touched the code -- silently, which is how a wrong
# author ends up in history and stays there. Unset is the better failure:
# git refuses to commit and prints exactly what to set.
#
# Warned about at boot rather than exited on, because it costs you a commit,
# not a way into the box.
#
# System-level, in /etc/gitconfig: the identity belongs to the deployment, a
# ~/.gitconfig of the user's own still overrides it, and nothing is written
# into home.
if [ -n "${GIT_USER_NAME:-}" ]; then
  git config --system user.name "${GIT_USER_NAME}"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
  git config --system user.email "${GIT_USER_EMAIL}"
fi
if [ -z "${GIT_USER_NAME:-}" ] || [ -z "${GIT_USER_EMAIL:-}" ]; then
  echo "warning: GIT_USER_NAME and/or GIT_USER_EMAIL are unset - git will refuse to commit until you set them." >&2
fi

# GitHub SSH key (via GITHUB_SSH_KEY env var). Under the runtime directory
# like every other secret, and wired in through the system ssh_config.d, so
# ~/.ssh/config stays the user's own.
GITHUB_KEY="$RUNTIME_DIR/github_ed25519"
if [ -n "${GITHUB_SSH_KEY:-}" ]; then
  # This has flip-flopped between base64 and raw four times (see 246779d,
  # 68e6a7f, f39b1d7): each form works in one Coolify setup and breaks the
  # other, and the docs have been out of sync with the code since 45350b9.
  # Accept both and stop guessing. CRs are stripped because Coolify can hand
  # back CRLF, which makes openssl fail with an opaque libcrypto error (ce7058e).
  # umask so the key is never briefly world-readable between write and chmod.
  # A bash substring match rather than `printf | grep -q`: under pipefail a
  # grep that finds its match and exits first leaves printf to die of SIGPIPE,
  # and the pipeline then reports 141 even though the key is a PEM. Only a key
  # larger than the pipe buffer could actually trigger it, which is not a key
  # anyone has -- but the match needs no subprocess either way.
  if [[ "${GITHUB_SSH_KEY}" == *"-----BEGIN"* ]]; then
    (umask 077; printf '%s\n' "${GITHUB_SSH_KEY}" | sed 's/\r$//' > "$GITHUB_KEY")
  else
    (umask 077; printf '%s' "${GITHUB_SSH_KEY}" | tr -d '\r\n' | base64 -d > "$GITHUB_KEY" 2>/dev/null) || true
  fi

  # A bad key must not stop sshd from coming up - you need a way in to fix it.
  if grep -q -- '-----BEGIN' "$GITHUB_KEY" 2>/dev/null; then
    # ssh rejects a key file whose last line has no trailing newline
    if [ -n "$(tail -c1 "$GITHUB_KEY")" ]; then
      echo >> "$GITHUB_KEY"
    fi
    chmod 600 "$GITHUB_KEY"
    gh_key_ok=1
  else
    echo "warning: GITHUB_SSH_KEY is neither a PEM private key nor base64-encoded one; skipping GitHub SSH setup" >&2
    rm -f "$GITHUB_KEY"
    gh_key_ok=0
  fi
fi

if [ "${gh_key_ok:-0}" = "1" ]; then
  # Unguarded this is fatal under `set -e`: ssh-keyscan exits 1 when github.com
  # does not resolve, which happens on any boot that wins a race with the
  # network. Losing known_hosts costs you git-over-ssh; aborting here costs you
  # sshd, and with it every way back into the box.
  ssh-keyscan -t ed25519 github.com >> /etc/ssh/ssh_known_hosts 2>/dev/null \
    || echo "warning: could not reach github.com to record its host key; git over ssh may prompt" >&2
  cat > /etc/ssh/ssh_config.d/50-github.conf <<SSHCFG
Host github.com
  IdentityFile ${GITHUB_KEY}
  IdentitiesOnly yes
SSHCFG
  chmod 644 /etc/ssh/ssh_config.d/50-github.conf
fi

# Forward container env vars to SSH sessions. Values can hold spaces, quotes
# or newlines (an API key with a $, a multiline token), so each one is emitted
# with %q rather than by line-parsing `env` -- one unquoted value would
# otherwise corrupt itself and every export after it. bash's %q output is
# valid zsh, including the $'...' form it uses for newlines.
#
# Sourced by /etc/zsh/remote-claude.zshenv, which every zsh reads. Written
# under a umask like the GitHub key above: this file holds GH_TOKEN and every
# agent API key, and a plain redirect creates it 0644 and leaves it that way
# until the chmod. The chmod stays for the case where the file already exists,
# since a redirect truncates it without touching its mode.
FORWARDED_ENV="$RUNTIME_DIR/env.zsh"
(umask 077
  for name in GH_TOKEN OPENAI_API_KEY ANTHROPIC_API_KEY \
              "${!CODEX_@}" "${!CLAUDE_@}"; do
    [ -n "${!name+x}" ] || continue
    printf 'export %s=%q\n' "$name" "${!name}"
  done > "$FORWARDED_ENV"
)
chmod 600 "$FORWARDED_ENV"

# Claude Code default settings: the user's own file, seeded once and never
# overwritten. Written under a umask because the user may well put a token in
# it, and older images merged the ntfy bearer token into it.
if [ ! -f /root/.claude/settings.json ]; then
  (umask 077
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
  )
fi

# Older images merged the ntfy hooks into the user's settings.json on every
# boot, bearer token and all. A volume written by one still carries them, and
# left in place they would fire alongside the managed copy below and keep the
# token in home. Only entries carrying this image's own ntfy titles are
# removed -- anything else under those events is the user's -- and the file is
# rewritten only when something was actually removed.
#
# The scratch file sits next to the target rather than in /tmp. /root/.claude
# is a volume, so /tmp is a different filesystem: `mv` across it is a copy
# that both loses atomicity and carries /tmp's mode onto the file. Same
# directory, same umask, real rename.
if [ -f /root/.claude/settings.json ] \
   && (umask 077
       jq 'if .hooks then
             .hooks |= (with_entries(.value |= (
                          map(.hooks |= map(select(((.command // "")
                                | test("Title: Claude (needs you|finished)")) | not)))
                          | map(select(.hooks | length > 0))))
                        | with_entries(select(.value | length > 0)))
             | if .hooks == {} then del(.hooks) else . end
           else . end' \
         /root/.claude/settings.json > /root/.claude/settings.json.tmp) 2>/dev/null \
   && ! cmp -s <(jq -S . /root/.claude/settings.json) <(jq -S . /root/.claude/settings.json.tmp); then
  mv /root/.claude/settings.json.tmp /root/.claude/settings.json
  echo "removed notification hooks an older image wrote into settings.json; they now come from managed settings"
fi
rm -f /root/.claude/settings.json.tmp

# Unconditional rather than at creation: a settings.json restored from a volume
# written by an older image is 0644 and may still have held the ntfy token.
chmod 600 /root/.claude/settings.json

# Agent lifecycle notifications. Rebuilt on every boot from NTFY_URL, so the
# wiring stays declarative. This is what lets a detached session page a phone
# instead of needing someone attached.
#
# They are the deployment's hooks, not the user's, so they go into Claude
# Code's managed settings: Claude merges them over whatever the user has,
# nothing in home is touched, and the token never lands on a volume.
#
# These two strings are commands Claude Code hands to a shell, so the URL and
# the token are shell-quoted with %q before being spliced in. They used to be
# wrapped in hand-written quotes -- the token in "..." and the URL in '...' --
# which holds only until a value contains the matching quote or, for the
# double-quoted one, anything the shell expands. All four of these ran as the
# agent's own user when the hook fired -- the first two without even needing a
# quote, since the shell expands those inside "...":
#
#   NTFY_TOKEN   tk`cmd`   |   tk$(cmd)   |   tk"; cmd;
#   NTFY_URL     https://host/topic'; cmd;
#
# jq's --arg does the JSON quoting, which is a different layer and never
# covered any of this.
NTFY_SETTINGS=/etc/claude-code/managed-settings.d/50-ntfy.json
if [ -n "${NTFY_URL:-}" ]; then
  printf -v ntfy_url_q '%q' "${NTFY_URL}"
  ntfy_auth=""
  if [ -n "${NTFY_TOKEN:-}" ]; then
    printf -v ntfy_header_q '%q' "Authorization: Bearer ${NTFY_TOKEN}"
    ntfy_auth="-H ${ntfy_header_q} "
  fi
  needs_you="jq -r '.message // \"needs attention\"' | curl -s ${ntfy_auth}-H 'Title: Claude needs you' -H 'Priority: high' -H 'Tags: warning' --data-binary @- ${ntfy_url_q}"
  finished="curl -s ${ntfy_auth}-H 'Title: Claude finished' -H 'Tags: white_check_mark' -d 'turn complete' ${ntfy_url_q}"

  # A notification-config failure must never stop sshd from coming up.
  mkdir -p "$(dirname "$NTFY_SETTINGS")"
  if ! (umask 077
        jq -n --arg needs_you "${needs_you}" --arg finished "${finished}" \
          '{hooks: {Notification: [{hooks: [{type: "command", command: $needs_you}]}],
                    Stop:         [{hooks: [{type: "command", command: $finished}]}]}}' \
          > "$NTFY_SETTINGS") 2>/dev/null; then
    echo "warning: could not write the notification hooks" >&2
    rm -f "$NTFY_SETTINGS"
  fi
  chmod 600 "$NTFY_SETTINGS" 2>/dev/null || true
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
