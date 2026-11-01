# A workstation, not a runtime: plain Debian stable, with languages layered on
# top by mise rather than chosen by the base. Not -slim, whose dpkg excludes
# strip man pages and docs from every package installed afterwards -- the right
# trade for a service, the wrong one for a box people work on.
FROM debian:trixie-20261005@sha256:913f6706df59a68922d1dd08f78c2476560a8d367897200a6005b00e5f67c2d5

# Most fetches below are `curl ... | tar`. Under the default `sh -c` a failed
# download still exits 0 as long as tar is happy with the empty stream, so
# the image builds and ships without the tool. pipefail makes it fail loudly.
#
# pipefail only covers pipelines. `sh -c "$(curl ...)"` is a command
# substitution: a failed download is substituted in as the empty string and
# `sh -c ""` exits 0, so nothing below runs a fetched script that way.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV LANG=C.UTF-8

# Set by BuildKit from the platform being built for, and the single source of
# architecture in this file. It used to be discovered at runtime in two
# spellings -- `dpkg --print-architecture` for the apt repo and fzf, `uname -m`
# for git-spice and herdr -- which line up with what those four upstreams
# publish on exactly the two architectures this image supports, and on nothing
# else. Build for armv7 and dpkg says `armhf` while fzf publishes `armv7`:
# every URL 404s, and `curl | tar` turns that into an install that is simply
# empty. So the supported set is named here instead, and each RUN that wants
# the uname spelling maps it explicitly and exits non-zero on anything it does
# not recognise.
ARG TARGETARCH

# `(A || B && C)` groups as `(A || B) && C`, so with wget already present this
# skipped apt-get update and ran the install against empty package lists. It is
# latent only because the base image ships no wget; the day it does -- a
# Renovate bump away -- the short circuit goes live.
#
# The marker has to stay on the line directly above the RUN: check-pins reads
# exactly one comment line back.
# pin-check: ignore - a signing key, not a versioned artifact
RUN if ! command -v wget >/dev/null; then apt-get update && apt-get install -y --no-install-recommends wget ca-certificates; fi \
    && mkdir -p /etc/apt/keyrings \
    && chmod 755 /etc/apt/keyrings \
    && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && echo "deb [arch=${TARGETARCH} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       | tee /etc/apt/sources.list.d/github-cli.list > /dev/null

# openssh-server's postinst generates host keys during the install below.
# Left in place they are baked into the image and shared by every container
# built from it, and the entrypoint's `ssh-keygen -A` would never replace
# them -- it only creates key types that are missing. Removing them here
# means each deployment generates its own on first boot, which is what the
# entrypoint already claims to do.
# --no-install-recommends, so every package below is here because something
# names it. Five of them were arriving as recommends and are now explicit.
#
# ca-certificates is the one that breaks the build rather than the box. The
# base image carries none; wget and curl recommend it, so it used to arrive
# with them. Without it every https fetch here -- the gh keyring, fzf,
# starship, git-spice, herdr, npm -- fails verification, and wget exits 5
# before the first RUN is done.
#
# The other four fail quietly instead, which is the worse way to find out:
# `less` is git's pager, `ncurses-term` carries the screen/tmux terminfo
# entries that ncurses-base leaves out, `gnupg` is what git-crypt and signed
# commits need, and fonts-dejavu-core is what the JetBrains backend rasterizes
# its UI with -- a backend with no fonts starts and then draws nothing legible.
#
# Deliberately not re-added: openssh-server's `xauth`, since X11 forwarding is
# off, and its `default-logind`, which has no place in a container.
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    ca-certificates \
    less \
    ncurses-term \
    gnupg \
    patch \
    git \
    git-crypt \
    tmux \
    curl \
    wget \
    unzip \
    gh \
    ripgrep \
    fd-find \
    jq \
    python3 \
    make \
    zsh \
    htop \
    procps \
# Kills the biggest process before memory runs out rather than after, which
# on a box with no swap is the difference between losing one agent and
# losing the box. The entrypoint starts it; see the comment there.
    earlyoom \
# The login user is not root, and still administers its own box.
    sudo \
