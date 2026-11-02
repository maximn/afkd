# Sourced from /etc/zsh/zshrc, so every interactive zsh gets it before reading
# ~/.zshrc -- which stays the user's own, and wins wherever the two disagree.
# The image's shell setup lives here rather than in home so that a home on a
# volume, which keeps whatever it was first seeded with, still picks up every
# change the image makes.

# The git plugin registers completions with compdef, so compinit runs first.
autoload -Uz compinit && compinit

# Stock zsh leaves the main keymap on vi insert when nothing picks one, so
# Ctrl+A and Ctrl+E would self-insert. The box is used with emacs keys.
bindkey -e

# Typing a directory's name changes into it, so `..` and `../..` work without
# an alias for each depth. Stock zsh leaves this off.
setopt AUTO_CD

source /usr/local/share/afkd/zsh/omz/lib-git.zsh
source /usr/local/share/afkd/zsh/omz/git.plugin.zsh

# After the plugin, so the personal overrides win.
source /usr/local/share/afkd/zsh/git-aliases.zsh

# Interactive shells resolve tool versions on every prompt rather than through
# the shims afkd.zshenv puts on PATH, which also applies a trusted
# project's [env].
eval "$(mise activate zsh)"
eval "$(starship init zsh)"
source <(fzf --zsh)
eval "$(gs shell completion zsh)"

# eza under names of its own rather than over ls: an agent's shell can read
# this file too, and what ls prints is what it parses.
alias ll='eza -l --git --group-directories-first'
alias la='eza -la --git --group-directories-first'
alias lt='eza -T --git-ignore -L 2'

cd ~/dev 2>/dev/null
