# Coolify Configuration

## Setup (New Application)

1. Create a new application from GitHub repo `maximn/remote-claude-code`
2. Branch: `main`, Build Pack: `Dockerfile`, Base Directory: `/`, Port: `22`
3. After creation, configure the sections below

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `SSH_PUBLIC_KEYS` | Yes | Multiline — one SSH public key per line (`cat ~/.ssh/id_ed25519.pub`) |
| `GIT_USER_NAME` | Recommended | Git author name. No default — unset means git refuses to commit until you set it on the box |
| `GIT_USER_EMAIL` | Recommended | Git author email. Same as above |
| `GITHUB_SSH_KEY` | No | Private SSH key for GitHub access, either a raw PEM key or base64-encoded (`base64 < ~/.ssh/remote-claude \| tr -d '\n'`) — the entrypoint detects which. Needed because some GitHub orgs restrict fine-grained PATs (e.g. max token lifetime), so `GH_TOKEN` alone can't clone their repos. Add the matching public key to [GitHub SSH keys](https://github.com/settings/ssh/new) |

`.env.example` at the repo root lists every variable the image reads, including
the agent credentials and the optional ntfy notifications not shown here.

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
| `*-cache` | `/root/.cache` | Regenerable-but-expensive caches: npm (pointed here by the image's global npmrc), JetBrains IDE backend and project indexes |
| `*-localshare` | `/root/.local/share` | JetBrains backend plugins and per-project data |

Size the cache volume with headroom — a JetBrains backend is ~1.5 GB before
indexes. Nothing in it is worth backing up, but a *full* volume fails at write
time in the middle of work, which is worse than a cold cache. Caches also no
longer reset on redeploy, so a corrupt one has to be cleared by hand with
`rm -rf /root/.cache/<subdir>`.

`/root/.local/share` is a separate volume because JetBrains splits its state
three ways: settings land in `/root/.config`, the backend and its indexes in
`/root/.cache`, and installed plugins in `/root/.local/share`. Without the third
one, plugins disappear on redeploy while everything around them survives, which
reads as the IDE randomly breaking rather than as a missing volume.

## Healthcheck

Nothing to configure — the image ships its own `HEALTHCHECK` (`pgrep -x sshd`,
every 30s after a 30s grace period), so Coolify picks it up from the image and
so does anything else that runs the container. It used to exist only here, as
four fields to paste into the Coolify UI, which left a Compose or Kubernetes
deployment with no health signal at all -- and a box whose entrypoint died
before `exec sshd` looking no different from a working one.

## Notes

SSH host keys are persisted in the `/root/.config` volume. After a fresh setup, accept the key once. If you ever recreate the volumes, clear the old key locally:
```
ssh-keygen -R '[<server-ip>]:2222'
```

## Custom Docker Options

```
--ulimit nofile=65536:65536
```

1024 descriptors is fine for shell sessions but not for a JetBrains backend,
which opens far more than that while indexing.

This line also used to carry `--cap-add SYS_ADMIN --device=/dev/fuse
--security-opt apparmor:unconfined`. Those were for the Browserless/Playwright
wiring the image no longer installs; nothing left in it needs them, and they
were handing every logged-in session more of the host than the box has any use
for. Drop them from an existing deployment.

This field is not part of the image, so recreating the app in the Coolify UI
drops it and nothing fails visibly — the container is healthy and indexing dies
with EMFILE. The entrypoint prints `nofile limit: <n>` at boot, so check the
container log after a redeploy: anything below 4096 and the options above were
not applied.

## Remote IDE (JetBrains)

Connecting WebStorm over SSH is not a terminal session with a file browser: the
backend is a full IDE running on the box, and the local client is close to a
rendering surface. That is why four things here exist — the X/font libraries in
the `Dockerfile`, the raised `nofile`, and the `/root/.cache` and
`/root/.local/share` volumes.

Two limits live on the Hetzner host rather than in the container, so they can't
be fixed from this repo:

- **Swap.** The box has 4 GB and no swap. A backend indexing a large JS project
  next to running Claude sessions will get OOM-killed. Add a swapfile on the host.
- **inotify watches.** `fs.inotify.max_user_watches` is at the host default
  (~29.5k), which is low for JS projects. Raise it via `/etc/sysctl.d/` on the host.

After connecting, set the backend heap to ~2048 MB (**Help → Change Memory
Settings**) and mark `node_modules` and build output as excluded — indexing them
is what will exhaust this machine.