# The workstation layer -- what a person or an agent reaches for on a box they
# work on, which a runtime image rightly leaves out.
#
# An editor: git, gh, git-spice and the agents' "open in editor" all launch
# one, falling back to `vi` when nothing is set, so with none here every one
# of them failed. vim also registers `vi` and `editor`. man-db because the base
# keeps every package's man pages and nothing could read them.
    vim \
    man-db \
# Every locale, precompiled. sshd accepts the client's LANG and LC_*, so a
# session runs in the laptop's locale, and any the box lacks makes man, perl
# and the rest warn "cannot set locale" on every run. Which locale arrives is
# up to whoever connects, so generating a chosen few from `locales` would only
# move the warning to the next person. ~230 MB, all of it on disk.
    locales-all \
# Native builds. Agents hit these in ordinary repos: an npm module with a
# binding.gyp (node-gyp wants a compiler, make and python3), a Rust crate on
# openssl-sys, a Python sdist with a C extension. pkg-config is how all three
# find the headers, and these three headers are the ones they most often need.
    build-essential \
    pkg-config \
    libssl-dev \
    zlib1g-dev \
    libffi-dev \
# Diagnosing the box from inside it: name resolution, reachability, a port or
# file someone is holding (lsof is also how a JetBrains EMFILE gets traced to
# its culprit), and what a stuck process is actually doing.
    bind9-dnsutils \
    iputils-ping \
    netcat-openbsd \
    lsof \
    strace \
# Moving files around: rsync for copying to and from the box, xz for the
# .tar.xz most toolchains release as, zip next to the unzip already here,
# file and tree for an agent finding its way around an unfamiliar repo.
# openssh-client already arrives with the server, but git over ssh needs it
# in its own right.
    rsync \
    xz-utils \
    zip \
    file \
    tree \
    openssh-client \
# A directory listing with each file's git status, behind the ll/la/lt aliases
# in afkd.zshrc. Plain `ls` stays GNU ls: an agent's shell can read
# that config too, and agents parse what ls prints.
    eza \
# JetBrains remote development runs a full desktop IDE on the box and rasterizes
# its UI server-side, so the backend's JBR loads libawt_xawt.so and needs the X
# and font libraries even though nothing here has a display. Without them the
# backend dies at startup with an UnsatisfiedLinkError and Gateway reports only
# that it failed to start. ~5 MB; libsecret is deliberately left out because it
# drags in glib and ICU for 57 MB to back a credential store that falls back to
# a file. The list names every library the backend loads directly, including
# the ones another entry already pulls in, so trimming one edge cannot quietly
# remove a library that is actually needed.
    libx11-6 \
    libxext6 \
    libxrender1 \
    libxtst6 \
    libxi6 \
    libfreetype6 \
    libfontconfig1 \
    fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd \
    && rm -f /etc/ssh/ssh_host_* \
    && chsh -s "$(which zsh)"

# Claude Code's apt repo, so the agent arrives as a signed package rather than
# through npm. The key is fetched over TLS and then held to the fingerprint
# Anthropic publishes (code.claude.com/docs/en/setup), because apt trusts every
# key in a signed-by file: the count check stops a second key riding along in
# the same download. gpg's output is captured first and every filter reads all
# of it: a `grep -q` or an awk `exit` stops reading early, and the writer then
# dies of SIGPIPE and fails the pipeline under pipefail.
# pin-check: ignore - a signing key, held to a pinned fingerprint
RUN curl -fsSL https://downloads.claude.ai/keys/claude-code.asc -o /etc/apt/keyrings/claude-code.asc \
    && gnupg_home="$(mktemp -d)" \
    && keys="$(gpg --homedir "$gnupg_home" --show-keys --with-colons /etc/apt/keyrings/claude-code.asc)" \
    && rm -rf "$gnupg_home" \
    && if [ "$(printf '%s\n' "$keys" | grep -c '^pub:')" != 1 ] \
          || [ "$(printf '%s\n' "$keys" | awk -F: '/^fpr:/ && !seen++ { print $10 }')" != 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE ]; then \
         echo "claude-code.asc is not Anthropic's release signing key" >&2; exit 1; \
       fi \
    && chmod 644 /etc/apt/keyrings/claude-code.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/latest latest main" \
       > /etc/apt/sources.list.d/claude-code.list

