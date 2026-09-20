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

# `(A || B && C)` groups as `(A || B) && C`, so with wget already present this
# skipped apt-get update and ran the install against empty package lists. It is
# latent only because node:*-slim purges wget in its own build; the day the base
# image keeps it -- a Renovate bump away -- the short circuit goes live.
#
# The marker has to stay on the line directly above the RUN: check-pins reads
# exactly one comment line back.
# pin-check: ignore - a signing key, not a versioned artifact
RUN if ! command -v wget >/dev/null; then apt-get update && apt-get install -y wget; fi \
    && mkdir -p /etc/apt/keyrings \
    && chmod 755 /etc/apt/keyrings \
    && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       | tee /etc/apt/sources.list.d/github-cli.list > /dev/null

# openssh-server's postinst generates host keys during the install below.
# Left in place they are baked into the image and shared by every container
# built from it, and the entrypoint's `ssh-keygen -A` would never replace
# them -- it only creates key types that are missing. Removing them here
# means each deployment generates its own on first boot, which is what the
# entrypoint already claims to do.
RUN apt-get update && apt-get install -y \
    openssh-server \
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

# renovate: datasource=github-releases depName=junegunn/fzf extractVersion=^v(?<version>.+)$
ARG FZF_VERSION=0.74.4
RUN curl -fsSL "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf-${FZF_VERSION}-linux_$(dpkg --print-architecture).tar.gz" \
      | tar -xz -C /usr/local/bin

# renovate: datasource=github-releases depName=starship/starship extractVersion=^v(?<version>.+)$
ARG STARSHIP_VERSION=1.26.0
RUN curl -fsSL https://starship.rs/install.sh -o /tmp/starship-install.sh \
    && sh /tmp/starship-install.sh --yes --version "v${STARSHIP_VERSION}" \
    && rm /tmp/starship-install.sh

# renovate: datasource=github-releases depName=abhinav/git-spice extractVersion=^v(?<version>.+)$
ARG GIT_SPICE_VERSION=0.31.2
RUN curl -fsSL "https://github.com/abhinav/git-spice/releases/download/v${GIT_SPICE_VERSION}/git-spice.Linux-$(uname -m).tar.gz" \
      | tar -xz -C /usr/local/bin git-spice \
    && ln -sf /usr/local/bin/git-spice /usr/local/bin/gs

# herdr is pre-1.0 and ships stable releases weekly.
# renovate: datasource=github-releases depName=herdrdev/herdr extractVersion=^v(?<version>.+)$
ARG HERDR_VERSION=0.9.1
RUN curl -fsSL "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-$(uname -m)" \
      -o /usr/local/bin/herdr \
    && chmod +x /usr/local/bin/herdr

# Last of the installs: these three publish most often, so keep the layers
# they invalidate to a minimum.
# renovate: datasource=npm depName=@openai/codex
ARG CODEX_VERSION=0.155.1
# renovate: datasource=npm depName=@playwright/mcp
ARG PLAYWRIGHT_MCP_VERSION=0.0.82
# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=2.1.278
RUN npm install -g \
      "@openai/codex@${CODEX_VERSION}" \
      "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}" \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

COPY ghostty.terminfo /tmp/ghostty.terminfo
RUN tic -x /tmp/ghostty.terminfo && rm /tmp/ghostty.terminfo

RUN sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

COPY bin/t /usr/local/bin/t
COPY bin/h /usr/local/bin/h
COPY bin/cc /usr/local/bin/cc
COPY bin/ch /usr/local/bin/ch
RUN chmod +x /usr/local/bin/t /usr/local/bin/h /usr/local/bin/cc /usr/local/bin/ch

COPY git-aliases.zsh /root/.git-aliases.zsh
RUN echo 'eval "$(starship init zsh)"' >> /root/.zshrc \
    && echo 'source <(fzf --zsh)' >> /root/.zshrc \
    && echo 'source /root/.git-aliases.zsh' >> /root/.zshrc \
    && echo 'cd ~/dev 2>/dev/null' >> /root/.zshrc

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22
CMD ["/usr/local/bin/entrypoint.sh"]
