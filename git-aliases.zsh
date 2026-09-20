# Personal git aliases for the remote box.
#
# The bulk of the g* shortcuts (gst, gl, gp, gd, gco, gcb, gaa, gwip, gpsup, ...)
# come from the oh-my-zsh git plugin, which mirrors the local machine. Only
# deliberate divergences from that plugin belong here, and this file is sourced
# after oh-my-zsh so they win.

# The plugin resolves the trunk via git_main_branch, which probes the remote and
# falls back to master. Every repo reachable from this box uses main, so skip
# the probe and keep gcm usable when the remote is unreachable.
alias gcm='git checkout main'

# git-spice drives the stacked-branch workflow and is on PATH as `gs` via a
# symlink created in the Dockerfile; no alias needed.