# Everything below is version-pinned rather than fetched as :latest, so the
# image only changes when a commit changes it and any build can be reproduced
# from its SHA. Renovate owns the bumps via the annotations. Each ARG sits
# directly above the RUN that consumes it so a bump only busts that one layer;
# the order runs stable -> churny for the same reason.
#
# apt packages are deliberately not pinned: Debian drops old versions from the
# archive, so a pinned apt version breaks the build the day it rolls.

# The g* shortcuts (gst, gl, gd, gcb, gwip, ...) are oh-my-zsh git plugin
# aliases, not zsh builtins, so the plugin is what keeps this box in sync with
# the local machine. Only two of that repo's files are needed - the plugin,
# plus git_current_branch out of lib/git.zsh - so they are vendored rather than
# run through the installer, which tracks master and would change the shell
# between rebuilds instead of between commits. oh-my-zsh ships no tags, so the
# pin is a commit and Renovate bumps the digest.
# renovate: datasource=git-refs depName=https://github.com/ohmyzsh/ohmyzsh
ARG OMZ_REF=d2b7f557cceaddb16ba89bbf8200d8a8df35c4d8
RUN mkdir -p /usr/local/share/afkd/zsh/omz \
    && curl -fsSL "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/${OMZ_REF}/lib/git.zsh" \
         -o /usr/local/share/afkd/zsh/omz/lib-git.zsh \
    && curl -fsSL "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/${OMZ_REF}/plugins/git/git.plugin.zsh" \
         -o /usr/local/share/afkd/zsh/omz/git.plugin.zsh

# renovate: datasource=github-releases depName=junegunn/fzf extractVersion=^v(?<version>.+)$
ARG FZF_VERSION=0.74.5
RUN curl -fsSL "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf-${FZF_VERSION}-linux_${TARGETARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin

# Markdown renderer for the terminal, so plans and READMEs an agent writes can
# be read on the box instead of as raw markup. Pages through `less`.
# renovate: datasource=github-releases depName=charmbracelet/glow extractVersion=^v(?<version>.+)$
ARG GLOW_VERSION=3.0.0
# glow mixes spellings: x86_64 like uname, but arm64 like Docker.
RUN case "${TARGETARCH}" in \
      amd64) garch=x86_64 ;; \
      arm64) garch=arm64 ;; \
      *) echo "unsupported TARGETARCH: '${TARGETARCH}'" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/charmbracelet/glow/releases/download/v${GLOW_VERSION}/glow_${GLOW_VERSION}_Linux_${garch}.tar.gz" \
      | tar -xz -C /usr/local/bin --strip-components=1 "glow_${GLOW_VERSION}_Linux_${garch}/glow"

# The release asset, not starship.rs/install.sh. The installer was fetched
# unversioned from a different host than the release and run as root, so the
# pin covered only what it was asked to install, never the script doing the
# installing -- and check-pins passed it because the block named a VERSION.
# The checksum is the per-asset .sha256 from the same release, the bar the
# Codex install below is held to; an empty one is refused rather than handed
# to `sha256sum -c`.
# renovate: datasource=github-releases depName=starship/starship extractVersion=^v(?<version>.+)$
ARG STARSHIP_VERSION=1.27.0
RUN case "${TARGETARCH}" in \
      amd64) triple=x86_64-unknown-linux-musl ;; \
      arm64) triple=aarch64-unknown-linux-musl ;; \
      *) echo "unsupported TARGETARCH: '${TARGETARCH}'" >&2; exit 1 ;; \
    esac \
    && release="https://github.com/starship/starship/releases/download/v${STARSHIP_VERSION}" \
    && asset="starship-${triple}.tar.gz" \
    && tmp="$(mktemp -d)" \
    && curl -fsSL "${release}/${asset}" -o "${tmp}/${asset}" \
    && want="$(curl -fsSL "${release}/${asset}.sha256" | tr -d '[:space:]')" \
    && [ -n "${want}" ] \
    && echo "${want}  ${tmp}/${asset}" | sha256sum -c --quiet - \
    && tar -xzf "${tmp}/${asset}" -C /usr/local/bin starship \
    && rm -rf "${tmp}"

