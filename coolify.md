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
| `GITHUB_SSH_KEY` | No | **Base64-encoded** private SSH key for GitHub access. Generate with `base64 < ~/.ssh/remote-claude \| tr -d '\n'`. Needed because some GitHub orgs restrict fine-grained PATs (e.g. max token lifetime), so `GH_TOKEN` alone can't clone their repos. Add the matching public key to [GitHub SSH keys](https://github.com/settings/ssh/new) |

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

## Custom Docker Options

```
--cap-add SYS_ADMIN --device=/dev/fuse --security-opt apparmor:unconfined --ulimit nofile=1024:1024
```

