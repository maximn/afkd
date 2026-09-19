#!/bin/bash
set -e

# Persist SSH host keys across redeployments
if [ ! -f /root/.config/ssh_host_ed25519_key ]; then
  ssh-keygen -A
  cp /etc/ssh/ssh_host_*_key* /root/.config/
else
  cp /root/.config/ssh_host_*_key* /etc/ssh/
fi

# Claude Code config symlink
ln -sf /root/.claude/.claude.json /root/.claude.json

# SSH authorized keys
echo "${SSH_PUBLIC_KEYS}" > /root/.ssh/authorized_keys
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
  ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts 2>/dev/null
  cat > /root/.ssh/config <<'SSHCFG'
Host github.com
  IdentityFile /root/.ssh/github_ed25519
  IdentitiesOnly yes
SSHCFG
  chmod 600 /root/.ssh/config
fi

# Forward container env vars to SSH sessions
env | grep -E '^(GH_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY|CODEX_|CLAUDE_|BROWSERLESS_)' \
  | sed 's/^/export /' > /root/.zshenv

# Claude Code default settings
mkdir -p /root/.claude
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

# Playwright MCP config (always updated to track BROWSERLESS_URL changes)
if [ -n "${BROWSERLESS_URL}" ]; then
  jq --arg url "${BROWSERLESS_URL}" '.mcpServers.playwright = {
    "type": "stdio",
    "command": "playwright-mcp",
    "args": ["--cdp-endpoint", $url],
    "env": {}
  }' /root/.claude/.claude.json > /tmp/claude.json && mv /tmp/claude.json /root/.claude/.claude.json
fi

# Ensure ~/dev exists
mkdir -p /root/dev

exec /usr/sbin/sshd -D