# renovate: datasource=github-releases depName=abhinav/git-spice extractVersion=^v(?<version>.+)$
ARG GIT_SPICE_VERSION=0.33.0
# git-spice and herdr both name their assets with the uname spelling
# (x86_64/aarch64) rather than the Docker one, hence the mapping. Anything
# unmapped is a hard error here rather than a 404 three commands later.
RUN case "${TARGETARCH}" in \
      amd64) uarch=x86_64 ;; \
      arm64) uarch=aarch64 ;; \
      *) echo "unsupported TARGETARCH: '${TARGETARCH}' (BuildKit sets this; a legacy builder does not)" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/abhinav/git-spice/releases/download/v${GIT_SPICE_VERSION}/git-spice.Linux-${uarch}.tar.gz" \
      | tar -xz -C /usr/local/bin git-spice \
    && ln -sf /usr/local/bin/git-spice /usr/local/bin/gs

# herdr is pre-1.0 and ships stable releases weekly.
# renovate: datasource=github-releases depName=herdrdev/herdr extractVersion=^v(?<version>.+)$
ARG HERDR_VERSION=0.9.5
RUN case "${TARGETARCH}" in \
      amd64) uarch=x86_64 ;; \
      arm64) uarch=aarch64 ;; \
      *) echo "unsupported TARGETARCH: '${TARGETARCH}'" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-${uarch}" \
      -o /usr/local/bin/herdr \
    && chmod +x /usr/local/bin/herdr

# chezmoi, for a dotfiles repo of the user's own; dotfiles-sync catches it up
# at boot. The asset is checked against the checksums file from the same
# release, and one missing from that file is refused rather than skipped.
# renovate: datasource=github-releases depName=twpayne/chezmoi extractVersion=^v(?<version>.+)$
ARG CHEZMOI_VERSION=2.73.3
RUN case "${TARGETARCH}" in \
      amd64|arm64) ;; \
      *) echo "unsupported TARGETARCH: '${TARGETARCH}'" >&2; exit 1 ;; \
    esac \
    && release="https://github.com/twpayne/chezmoi/releases/download/v${CHEZMOI_VERSION}" \
    && asset="chezmoi_${CHEZMOI_VERSION}_linux_${TARGETARCH}.tar.gz" \
    && tmp="$(mktemp -d)" \
    && curl -fsSL "${release}/${asset}" -o "${tmp}/${asset}" \
    && curl -fsSL "${release}/chezmoi_${CHEZMOI_VERSION}_checksums.txt" -o "${tmp}/checksums.txt" \
    && sed -En "s#^([0-9a-f]{64})  ${asset}\$#\1  ${tmp}/${asset}#p" "${tmp}/checksums.txt" \
       | sha256sum -c --quiet - \
    && tar -xzf "${tmp}/${asset}" -C /usr/local/bin chezmoi \
    && rm -rf "${tmp}"

# Language runtimes are per project, so they come from mise rather than from the
# base image: a repo's .nvmrc, .node-version, .python-version or .tool-versions
# picks its own version. The binary is the static one from mise's own image,
# pinned by digest like the base.
COPY --from=ghcr.io/jdx/mise:2026.10.19@sha256:6bd2515bf27389f537921fc8c3e5a6579f15cf889a63a8432dc542670174e50a /usr/local/bin/mise /usr/local/bin/mise
# Not named config.toml in the repo: mise reads ./mise/config.toml as project
# config, so every contributor running mise here got it as theirs -- an
# untrusted-config error on every command, and once trusted, the image's Node.
COPY mise/system.toml /etc/mise/config.toml

# The shell-wide half of the setup lives in /etc/zsh, which every zsh reads --
# an ssh command, an interactive login, an agent's own subshell. Image ENV
# reaches none of those, since sshd builds each session's environment from
# scratch; it is set below only for what runs outside a login (docker exec,
# the entrypoint).
COPY zsh/afkd.zshenv /etc/zsh/afkd.zshenv
RUN echo 'source /etc/zsh/afkd.zshenv' >> /etc/zsh/zshenv
ENV PATH="/usr/local/share/mise/shims:${PATH}"

