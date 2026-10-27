# afkd

[![CI](https://github.com/maximn/afkd/actions/workflows/ci.yml/badge.svg)](https://github.com/maximn/afkd/actions/workflows/ci.yml)

A container image for a persistent remote coding box: SSH in from a laptop or a
phone, attach to a long-lived `tmux` or [herdr](https://github.com/herdrdev/herdr)
session, and leave Claude Code or Codex running while you disconnect. You go
AFK; the box keeps working.

The box is the unit of persistence. Sessions, agent state, auth and your working
tree all survive a dropped connection, a closed laptop, and a redeploy.

## What's inside

| | |
|---|---|
| Agents | [Claude Code](https://claude.com/claude-code), [Codex](https://github.com/openai/codex) |
| Multiplexers | `tmux`, `herdr` |
| Clipboard | `pbcopy` copies to the clipboard of the machine you connect from, over OSC 52 (Ghostty, or iTerm2 with "Applications in terminal may access clipboard") |
| Runtimes | [mise](https://mise.jdx.dev): Node by default, and whatever a project's `.nvmrc`, `.node-version`, `.python-version` or `.tool-versions` asks for. `yarn` and `pnpm` via corepack |
| Shell | `zsh` + [starship](https://starship.rs), `fzf`, git aliases |
| Git | `git`, `git-crypt`, `gh`, [git-spice](https://abhinav.github.io/git-spice/) |
| Search | `ripgrep`, `fd`, `jq` |
| Listing | [eza](https://eza.rocks) as `ll`, `la` and `lt` (tree), with each file's git status; `ls` stays GNU ls |
| Editing | `vim` (also `vi` and `editor`, set as `EDITOR`/`VISUAL`), man pages |
| Building | `gcc`/`g++`, `make`, `pkg-config`, OpenSSL, zlib and libffi headers — enough for node-gyp, `openssl-sys` and most Python sdists |
| Diagnostics | `dig`, `ping`, `nc`, `lsof`, `strace`, `htop` |
| Reading | [glow](https://github.com/charmbracelet/glow) (Markdown in the terminal) |
| Access | `openssh-server` (key auth only), `xterm-ghostty` terminfo |

Tool versions are pinned as build `ARG`s and bumped by Renovate, so an image can
be reproduced from its commit SHA. Debian packages are deliberately unpinned —
the archive drops superseded versions, so a pinned `apt` version breaks the
build the day it rolls.

## Deploy

[docker-compose.yaml](docker-compose.yaml) is the whole deployment: the image,
the published port, the three volumes and the fd limit. The image is the one CI
publishes to `ghcr.io/maximn/afkd` for every commit on `main` that
changes it, so pull access to it comes first (`docker login ghcr.io`). See
[coolify.md](coolify.md) for running it on Coolify.

```bash
SSH_PUBLIC_KEYS="$(cat ~/.ssh/id_ed25519.pub)" docker compose up -d
```

To run your own build, tag it as the image Compose expects and it is used
instead of pulled:

```bash
docker build -t ghcr.io/maximn/afkd:main .
```

Or without Compose:

```bash
docker build -t afkd .
docker run -d -p 2222:22 --ulimit nofile=65536:65536 \
  -e SSH_PUBLIC_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  -v afkd-home:/home/dev \
  -v afkd-cache:/home/dev/.cache \
  -v afkd-system:/var/lib/afkd \
  afkd
```

A second box on the same host needs its own port and volumes, or it takes over
the first one's: give Compose its own project name (`SSH_PORT=2223 docker
compose -p afkd-work up -d`), or change the port and all three volume names in
`docker run`. On Coolify, see [Running several boxes](coolify.md#running-several-boxes).

You log in as `dev`, which owns all of `/home/dev` and has passwordless `sudo`.
Home is persisted whole; the image keeps its own config under `/etc` and
`/usr`, so a long-lived home still gets every image update. The system volume
holds the SSH host keys. Coming from an image that ran as root? See
[Migrating from the root layout](coolify.md#migrating-from-the-root-layout).

`SSH_PUBLIC_KEYS` is required and the entrypoint refuses to start without it:
password auth is disabled, so no keys would mean a container that passes its
healthcheck while being impossible to log into. The image carries that
healthcheck itself (`pgrep -x sshd`), so a host that reads one from the image
gets it with no configuration.

## Connect

Add the box to `~/.ssh/config` as `Host afk` (see [ssh.md](ssh.md)), then
symlink `afk` onto your PATH:

```bash
ln -sf "$PWD/bin/afk" ~/.local/bin/afk
```

```bash
afk                 # attach to the 'main' tmux session, creating it if needed
afk myproject       # named session
afk ls              # list sessions
afk kill myproject  # end one
afk herdr           # the same, in herdr: afk herdr <name>, herdr ls, herdr kill
afk ssh             # a plain shell, no multiplexer
```

The image ships the same `afk`, which on the box drives tmux and herdr
directly: the same commands work over plain SSH from a phone. A host alias
other than `afk` goes in `AFK_HOST`, which is also how one laptop drives
[several boxes](ssh.md#several-boxes), one per account. For herdr on a phone,
a touch client beats a terminal; see [phone.md](phone.md).

On a new box, sign the agents in once — their credentials live in the mounted
volumes, so this survives redeploys:

```bash
afk
claude login
```

## Development

CI builds the image and runs the test suite against a running container. To do
the same locally:

```bash
docker build -t afkd:ci .
npm install -g bats
bats --print-output-on-failure tests/
```

The suite boots the real image for every case, because each entrypoint bug this
repo has shipped was only visible at runtime. `tests/entrypoint.bats` covers key
installation, the `GITHUB_SSH_KEY` formats and forwarded-env quoting;
`tests/ssh.bats` proves a real login works; `tests/migrate.bats` runs
`afkd-migrate` against volumes laid out the way root-era images left them;
`tests/compose.bats` boots `docker-compose.yaml`, checks it declares every
variable the image reads and pulls the published image rather than building;
`tests/image.bats` checks the toolchain matches the pinned versions.

Linting: `shellcheck entrypoint.sh`, `zsh -n` for the `bin/` scripts (they're
zsh, which shellcheck can't parse), and `hadolint` for the Dockerfile.

### Platform

`linux/amd64` and `linux/arm64`. CI builds and runs the full suite on both before
publishing, on a native runner each rather than one emulating the other. PRs
run amd64 alone, to keep the private repo inside its Actions allowance.

Architecture comes from BuildKit's `TARGETARCH` and nothing else. It used to be
discovered at runtime in two spellings — `dpkg --print-architecture` for the
apt repo and fzf, `uname -m` for git-spice and herdr — which agree with what
those upstreams publish on these two architectures and on nothing else. The two
that name their assets `x86_64`/`aarch64` now get an explicit mapping, and an
architecture outside it fails the build instead of 404ing into an empty
install.

## License

[MIT](LICENSE)
