# Coolify Configuration

## Setup (New Application)

1. Create a new application from GitHub repo `maximn/remote-claude-code`
2. Branch: `main`, Build Pack: `Dockerfile`, Base Directory: `/`, Port: `22`
3. After creation, configure the sections below

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `SSH_PUBLIC_KEY` | Yes | Public SSH key for root access |
| `GIT_USER_NAME` | No | Git author name (default: Novak) |
| `GIT_USER_EMAIL` | No | Git author email |

## Ports

| Port | Mapping | Description |
|---|---|---|
| 22 | 2222:22 | SSH access |

## Persistent Storage (Volumes)

| Volume Name | Mount Path | Purpose |
|---|---|---|
| `*-workspace` | `/workspace` | Working directory |
| `*-claude-config` | `/root/.claude` | Claude Code auth, settings, sessions |
| `*-dotconfig` | `/root/.config` | App configs (gh, starship, etc.) |
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

## Custom Docker Options

```
--cap-add SYS_ADMIN --device=/dev/fuse --security-opt apparmor:unconfined --ulimit nofile=1024:1024
```

## SSH Config (local machine)

```
Host cc
    HostName <server-ip>
    Port 2222
    User root
    IdentityFile ~/.ssh/id_ed25519
```
