# remote-claude-code

[![CI](https://github.com/maximn/remote-claude-code/actions/workflows/ci.yml/badge.svg)](https://github.com/maximn/remote-claude-code/actions/workflows/ci.yml)

A container image for a persistent remote coding box: SSH in from a laptop or a
phone, attach to a long-lived `tmux` or [herdr](https://github.com/herdrdev/herdr)
session, and leave Claude Code or Codex running while you disconnect.

The box is the unit of persistence. Sessions, agent state, auth and your working
tree all survive a dropped connection, a closed laptop, and a redeploy.

## What's inside

| | |
|---|---|
| Agents | [Claude Code](https://claude.com/claude-code), [Codex](https://github.com/openai/codex) |
| Multiplexers | `tmux`, `herdr` |
| Runtimes | [mise](https://mise.jdx.dev): Node by default, and whatever a project's `.nvmrc`, `.node-version`, `.python-version` or `.tool-versions` asks for. `yarn` and `pnpm` via corepack |
| Shell | `zsh` + [starship](https://starship.rs), `fzf`, git aliases |
| Git | `git`, `git-crypt`, `gh`, [git-spice](https://abhinav.github.io/git-spice/) |
| Search | `ripgrep`, `fd`, `jq` |
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

The image is built from the `Dockerfile` at the repo root and needs a container
host that can mount volumes and publish port 22. See [coolify.md](coolify.md)
for a full Coolify setup: env vars, volumes, port mapping and healthcheck.

Minimum to boot:

```bash
docker build -t remote-claude-code .
docker run -d -p 2222:22 \
  -e SSH_PUBLIC_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  -v rcc-config:/root/.config \
  -v rcc-claude:/root/.claude \
  -v rcc-dev:/root/dev \
  remote-claude-code
```

`SSH_PUBLIC_KEYS` is required and the entrypoint refuses to start without it:
password auth is disabled, so no keys would mean a container that passes its
healthcheck while being impossible to log into. The image carries that
healthcheck itself (`pgrep -x sshd`), so a host that reads one from the image
gets it with no configuration.

## Connect

Add the host to `~/.ssh/config` (see [ssh.md](ssh.md)), then symlink the local
helpers from `bin/`:

```bash
ln -sf "$PWD/bin/cc" ~/.local/bin/cc   # tmux sessions over ssh
ln -sf "$PWD/bin/ch" ~/.local/bin/ch   # herdr sessions over ssh
```

```bash
cc              # attach to the 'main' tmux session, creating it if needed
cc myproject    # named session
cc ls           # list sessions
ch              # the herdr equivalent
```

`bin/t` and `bin/h` are the server-side counterparts, for when you're already
on the box — over plain SSH from a phone, for instance.

On a new box, sign the agents in once — their credentials live in the mounted
volumes, so this survives redeploys:

```bash
cc
claude login
```

## Development

CI builds the image and runs the test suite against a running container. To do
the same locally:

```bash
docker build -t remote-claude-code:ci .
npm install -g bats
bats --print-output-on-failure tests/
```

The suite boots the real image for every case, because each entrypoint bug this
repo has shipped was only visible at runtime. `tests/entrypoint.bats` covers key
installation, the `GITHUB_SSH_KEY` formats and forwarded-env quoting;
`tests/ssh.bats` proves a real login works; `tests/image.bats` checks the
toolchain matches the pinned versions.

Linting: `shellcheck entrypoint.sh`, `zsh -n` for the `bin/` scripts (they're
zsh, which shellcheck can't parse), and `hadolint` for the Dockerfile.

### Platform

`linux/amd64` and `linux/arm64`. CI builds and runs the full suite on both, on
a native runner each rather than one emulating the other.

Architecture comes from BuildKit's `TARGETARCH` and nothing else. It used to be
discovered at runtime in two spellings — `dpkg --print-architecture` for the
apt repo and fzf, `uname -m` for git-spice and herdr — which agree with what
those upstreams publish on these two architectures and on nothing else. The two
that name their assets `x86_64`/`aarch64` now get an explicit mapping, and an
architecture outside it fails the build instead of 404ing into an empty
install.

## License

[MIT](LICENSE)
