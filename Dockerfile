FROM node:20-slim

ENV LANG=C.UTF-8

RUN (type -p wget >/dev/null || apt-get update && apt-get install -y wget) \
    && mkdir -p -m 755 /etc/apt/keyrings \
    && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       | tee /etc/apt/sources.list.d/github-cli.list > /dev/null

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
    && npm install -g @openai/codex @playwright/mcp @anthropic-ai/claude-code \
    && mkdir -p /run/sshd /root/.ssh \
    && FZF_VERSION=$(curl -s https://api.github.com/repos/junegunn/fzf/releases/latest | grep tag_name | cut -d '"' -f 4 | tr -d v) \
    && curl -fsSL "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf-${FZF_VERSION}-linux_amd64.tar.gz" | tar -xz -C /usr/local/bin \
    && sh -c "$(curl -fsSL https://starship.rs/install.sh)" -- --yes \
    && chsh -s $(which zsh)

COPY ghostty.terminfo /tmp/ghostty.terminfo
RUN tic -x /tmp/ghostty.terminfo && rm /tmp/ghostty.terminfo

RUN sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

COPY bin/t /usr/local/bin/t
COPY bin/cc /usr/local/bin/cc
RUN chmod +x /usr/local/bin/t /usr/local/bin/cc

RUN echo 'eval "$(starship init zsh)"' >> /root/.zshrc \
    && echo 'source <(fzf --zsh)' >> /root/.zshrc \
    && echo 'cd ~/dev 2>/dev/null' >> /root/.zshrc

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22
CMD ["/usr/local/bin/entrypoint.sh"]
