# Sourced from /etc/zsh/zshenv, so every zsh on the box reads it: ssh
# commands, interactive logins and the shells agents spawn. Keep it to
# environment -- nothing here may print or prompt.

# mise's shims resolve a tool's version per directory, for shells that never
# run `mise activate`. The user's own shim directory holds versions installed
# for projects; the system one holds the image's defaults. ~/.local/bin is
# where npm's global installs land (below).
typeset -U path
path=("$HOME/.local/bin" "$HOME/.local/share/mise/shims" /usr/local/share/mise/shims $path)

# The default Node is installed system-wide and owned by the image, and mise
# reshims only the user's directory after `npm i -g` -- so a global install
# into it would land where nothing on PATH points. Global CLIs go to home
# instead, which also keeps them across a Node version change.
export NPM_CONFIG_PREFIX="$HOME/.local"

# npm ignores XDG on Linux and caches to ~/.npm. ~/.cache is where every
# other cache on the box lives, and the one that persists across redeploys.
export NPM_CONFIG_CACHE="$HOME/.cache/npm"

# corepack would otherwise stop at a y/N prompt the first time a project's
# package manager is fetched -- which an agent's non-interactive shell never
# answers.
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

# What git, gh, git-spice, crontab and the agents open for an edit. Set
# explicitly rather than left to the `vi` fallback: Claude Code and Codex read
# VISUAL/EDITOR themselves and have no fallback of their own.
export EDITOR=vim VISUAL=vim

# Inside a herdr or tmux pane, this shell and everything it starts -- agents,
# and the builds and test runs they kick off -- go to the back of the queue:
# first in line for an OOM killer (the kernel's, and the earlyoom the
# entrypoint runs), and behind sshd and herdr for the CPU, so the way back in
# stays responsive while agents saturate the box. The first shell in a pane
# does it and everything under it inherits it, so an agent's own subshells
# skip the renice. Raising both is something any process may do to itself;
# only lowering them takes root.
if [[ -n ${HERDR_ENV:-}${TMUX:-} && $(</proc/$$/oom_score_adj) -lt 500 ]]; then
  print 500 >| /proc/$$/oom_score_adj
  renice -n 10 -p $$ >/dev/null
fi 2>/dev/null

# API keys and tokens forwarded from the container's environment, rebuilt by
# the entrypoint on every boot. sshd starts each session with a clean
# environment, so this is how they reach an ssh command or an agent at all.
[[ -r /run/afkd/env.zsh ]] && source /run/afkd/env.zsh
