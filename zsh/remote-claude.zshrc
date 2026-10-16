# Sourced from /etc/zsh/zshrc, so every interactive zsh gets it before reading
# ~/.zshrc -- which stays the user's own, and wins wherever the two disagree.
# The image's shell setup lives here rather than in home so that a home on a
# volume, which keeps whatever it was first seeded with, still picks up every
# change the image makes.

# The git plugin registers completions with compdef, so compinit runs first.
autoload -Uz compinit && compinit

source /usr/local/share/remote-claude/zsh/omz/lib-git.zsh
source /usr/local/share/remote-claude/zsh/omz/git.plugin.zsh

# After the plugin, so the personal overrides win.
source /usr/local/share/remote-claude/zsh/git-aliases.zsh

# Interactive shells resolve tool versions on every prompt rather than through
# the shims remote-claude.zshenv puts on PATH, which also applies a trusted
# project's [env].
eval "$(mise activate zsh)"
eval "$(starship init zsh)"
source <(fzf --zsh)
eval "$(gs shell completion zsh)"

cd ~/dev 2>/dev/null
