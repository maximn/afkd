#!/bin/bash
# Catches a chezmoi dotfiles repo up once, at boot, so a change pushed while the
# box was down is not missed. While the box is up, changes reach it when a
# laptop runs chezmoi update over ssh. Started by the entrypoint as dev, with
# only PATH, HOME, the ntfy settings and BOX_NAME.
#
# chezmoi runs through zsh so that it gets what a session gets -- the mise
# shims and ~/.local/bin on PATH, GH_TOKEN for a private repo -- because the
# scripts a dotfiles repo runs on apply expect a session's tools. The ntfy
# settings are held back from it: those scripts are the repo's code, not the
# image's.
#
# A file edited on the box since chezmoi last wrote it is a conflict: it is
# left alone, the rest is still applied, and the pass counts as failed. Nobody
# is watching a boot, so a failure pages.
set -uo pipefail

[ -d "$HOME/.local/share/chezmoi" ] || exit 0

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

if ! env -u NTFY_URL -u NTFY_TOKEN zsh -c \
     'chezmoi update --init --no-tty --keep-going --error-on-conflict' </dev/null 2>&1 \
     | sed -u 's/^/dotfiles-sync: /'; then
  echo "dotfiles-sync: failed; run chezmoi status to see why" >&2
  notify_failure
  exit 1
fi
