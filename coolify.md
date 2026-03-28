# Coolify Configuration

## Setup (New Application)

1. Create a new application from GitHub repo `maximn/remote-claude-code`
2. Branch: `main`, Build Pack: `Dockerfile`, Base Directory: `/`, Port: `22`
3. After creation, configure the sections below

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `SSH_PUBLIC_KEYS` | Yes | Multiline — one SSH public key per line (`cat ~/.ssh/id_ed25519.pub`) |
| `GIT_USER_NAME` | No | Git author name (default: Novak) |
| `GIT_USER_EMAIL` | No | Git author email |
| `GITHUB_SSH_KEY` | No | Private SSH key for GitHub access (`cat ~/.ssh/remote-claude`). Set as **multiline** in Coolify. Needed because some GitHub orgs restrict fine-grained PATs (e.g. max token lifetime), so `GH_TOKEN` alone can't clone their repos. Add the matching public key to [GitHub SSH keys](https://github.com/settings/ssh/new) |
| `BROWSERLESS_URL` | No | CDP WebSocket URL of Browserless service (see [Browser Service](#browser-service-browserless) section) |

## Ports

| Setting | Value |
|---|---|
| Port (Exposes) | `22` |
| Port Mappings | `2222:22` |

## Persistent Storage (Volumes)

| Volume Name | Mount Path | Purpose |
|---|---|---|
| `*-workspace` | `/workspace` | Working directory |
| `*-claude-config` | `/root/.claude` | Claude Code auth, settings, sessions |
| `*-dotconfig` | `/root/.config` | App configs (gh, starship, etc.) |
| `*-codex` | `/root/.codex` | Codex CLI auth and settings |
| `*-dev` | `/root/dev` | Development projects |

## Healthcheck

| Setting | Value |
|---|---|
| Type | CMD |
| Command | `pgrep sshd` |
| Interval | 30s |
| Timeout | 30s |
| Retries | 3 |
| Start Period | 30s |

## Notes

SSH host keys are persisted in the `/root/.config` volume. After a fresh setup, accept the key once. If you ever recreate the volumes, clear the old key locally:
```
ssh-keygen -R '[<server-ip>]:2222'
```

## Browser Service (Browserless)

A shared headless browser runs as a separate Coolify service, connected via CDP.

### Setup

1. In Coolify → **New Service** → select **Browserless** template → deploy
2. Both services must share a Docker network. In Coolify, add the Browserless service to the same network as remote-claude (the `coolify` network), or connect manually:
   ```
   docker network connect coolify <browserless-container-name>
   ```
3. Set `BROWSERLESS_URL` env var on remote-claude to `ws://<browserless-hostname>:3000`
4. Claude Code uses Playwright MCP to connect — config is injected automatically on boot

## Custom Docker Options

```
--cap-add SYS_ADMIN --device=/dev/fuse --security-opt apparmor:unconfined --ulimit nofile=1024:1024
```

