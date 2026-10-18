#!/bin/bash
# Everything the entrypoint writes into home, run as dev on every boot. Apart
# from the entrypoint so that it runs with dev's privileges: what it creates
# comes out dev's, and a symlink in home can only steer a write somewhere dev
# could already write.
#
# Same rules as the entrypoint: -u so a typo'd name is an error rather than an
# empty string, pipefail so a pipeline does not report only its last command.
set -euo pipefail

# Docker seeds an empty home volume from the image, skeleton included. A host
# that does not -- a bind mount never does -- leaves home bare, and zsh then
# greets the first login with its new-user wizard. Only missing files are
# copied, so nothing of the user's is replaced.
if [ ! -e "$HOME/.zshrc" ]; then
  cp -r --update=none /etc/skel/. "$HOME"/
fi

mkdir -p "$HOME/.claude" "$HOME/dev"

# Claude Code default settings: the user's own file, seeded once and never
# overwritten. Written under a umask because the user may well put a token in
# it, and older images merged the ntfy bearer token into it.
SETTINGS="$HOME/.claude/settings.json"
if [ ! -f "$SETTINGS" ]; then
  (umask 077
   cat > "$SETTINGS" <<'JSON'
{
  "permissions": {
    "allow": ["Bash", "Read", "Edit", "Write", "Grep", "Glob", "WebSearch"],
    "deny": ["Bash(rm -rf:*)", "Bash(git push --force:*)", "Bash(git reset --hard:*)"],
    "defaultMode": "auto"
  },
  "alwaysThinkingEnabled": true
}
JSON
  )
fi

# Older images merged the ntfy hooks into the user's settings.json on every
# boot, bearer token and all. A home carried over from one still has them, and
# left in place they would fire alongside the managed copy the entrypoint
# writes and keep the token in home. Only entries carrying this image's own
# ntfy titles are removed -- anything else under those events is the user's --
# and the file is rewritten only when something was actually removed.
#
# The scratch file sits next to the target rather than in /tmp: home is a
# volume, so /tmp is another filesystem, and `mv` across it is a copy that
# loses atomicity and carries /tmp's mode onto the file. Same directory, same
# umask, real rename.
if [ -f "$SETTINGS" ] \
   && (umask 077
       jq 'if .hooks then
             .hooks |= (with_entries(.value |= (
                          map(.hooks |= map(select(((.command // "")
                                | test("Title: Claude (needs you|finished)")) | not)))
                          | map(select(.hooks | length > 0))))
                        | with_entries(select(.value | length > 0)))
             | if .hooks == {} then del(.hooks) else . end
           else . end' \
         "$SETTINGS" > "$SETTINGS.tmp") 2>/dev/null \
   && ! cmp -s <(jq -S . "$SETTINGS") <(jq -S . "$SETTINGS.tmp"); then
  mv "$SETTINGS.tmp" "$SETTINGS"
  echo "removed notification hooks an older image wrote into settings.json; they now come from managed settings"
fi
rm -f "$SETTINGS.tmp"

# Unconditional rather than at creation: a settings.json carried over from an
# older image is 0644 and may still have held the ntfy token.
chmod 600 "$SETTINGS"
