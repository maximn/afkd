# Git shortcuts for the remote box.
# Split by responsibility: raw git for inspect/stage/stash (git-spice doesn't
# cover these), plain fallbacks for non-stacked repos, and git-spice itself for
# the branch lifecycle / sync / submit / stack workflow.

# --- raw git: inspect / stage / stash ---
alias gst='git status'
alias gd='git diff'
alias gds='git diff --staged'
alias gaa='git add --all'
alias ga='git add'
alias gco='git checkout'
alias gsw='git switch'
alias gb='git branch'
alias gsta='git stash'
alias gstp='git stash pop'

# --- plain fallbacks for repos not using git-spice ---
alias gl='git pull'
alias gp='git push'
alias glog='git log --oneline --decorate --graph'

# --- git-spice: branch lifecycle / sync / submit / stack log ---
# gs bc (branch create), gs cc (commit create), gs bco (branch checkout),
# gs rs (repo sync), gs bs/ss (branch/stack submit), gs ls (log short), gs up/down
alias gs='git-spice'
