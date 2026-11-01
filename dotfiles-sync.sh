#!/bin/bash
# Keeps the user's chezmoi dotfiles applied: every DOTFILES_SYNC_INTERVAL
# seconds it pulls the repo and applies it, so a change pushed from a laptop
# reaches the box without anyone logging in. Started by the entrypoint as dev,
# with only PATH, HOME, the ntfy settings and BOX_NAME. A home with no chezmoi
# source directory is skipped on every pass, so a repo set up later is picked
# up without a restart.
#
# chezmoi runs through zsh so that it gets what a session gets -- the mise
# shims and ~/.local/bin on PATH, GH_TOKEN for a private repo -- because the
# scripts a dotfiles repo runs on apply expect a session's tools. The ntfy
# settings are held back from it: those scripts are the repo's code, not the
# image's.
#
# A file edited on the box since chezmoi last wrote it is a conflict: it is
# left alone, the rest is still applied, and the pass counts as failed. A
# failure pages once, on the first failed pass after one that was not, rather
# than every interval until someone looks.
set -uo pipefail

interval="${DOTFILES_SYNC_INTERVAL:-3600}"
source_dir="$HOME/.local/share/chezmoi"

notify_failure() {
  [ -n "${NTFY_URL:-}" ] || return 0
  local auth=()
  if [ -n "${NTFY_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer ${NTFY_TOKEN}")
  fi
  curl -s -o /dev/null --max-time 10 "${auth[@]}" \
    -H "Title: Dotfiles sync failed${BOX_NAME:+ (${BOX_NAME})}" -H 'Tags: warning' \
    --data-binary "chezmoi update failed; run chezmoi status on the box to see what needs attention" \
    "${NTFY_URL}" || true
}

failing=0
while :; do
  if [ -d "$source_dir" ]; then
    if env -u NTFY_URL -u NTFY_TOKEN zsh -c \
         'chezmoi update --init --no-tty --keep-going --error-on-conflict' </dev/null 2>&1 \
         | sed -u 's/^/dotfiles-sync: /'; then
      failing=0
    elif [ "$failing" -eq 0 ]; then
      failing=1
      echo "dotfiles-sync: failed; run chezmoi status to see why" >&2
      notify_failure
    fi
  fi
  sleep "$interval"
done
