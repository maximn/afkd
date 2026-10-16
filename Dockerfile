FROM node:24.21.0-slim

# Most fetches below are `curl ... | tar`. Under the default `sh -c` a failed
# download still exits 0 as long as tar is happy with the empty stream, so
# the image builds and ships without the tool. pipefail makes it fail loudly.
#
# pipefail only covers pipelines. `sh -c "$(curl ...)"` is a command
# substitution: a failed download is substituted in as the empty string and
# `sh -c ""` exits 0, which is why the starship install below writes the
# script to a file and runs that instead.
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
# latent only because node:*-slim purges wget in its own build; the day the base
# image keeps it -- a Renovate bump away -- the short circuit goes live.
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
    && mkdir -p /run/sshd /root/.ssh \
    && rm -f /etc/ssh/ssh_host_* \
    && chsh -s "$(which zsh)"

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
ARG OMZ_REF=964ddf789b022b6958b27d02d7fa54f552de21e9
RUN mkdir -p /root/.omz-git \
    && curl -fsSL "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/${OMZ_REF}/lib/git.zsh" \
         -o /root/.omz-git/lib-git.zsh \
    && curl -fsSL "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/${OMZ_REF}/plugins/git/git.plugin.zsh" \
         -o /root/.omz-git/git.plugin.zsh

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

# renovate: datasource=github-releases depName=starship/starship extractVersion=^v(?<version>.+)$
ARG STARSHIP_VERSION=1.26.0
RUN curl -fsSL https://starship.rs/install.sh -o /tmp/starship-install.sh \
    && sh /tmp/starship-install.sh --yes --version "v${STARSHIP_VERSION}" \
    && rm /tmp/starship-install.sh

# renovate: datasource=github-releases depName=abhinav/git-spice extractVersion=^v(?<version>.+)$
ARG GIT_SPICE_VERSION=0.32.0
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
ARG HERDR_VERSION=0.9.4
RUN case "${TARGETARCH}" in \
      amd64) uarch=x86_64 ;; \
      arm64) uarch=aarch64 ;; \
      *) echo "unsupported TARGETARCH: '${TARGETARCH}'" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-${uarch}" \
      -o /usr/local/bin/herdr \
    && chmod +x /usr/local/bin/herdr

# Last of the installs: these two publish most often, so keep the layers
# they invalidate to a minimum.
# renovate: datasource=npm depName=@openai/codex
ARG CODEX_VERSION=0.162.1
# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=2.1.299
RUN npm install -g \
      "@openai/codex@${CODEX_VERSION}" \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
# npm ignores XDG on Linux and caches to ~/.npm, which is on the container's
# writable layer and so is thrown away on every redeploy. /root/.cache is a
# volume, so point npm at it -- but via npmrc rather than NPM_CONFIG_CACHE,
# because sshd builds a fresh environment per session and container ENV never
# reaches an SSH login (the same reason entrypoint.sh writes /root/.zshenv).
# The clean runs first and against the *default* cache, so the build's own
# tarballs are dropped instead of being baked under the volume's mount path,
# where Docker would seed them into the empty volume on first deploy.
    && npm cache clean --force \
    && npm config set cache /root/.cache/npm --global

COPY ghostty.terminfo /tmp/ghostty.terminfo
RUN tic -x /tmp/ghostty.terminfo && rm /tmp/ghostty.terminfo

# Replaces `sed -i 's/#PasswordAuthentication yes/...' sshd_config`, which
# edited a *commented* line and so no-opped into a box with password auth on
# the day Debian reworded it. See the header in the file itself.
COPY sshd_config.d/99-remote-claude.conf /etc/ssh/sshd_config.d/99-remote-claude.conf
# A hardening file that is silently not read is worse than no hardening file,
# so assert the end state rather than the mechanism: `sshd -T` prints the
# config as sshd has actually merged it. It prints sshd's own spelling, not
# the file's -- prohibit-password comes back as its older synonym
# without-password -- hence the alternation rather than a literal match. It refuses to run without host keys,
# hence the keygen -- and the rm in the same layer, so none are baked into the
# image (tests/image.bats asserts that separately).
RUN chmod 644 /etc/ssh/sshd_config.d/99-remote-claude.conf \
    && ssh-keygen -A >/dev/null \
    && /usr/sbin/sshd -T > /tmp/sshd-effective.conf \
    && for kv in 'passwordauthentication no' 'kbdinteractiveauthentication no' \
                 'permitrootlogin (without-password|prohibit-password)' \
                 'x11forwarding no' 'maxauthtries 4' 'clientaliveinterval 300'; do \
         grep -qE "^${kv}$" /tmp/sshd-effective.conf \
           || { echo "sshd drop-in not in effect: ${kv}" >&2; exit 1; }; \
       done \
    && rm -f /tmp/sshd-effective.conf /etc/ssh/ssh_host_*

COPY bin/t /usr/local/bin/t
COPY bin/h /usr/local/bin/h
COPY bin/cc /usr/local/bin/cc
COPY bin/ch /usr/local/bin/ch
RUN chmod +x /usr/local/bin/t /usr/local/bin/h /usr/local/bin/cc /usr/local/bin/ch

COPY git-aliases.zsh /root/.git-aliases.zsh
RUN cat > /root/.zshrc <<'ZSHRC'
# The git plugin registers completions with compdef, so compinit runs first.
autoload -Uz compinit && compinit -d /root/.zcompdump

source /root/.omz-git/lib-git.zsh
source /root/.omz-git/git.plugin.zsh

# After the plugin, so the personal overrides win.
source /root/.git-aliases.zsh

eval "$(starship init zsh)"
source <(fzf --zsh)
eval "$(gs shell completion zsh)"

cd ~/dev 2>/dev/null
ZSHRC

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
