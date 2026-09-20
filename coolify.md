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
| `*-cache` | `/root/.cache` | Regenerable-but-expensive caches: npm (`NPM_CONFIG_CACHE` points here), JetBrains IDE backend and project indexes |

Size the cache volume with headroom — a JetBrains backend is ~1.5 GB before
indexes. Nothing in it is worth backing up, but a *full* volume fails at write
time in the middle of work, which is worse than a cold cache. Caches also no
longer reset on redeploy, so a corrupt one has to be cleared by hand with
`rm -rf /root/.cache/<subdir>`.

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
ssh-keygen -R '[46.224.159.50]:2222'
```

## Custom Docker Options

```
--cap-add SYS_ADMIN --device=/dev/fuse --security-opt apparmor:unconfined --ulimit nofile=65536:65536
```

1024 descriptors is fine for shell sessions but not for a JetBrains backend,
which opens far more than that while indexing.

## Remote IDE (JetBrains)

Connecting WebStorm over SSH is not a terminal session with a file browser: the
backend is a full IDE running on the box, and the local client is close to a
rendering surface. That is why three things here exist — the X/font libraries in
the `Dockerfile`, the raised `nofile`, and the `/root/.cache` volume.

Two limits live on the Hetzner host rather than in the container, so they can't
be fixed from this repo:

- **Swap.** The box has 4 GB and no swap. A backend indexing a large JS project
  next to running Claude sessions will get OOM-killed. Add a swapfile on the host.
- **inotify watches.** `fs.inotify.max_user_watches` is at the host default
  (~29.5k), which is low for JS projects. Raise it via `/etc/sysctl.d/` on the host.

After connecting, set the backend heap to ~2048 MB (**Help → Change Memory
Settings**) and mark `node_modules` and build output as excluded — indexing them
is what will exhaust this machine.

