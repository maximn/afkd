# Coolify Configuration

## Setup (New Application)

1. Create a new application from GitHub repo `maximn/remote-claude-code`
2. Branch: `main`, Build Pack: `Docker Compose`, Base Directory: `/`, Docker
   Compose Location: `/docker-compose.yaml`
3. Fill in the environment variables Coolify lists, then deploy

[docker-compose.yaml](docker-compose.yaml) carries the port, the volumes and
the fd limit, so there is nothing else to set by hand -- and nothing that
recreating the app in the UI can quietly drop.

## Environment Variables

Coolify reads the variables from the compose file and lists them under
Environment Variables. `SSH_PUBLIC_KEYS` is marked required, and Coolify will
not deploy while it is empty; the rest are optional and start out blank.

| Variable | Required | Description |
|---|---|---|
| `SSH_PUBLIC_KEYS` | Yes | Multiline — one SSH public key per line (`cat ~/.ssh/id_ed25519.pub`) |
| `GIT_USER_NAME` | Recommended | Git author name. No default — unset means git refuses to commit until you set it on the box |
| `GIT_USER_EMAIL` | Recommended | Git author email. Same as above |
| `GITHUB_SSH_KEY` | No | Private SSH key for GitHub access, either a raw PEM key or base64-encoded (`base64 < ~/.ssh/remote-claude \| tr -d '\n'`) — the entrypoint detects which. Needed because some GitHub orgs restrict fine-grained PATs (e.g. max token lifetime), so `GH_TOKEN` alone can't clone their repos. Add the matching public key to [GitHub SSH keys](https://github.com/settings/ssh/new) |

`.env.example` at the repo root lists every variable the image reads, including
the agent credentials and the optional ntfy notifications not shown here.

## Ports

SSH is published on host port `2222`. Set `SSH_PORT` to use another; it is
read by the compose file, not by the image.

## Persistent Storage (Volumes)

Declared in the compose file; Coolify names each one `<app uuid>_<name>`.

