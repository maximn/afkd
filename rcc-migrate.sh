#!/bin/bash
# rcc-migrate - move a root-era deployment into dev's home, once.
#
# Images before the dev user ran everything as root, with a volume per
# directory under /root. Run this on the deploy that mounts the new volumes
# and still has the old ones at their old paths (the runbook is in coolify.md
# in the remote-claude-code repo):
#
#   /root/.claude        -> ~/.claude, its .claude.json moved up to ~/.claude.json
#   /root/.config        -> ~/.config, less the SSH host keys
#   /root/.codex         -> ~/.codex
#   /root/dev            -> ~/dev
#   /root/.local/share   -> ~/.local/share
#
# Claude Code's per-project state is re-keyed from /root/... to /home/dev/...
# to follow the projects, and ~/.cache -- the old cache volume, reused -- is
# handed to dev. The host keys are not this script's: the entrypoint adopts
# them at boot, before sshd needs them.
#
# Usage: sudo rcc-migrate [--dry-run] [--force]
#   --dry-run  print what would be done, and do nothing
#   --force    run again after a completed migration
set -euo pipefail

TARGET=/home/dev
MARKER=/var/lib/remote-claude/migrated-from-root
SOURCES=(.claude .config .codex dev .local/share)

dry_run=0
force=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --force) force=1 ;;
    -h | --help) sed -n '2,/^set /{/^set /d; s/^# \{0,1\}//; p;}' "$0"; exit 0 ;;
    *) echo "rcc-migrate: unknown option '$arg' (see --help)" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" != 0 ]; then
  echo "rcc-migrate reads /root, which only root can: run it as 'sudo rcc-migrate'." >&2
  exit 1
fi

# A second run copies the old tree back over everything done in the new home
# since -- settings changed, sessions written, branches committed.
if [ -e "$MARKER" ] && [ "$force" = 0 ]; then
  echo "already migrated ($(cat "$MARKER")). Running again would copy the old" \
       "/root tree back over everything changed in $TARGET since; pass --force to do it anyway." >&2
  exit 1
fi

found=()
for dir in "${SOURCES[@]}"; do
  if [ -n "$(ls -A "/root/$dir" 2>/dev/null)" ]; then
    found+=("$dir")
  fi
done
# The likeliest mistake is running this after the old volumes are gone, and
# "done" there would read as "migrated".
if [ "${#found[@]}" = 0 ]; then
  echo "nothing to migrate: none of /root/{.claude,.config,.codex,dev,.local/share} holds anything." \
       "Mount the old volumes at their old paths and run this again." >&2
  exit 1
fi

say() {
  if [ "$dry_run" = 1 ]; then echo "would $*"; else echo "$*"; fi
}

for dir in "${found[@]}"; do
  say "copy /root/$dir -> $TARGET/$dir"
  [ "$dry_run" = 1 ] && continue
  install -d -o dev -g dev "$(dirname "$TARGET/$dir")"
  # .claude.json is lifted out below; the host keys stay with root.
  case "$dir" in
    .claude) exclude=(--exclude=/.claude.json) ;;
    .config) exclude=(--exclude='/ssh_host_*') ;;
    *) exclude=() ;;
  esac
  rsync -a --chown=dev:dev "${exclude[@]}" "/root/$dir/" "$TARGET/$dir/"
done

# Claude Code keys per-project trust, settings and history by absolute path.
# Projects moved from /root/dev to /home/dev/dev, so the keys follow them.
LEGACY_STATE=/root/.claude/.claude.json
if [ -f "$LEGACY_STATE" ]; then
  say "move $LEGACY_STATE -> $TARGET/.claude.json, re-keying projects under /root"
  if [ "$dry_run" = 0 ]; then
    tmp="$(mktemp)"
    jq 'if .projects then
          .projects |= with_entries(
            if .key == "/root" or (.key | startswith("/root/"))
            then .key = "/home/dev" + .key[5:] else . end)
        else . end' "$LEGACY_STATE" > "$tmp"
    install -o dev -g dev -m 600 "$tmp" "$TARGET/.claude.json"
    rm -f "$tmp"
  fi
fi

# The same paths, encoded as directory names: every character that is not a
# letter or digit becomes '-', so /root/dev/app is -root-dev-app.
PROJECTS="$TARGET/.claude/projects"
if [ "$dry_run" = 1 ]; then PROJECTS=/root/.claude/projects; fi
for old in "$PROJECTS"/-root "$PROJECTS"/-root-*; do
  [ -d "$old" ] || continue
  name="$(basename "$old")"
  new="$TARGET/.claude/projects/-home-dev${name#-root}"
  say "rename Claude Code project $name -> $(basename "$new")"
  [ "$dry_run" = 1 ] && continue
  if [ -e "$new" ]; then
    cp -a "$old/." "$new/"
    rm -rf "$old"
  else
    mv "$old" "$new"
  fi
done

if [ -n "$(find "$TARGET/.cache" ! -user dev -print -quit 2>/dev/null)" ]; then
  say "hand $TARGET/.cache to dev"
  [ "$dry_run" = 0 ] && chown -R dev:dev "$TARGET/.cache"
fi

[ "$dry_run" = 1 ] && exit 0

# Strips the notification hooks older images merged into settings.json, the
# same clean-up the next boot would do.
runuser -u dev -- /usr/local/libexec/remote-claude/home-init

date -u +%Y-%m-%dT%H:%M:%SZ > "$MARKER"
echo "done. Remove the old /root volumes from the deployment and redeploy."