# The default Node, for anything with no version file of its own. Installed
# with --system into /usr/local/share/mise, so it belongs to the image like any
# other binary here and no volume mounted over home can hide it; per-project
# versions install into home on first use.
#
# corepack puts yarn and pnpm on PATH, each resolving to the version a
# project's packageManager field names -- which a single global yarn, as the
# node base image shipped, never could. Node stops bundling corepack from 25 on,
# so a major bump fails right here rather than quietly dropping yarn.
#
# mise also writes download scratch under root's home, which nothing reads at
# runtime, so it is removed rather than shipped.
# renovate: datasource=node-version depName=node
ARG NODE_VERSION=24.22.1
RUN printf '\n[tools]\nnode = "%s"\n' "${NODE_VERSION}" >> /etc/mise/config.toml \
    && mise install --system \
    && corepack enable --install-directory /usr/local/bin yarn pnpm \
    && rm -rf /root/.local/share/mise /root/.local/state/mise /root/.cache/mise

# Each agent's own update mechanism is switched off in a system-level file
# rather than through ENV, which never reaches an SSH login. Left on, they
# update themselves on the container's writable layer: the box drifts from the
# pinned version and drifts back on the next redeploy.
COPY claude-code/managed-settings.json /etc/claude-code/managed-settings.json
COPY codex/config.toml /etc/codex/config.toml

# Last of the installs: these two publish most often, so keep the layers
# they invalidate to a minimum.
#
# Codex comes from its release *package* rather than the bare binary: the
# package carries the ripgrep and bubblewrap Codex runs with, and is the layout
# upstream's own installer unpacks and links to. The checksum file is from the
# same release, so this proves the download is the one published rather than
# authenticating the publisher -- the same bar the other release assets here
# are held to. The hash is looked up rather than piped through `sha256sum -c`
# against a grep: a filename that matches nothing would hand -c an empty list,
# so an empty lookup is refused explicitly.
# renovate: datasource=github-releases depName=openai/codex extractVersion=^rust-v(?<version>\d+\.\d+\.\d+)$
ARG CODEX_VERSION=0.164.0
RUN case "${TARGETARCH}" in \
      amd64) triple=x86_64-unknown-linux-musl ;; \
      arm64) triple=aarch64-unknown-linux-musl ;; \
      *) echo "unsupported TARGETARCH: '${TARGETARCH}'" >&2; exit 1 ;; \
    esac \
    && release="https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}" \
    && package="codex-package-${triple}.tar.gz" \
    && tmp="$(mktemp -d)" \
    && curl -fsSL "${release}/${package}" -o "${tmp}/${package}" \
    && want="$(curl -fsSL "${release}/codex-package_SHA256SUMS" | awk -v f="${package}" '$2 == f { print $1 }')" \
    && [ -n "${want}" ] \
    && echo "${want}  ${tmp}/${package}" | sha256sum -c --quiet - \
    && mkdir -p /opt/codex \
    && tar -xzf "${tmp}/${package}" -C /opt/codex \
    && ln -sf /opt/codex/bin/codex /usr/local/bin/codex \
    && rm -rf "${tmp}"

