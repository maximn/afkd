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
  echo "${GITHUB_SSH_KEY}" | base64 -d > /root/.ssh/github_ed25519
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
