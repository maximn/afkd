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
  printf '%s\n' "${GITHUB_SSH_KEY}" > /root/.ssh/github_ed25519
  chmod 600 /root/.ssh/github_ed25519
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
