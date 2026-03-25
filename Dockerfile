FROM node:20-slim

RUN (type -p wget >/dev/null || apt-get update && apt-get install -y wget) \
    && mkdir -p -m 755 /etc/apt/keyrings \
    && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       | tee /etc/apt/sources.list.d/github-cli.list > /dev/null

RUN apt-get update && apt-get install -y \
    openssh-server \
    git \
    tmux \
    curl \
    gh \
    ripgrep \
    fd-find \
    jq \
    python3 \
    make \
    zsh \
    fzf \
    procps \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code @openai/codex \
    && mkdir -p /run/sshd /root/.ssh \
    && sh -c "$(curl -fsSL https://starship.rs/install.sh)" -- --yes \
    && chsh -s $(which zsh)

RUN sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

COPY bin/t /usr/local/bin/t
RUN chmod +x /usr/local/bin/t

RUN echo 'eval "$(starship init zsh)"' >> /root/.zshrc \
    && echo 'source <(fzf --zsh)' >> /root/.zshrc

WORKDIR /workspace
EXPOSE 22

CMD if [ ! -f /root/.config/ssh_host_ed25519_key ]; then \
      ssh-keygen -A && \
      cp /etc/ssh/ssh_host_*_key* /root/.config/; \
    else \
      cp /root/.config/ssh_host_*_key* /etc/ssh/; \
    fi && \
    ln -sf /root/.claude/.claude.json /root/.claude.json && \
    echo "${SSH_PUBLIC_KEYS}" > /root/.ssh/authorized_keys && \
    chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys && \
    git config --global user.name "${GIT_USER_NAME:-Novak}" && \
    git config --global user.email "${GIT_USER_EMAIL:-your@email.com}" && \
    env | grep -E '^(GH_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY|CODEX_|CLAUDE_)' | sed 's/^/export /' > /root/.zshenv && \
    if [ ! -f /root/.claude/settings.json ]; then \
      mkdir -p /root/.claude && \
      echo '{"permissions":{"allow":["Bash","Read","Edit","Write","Grep","Glob","WebSearch"],"deny":["Bash(rm -rf:*)","Bash(git push --force:*)","Bash(git reset --hard:*)"],"defaultMode":"auto"},"alwaysThinkingEnabled":true}' > /root/.claude/settings.json; \
    fi && \
    /usr/sbin/sshd -D