# The exact package revision is pinned along with the version: every release
# in the repo so far is -1, and a rebuilt -2 should arrive as a reviewed bump
# rather than silently under an unchanged pin. Renovate reads the version from
# npm, where Anthropic publishes the same numbers.
# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=2.1.310
RUN apt-get update \
    && apt-get install -y --no-install-recommends "claude-code=${CLAUDE_CODE_VERSION}-1" \
    && rm -rf /var/lib/apt/lists/*

COPY ghostty.terminfo /tmp/ghostty.terminfo
RUN tic -x /tmp/ghostty.terminfo && rm /tmp/ghostty.terminfo

# Replaces `sed -i 's/#PasswordAuthentication yes/...' sshd_config`, which
# edited a *commented* line and so no-opped into a box with password auth on
# the day Debian reworded it. See the header in the file itself.
COPY sshd_config.d/99-afkd.conf /etc/ssh/sshd_config.d/99-afkd.conf
# A hardening file that is silently not read is worse than no hardening file,
# so assert the end state rather than the mechanism: `sshd -T` prints the
# config as sshd has actually merged it. It refuses to run without the host
# keys it is configured with, hence the keygen -- and the rm in the same
# layer, so none are baked into the image (tests/image.bats asserts that
# separately).
RUN chmod 644 /etc/ssh/sshd_config.d/99-afkd.conf \
    && install -d -m 700 /var/lib/afkd/ssh \
    && for type in ed25519 ecdsa rsa; do \
         ssh-keygen -q -t "${type}" -N '' -f "/var/lib/afkd/ssh/ssh_host_${type}_key"; \
       done \
    && /usr/sbin/sshd -T > /tmp/sshd-effective.conf \
    && for kv in 'passwordauthentication no' 'kbdinteractiveauthentication no' \
                 'permitrootlogin no' 'allowusers dev' \
                 'x11forwarding no' 'maxauthtries 4' 'clientaliveinterval 300' \
                 'authorizedkeysfile /etc/ssh/authorized_keys/%u' \
                 'hostkey /var/lib/afkd/ssh/ssh_host_ed25519_key'; do \
         grep -qx "${kv}" /tmp/sshd-effective.conf \
           || { echo "sshd drop-in not in effect: ${kv}" >&2; exit 1; }; \
       done \
    && rm -rf /tmp/sshd-effective.conf /var/lib/afkd

# afk is the same script on the laptop and here: it notices /run/afkd and
# drives tmux or herdr directly instead of ssh-ing. Nothing else from bin/ is
# named after a real tool -- the laptop helper used to be called cc, and
# shipped here it shadowed the C compiler that make and node-gyp invoke.
COPY bin/afk /usr/local/bin/afk
COPY bin/pbcopy /usr/local/bin/pbcopy
RUN chmod +x /usr/local/bin/afk /usr/local/bin/pbcopy
COPY tmux.conf /etc/tmux.conf

# The image's interactive shell setup, kept out of home: sourced from the
# system zshrc, ahead of the user's own ~/.zshrc. That file is seeded from
# /etc/skel -- which also keeps zsh's new-user wizard from ever running -- and
# is the user's from then on.
COPY git-aliases.zsh /usr/local/share/afkd/zsh/git-aliases.zsh
COPY zsh/afkd.zshrc /etc/zsh/afkd.zshrc
COPY zsh/skel.zshrc /etc/skel/.zshrc
RUN echo 'source /etc/zsh/afkd.zshrc' >> /etc/zsh/zshrc \
    && cp /etc/skel/.zshrc /root/.zshrc

# The one login. Its home is created here, from the skeleton above, because
# Docker seeds an empty volume from what the image holds at the mount point --
# files, ownership and mode -- so a first deploy starts with a home that is
# already dev's. The cache volume is mounted inside it and seeded the same
# way. uid 1000 is the first a Debian host hands out, so a project
# bind-mounted from that host's first user has the same owner on both sides.
#
# Passwordless sudo because no password is ever set: the box is single-user,
# and this is that user administering it, not a privilege boundary.
RUN useradd --create-home --uid 1000 --user-group --shell /usr/bin/zsh dev \
    && chmod 700 /home/dev \
    && install -d -o dev -g dev -m 755 /home/dev/.cache \
    && echo 'dev ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/dev \
    && chmod 440 /etc/sudoers.d/dev \
    && visudo -cf /etc/sudoers.d/dev

COPY home-init.sh /usr/local/libexec/afkd/home-init
COPY afkd-migrate.sh /usr/local/bin/afkd-migrate
COPY oom-notify.sh /usr/local/libexec/afkd/oom-notify
COPY dotfiles-sync.sh /usr/local/libexec/afkd/dotfiles-sync
RUN chmod 755 /usr/local/libexec/afkd/home-init /usr/local/bin/afkd-migrate \
      /usr/local/libexec/afkd/oom-notify /usr/local/libexec/afkd/dotfiles-sync

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22

# sshd is the last thing the entrypoint execs, so "sshd is running" means the
# whole entrypoint ran -- the same signal the test suite waits on. Shipped in
# the image because it previously existed only as a field in coolify.md, which
# left every other deployment (Compose, Kubernetes, a bare `docker run`) with
# no health signal at all.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["pgrep", "-x", "sshd"]

CMD ["/usr/local/bin/entrypoint.sh"]