| Volume | Mount Path | Purpose |
|---|---|---|
| `home` | `/home/dev` | All of dev's home: agent auth, settings and sessions (`~/.claude`, `~/.claude.json`, `~/.codex`), app configs (`~/.config`), projects (`~/dev`), JetBrains plugins (`~/.local/share`), your own dotfiles |
| `cache` | `/home/dev/.cache` | Regenerable-but-expensive caches: npm (pointed here by `NPM_CONFIG_CACHE` in the image's zsh environment), mise downloads, JetBrains IDE backend and project indexes |
| `system` | `/var/lib/remote-claude` | The SSH host keys, kept out of home so dev cannot read them |

Home is one volume rather than one per directory. Anything a tool writes there
survives a redeploy, including the tools nobody thought to give a volume, and
the image keeps nothing of its own in home: its shell config, Node and the
agents live under `/etc`, `/usr` and `/opt`, so a long-lived home still picks
up every image change.

The cache is separate so it can be sized, and cleared, on its own. Size it with
headroom — a JetBrains backend is ~1.5 GB before indexes. Nothing in it is
worth backing up, but a *full* volume fails at write time in the middle of
work, which is worse than a cold cache. Caches don't reset on redeploy, so a
corrupt one has to be cleared by hand with `rm -rf ~/.cache/<subdir>`.

Docker seeds an empty volume from the image, so a fresh `home` starts as
dev's, with the skeleton dotfiles in it. Where that doesn't happen, the
entrypoint hands an empty home to dev itself. A home that dev doesn't own and
that already holds files is left alone, with a warning in the container log.

## Migrating from the root layout

Images before the `dev` user ran as root, with up to seven volumes under
`/root` and `/workspace` -- older deployments may have fewer -- and all of them
on the `Dockerfile` build pack. Do this move first, on that build pack, and
[move to Docker Compose](#moving-from-the-dockerfile-build-pack) after. It is a
one-off, and the old volumes stay untouched until you remove them yourself:

1. **Add the new volumes, and keep the old ones mounted.** Add `*-home` at
   `/home/dev` and `*-system` at `/var/lib/remote-claude`. If there is a
   `*-cache` at `/root/.cache`, change its mount path to `/home/dev/.cache`
   (the cache is reused, not copied); otherwise add one there. Leave
   whichever of `/root/.claude`, `/root/.config`, `/root/.codex`, `/root/dev`,
   `/root/.local/share` and `/workspace` you have where they are.
2. **Deploy.** The entrypoint adopts the SSH host keys from `/root/.config`,
   so the box comes back as the same host. A reused cache comes up owned by
   root, with a warning in the log; the next step fixes it.
3. **Log in as dev.** Root no longer logs in at all. Set `User dev` in your
   `~/.ssh/config` ([ssh.md](ssh.md)).
4. **Migrate:**
   ```bash
   sudo rcc-migrate --dry-run   # what it will copy
   sudo rcc-migrate
   ```
   It copies the old volumes into `~`, moves `.claude.json` up to
   `~/.claude.json`, re-keys Claude Code's per-project state from `/root/dev/…`
   to `~/dev/…`, and hands the reused cache to dev. It refuses to run twice
   unless you pass `--force`.
5. **Check** that `claude` and `codex` are still signed in, `gh auth status`
   passes, and `~/dev` holds your projects. Nothing in the image uses
   `/workspace`; copy anything you kept there into `~/dev` now.
6. **Remove the old mounts and redeploy:** `/root/.claude`, `/root/.config`,
   `/root/.codex`, `/root/dev`, `/root/.local/share` and `/workspace`. Coolify
   keeps the volumes themselves until you delete them, so keep them until the
   new box has run for a while.

## Healthcheck

Nothing to configure — the image ships its own `HEALTHCHECK` (`pgrep -x sshd`,
every 30s after a 30s grace period), so Coolify picks it up from the image and
so does anything else that runs the container. It used to exist only here, as
four fields to paste into the Coolify UI, which left a Compose or Kubernetes
deployment with no health signal at all -- and a box whose entrypoint died
before `exec sshd` looking no different from a working one.

## Notes

SSH host keys are persisted in the `system` volume. After a fresh setup, accept the key once. If you ever recreate that volume, clear the old key locally:
```
ssh-keygen -R '[<server-ip>]:2222'
```

## Moving from the Dockerfile build pack

Deployments before the compose file used the `Dockerfile` build pack, with the
port mapping, the volumes and `--ulimit nofile=65536:65536` set by hand in the
UI. Switching keeps the data, but the compose file's volumes are new ones, so
it is copied across once:

1. **Switch the build pack.** In the app's General settings set Build Pack to
   `Docker Compose` and Docker Compose Location to `/docker-compose.yaml`.
   Clear Port Mappings and Custom Docker Options; the compose file has both.
   Fill in `SSH_PUBLIC_KEYS` and the rest, which Coolify now lists.
2. **Deploy once, then stop the app.** That creates the new, empty volumes.
3. **Copy each old volume into its new one** on the host. `docker volume ls`
   shows both sets: the old `<uuid>-home`, `<uuid>-cache`, `<uuid>-system` and
   the new `<uuid>_home`, `<uuid>_cache`, `<uuid>_system`.
   ```bash
   for v in home cache system; do
     docker run --rm -v "<uuid>-$v:/from:ro" -v "<uuid>_$v:/to" debian:trixie \
       cp -a /from/. /to/
   done
   ```
   Copying `system` keeps the SSH host keys, so clients see the same host.
4. **Start the app** and check the container log for `nofile limit: 65536`,
   then log in and check `~/dev` and the agents' logins.
5. **Remove the old volumes** from Persistent Storage once the new box has run
   for a while.

The entrypoint prints `nofile limit: <n>` at boot and warns below 4096, which
is what a deployment that runs the image without the compose file looks like:
healthy, until a JetBrains backend dies indexing with EMFILE.

## Remote IDE (JetBrains)

Connecting WebStorm over SSH is not a terminal session with a file browser: the
backend is a full IDE running on the box, and the local client is close to a
rendering surface. That is why three things here exist — the X/font libraries
in the `Dockerfile`, the raised `nofile`, and the cache volume. JetBrains also
keeps settings in `~/.config` and plugins in `~/.local/share`, which persist
with the rest of home.

Two limits live on the Hetzner host rather than in the container, so they can't
be fixed from this repo:

- **Swap.** The box has 4 GB and no swap. A backend indexing a large JS project
  next to running Claude sessions will get OOM-killed. Add a swapfile on the host.
- **inotify watches.** `fs.inotify.max_user_watches` is at the host default
  (~29.5k), which is low for JS projects. Raise it via `/etc/sysctl.d/` on the host.

After connecting, set the backend heap to ~2048 MB (**Help → Change Memory
Settings**) and mark `node_modules` and build output as excluded — indexing them
is what will exhaust this machine.

