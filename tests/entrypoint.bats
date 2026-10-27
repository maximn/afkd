#!/usr/bin/env bats
#
# entrypoint.sh behaviour. Each test here corresponds to a failure mode that
# has actually reached production (see git log): empty SSH_PUBLIC_KEYS, the
# base64-vs-PEM GITHUB_SSH_KEY flip-flop, and unquoted .zshenv exports.

load helpers

setup_file() {
  generate_keypair
}

teardown() {
  cleanup_box
}

# --- SSH_PUBLIC_KEYS ---------------------------------------------------------

@test "refuses to start when SSH_PUBLIC_KEYS is unset" {
  local vol
  vol="$(make_volume)"
  run docker run --rm --label "${LABEL}=1" -v "${vol}:/var/lib/afkd" "$IMAGE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SSH_PUBLIC_KEYS is empty"* ]]
}

@test "refuses to start when SSH_PUBLIC_KEYS is empty" {
  local vol
  vol="$(make_volume)"
  run docker run --rm --label "${LABEL}=1" -v "${vol}:/var/lib/afkd" \
    -e SSH_PUBLIC_KEYS= "$IMAGE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SSH_PUBLIC_KEYS is empty"* ]]
}

@test "boots with no volumes mounted" {
  # Nothing in the image creates /var/lib/afkd, but the entrypoint
  # keeps the host keys there. A deployment always mounts a volume on it; a
  # bare `docker run` must still work, or the image is undebuggable locally.
  boot_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready
}

# Written outside home, root-owned, and rewritten on every boot: sshd reads
# keys from nowhere else (AuthorizedKeysFile), so dropping a key from
# SSH_PUBLIC_KEYS revokes it on the next boot even once home is a volume that
# would otherwise carry a stale authorized_keys forward.
@test "installs every public key line into a root-owned file outside home" {
  start_box -e SSH_PUBLIC_KEYS="${PUBKEY}"$'\n'"ssh-ed25519 AAAAsecondkey other@host"
  wait_ready

  run in_box wc -l /etc/ssh/authorized_keys/dev
  [[ "$output" == 2* ]]

  run in_box grep -cF "$PUBKEY_BARE" /etc/ssh/authorized_keys/dev
  [ "$output" = "1" ]

  run in_box stat -c '%U %a' /etc/ssh/authorized_keys/dev
  [ "$output" = "root 644" ]

  run in_box test -e /home/dev/.ssh/authorized_keys
  [ "$status" -ne 0 ]

  # Nobody logs in as root, so nothing should be authorized as root either.
  run in_box test -e /etc/ssh/authorized_keys/root
  [ "$status" -ne 0 ]
}

# --- SSH host keys -------------------------------------------------------------

HOST_KEYS=/var/lib/afkd/ssh

@test "keeps the host keys on the system volume, readable by root alone" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run in_box stat -c '%U %a' "$HOST_KEYS" "$HOST_KEYS/ssh_host_ed25519_key"
  [ "$output" = $'root 700\nroot 600' ]

  # Not in home: dev owns home, and a host private key it could read is one it
  # could impersonate the box with.
  run in_box sh -c 'ls /home/dev/.config/ssh_host_* 2>/dev/null'
  [ -z "$output" ]
}

# Before the dev user, the keys were persisted in /root/.config. The first
# boot of this image on that deployment -- the one afkd-migrate runs on -- has
# to come up as the same host, or every client sees its key change.
@test "adopts the host keys an older image persisted in /root/.config" {
  local legacy want
  legacy="$(make_volume)"
  docker run --rm --label "${LABEL}=1" -v "${legacy}:/root/.config" \
    --entrypoint sh "$IMAGE" -c 'ssh-keygen -A >/dev/null && cp /etc/ssh/ssh_host_*_key* /root/.config/'
  want="$(docker run --rm --label "${LABEL}=1" -v "${legacy}:/root/.config" \
    --entrypoint ssh-keygen "$IMAGE" -lf /root/.config/ssh_host_ed25519_key.pub)"

  start_box -v "${legacy}:/root/.config" -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run in_box ssh-keygen -lf "$HOST_KEYS/ssh_host_ed25519_key.pub"
  [ -n "$want" ]
  [ "$output" = "$want" ]

  run in_box stat -c '%U %a' "$HOST_KEYS/ssh_host_ed25519_key"
  [ "$output" = "root 600" ]
}

# --- home ---------------------------------------------------------------------

@test "hands dev a home it owns, with the seeded files in it" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run in_box stat -c '%U' /home/dev /home/dev/.cache /home/dev/.zshrc \
    /home/dev/.claude /home/dev/.claude/settings.json /home/dev/dev
  [ "$output" = $'dev\ndev\ndev\ndev\ndev\ndev' ]
}

# Docker seeds an empty named volume from the image's /home/dev, which is
# where the ownership and the skeleton files come from. Nothing documents
# that every host does it -- a bind mount never does -- so an empty,
# root-owned home is made dev's and given the skeleton at boot.
@test "makes an unseeded empty home usable" {
  boot_box --tmpfs /home/dev -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run in_box stat -c '%U' /home/dev /home/dev/.zshrc /home/dev/.claude/settings.json
  [ "$output" = $'dev\ndev\ndev' ]
}

# A home that is not dev's and not empty is somebody's data -- most likely
# the old /root volumes mounted at the new path. Taking it over recursively
# is not the entrypoint's call, and refusing to boot would lock out the one
# person who can fix it, so it says so and comes up.
@test "warns about a home dev does not own, and still boots" {
  local vol
  vol="$(make_volume)"
  docker run --rm --label "${LABEL}=1" -v "${vol}:/home/dev" \
    --entrypoint sh "$IMAGE" -c 'chown -R root:root /home/dev'

  HOME_VOL="$vol" start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run box_logs
  [[ "$output" == *"warning: /home/dev is owned by root"* ]]

  run in_box stat -c '%U' /home/dev
  [ "$output" = "root" ]
}

# --- git identity ------------------------------------------------------------

@test "sets the git identity from the environment" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" \
    -e GIT_USER_NAME='Ada Lovelace' -e GIT_USER_EMAIL='ada@example.com'
  wait_ready

  run in_box git config --system user.name
  [ "$output" = 'Ada Lovelace' ]

  run in_box git config --system user.email
  [ "$output" = 'ada@example.com' ]

  # System-level, so a ~/.gitconfig of the user's own still wins, and the
  # deployment's identity never lands in home.
  run in_box test -e /home/dev/.gitconfig
  [ "$status" -ne 0 ]
}

@test "leaves the git identity unset rather than inventing one" {
  # These used to fall back to the name and email of this repo's author, so
  # every other deployment committed under an identity that had never touched
  # the code. An unset identity makes git say so at commit time; a wrong one
  # is silent and ends up in history.
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run in_box git config --system user.name
  [ "$status" -ne 0 ]

  run in_box git config --system user.email
  [ "$status" -ne 0 ]

  run box_logs
  [[ "$output" == *"GIT_USER_NAME and/or GIT_USER_EMAIL are unset"* ]]
}

@test "warns when only half the git identity is set" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e GIT_USER_NAME='Ada Lovelace'
  wait_ready

  run in_box git config --system user.name
  [ "$output" = 'Ada Lovelace' ]

  run in_box git config --system user.email
  [ "$status" -ne 0 ]

  run box_logs
  [[ "$output" == *"GIT_USER_NAME and/or GIT_USER_EMAIL are unset"* ]]
}

# --- GITHUB_SSH_KEY ----------------------------------------------------------
#
# The key must come out usable whichever form Coolify hands it over in. The
# strongest assertion available is that ssh-keygen can derive the matching
# public key from the file the entrypoint wrote.

# The key lives under /run, regenerated from the environment on every boot,
# and is wired in through the system ssh_config.d -- so it never reaches home,
# and ~/.ssh/config stays the user's own.
GITHUB_KEY=/run/afkd/github_ed25519

# What ssh would actually do for github.com, rather than what one file says:
# `ssh -G` prints the configuration after every Include has been merged. Its
# stderr goes: OpenSSH 10 warns there about a pty whenever stdin is not one.
assert_ssh_uses_github_key() {
  run as_dev sh -c 'ssh -G github.com 2>/dev/null | grep -i "^identityfile "'
  [ "$output" = "identityfile ${GITHUB_KEY}" ]
}

# Read as dev, since that is who runs git: ssh refuses a key that is not
# private to the user reading it, and a root-only file is unreadable.
assert_github_key_usable() {
  # ssh-keygen echoes the comment stored in the private key, so compare the
  # type and blob only.
  run as_dev sh -c "ssh-keygen -y -f ${GITHUB_KEY} | cut -d' ' -f1,2"
  [ "$status" -eq 0 ]
  [ "$output" = "$PUBKEY_BARE" ]

  run in_box stat -c '%U %a' "$GITHUB_KEY"
  [ "$output" = "dev 600" ]

  assert_ssh_uses_github_key

  run in_box sh -c 'ls /home/dev/.ssh/github* 2>/dev/null'
  [ -z "$output" ]
}

@test "accepts GITHUB_SSH_KEY as a raw PEM key" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e GITHUB_SSH_KEY="$PRIVKEY"
  wait_ready
  assert_github_key_usable
}

@test "accepts GITHUB_SSH_KEY as base64" {
  local b64
  b64="$(printf '%s\n' "$PRIVKEY" | base64 | tr -d '\n')"
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e GITHUB_SSH_KEY="$b64"
  wait_ready
  assert_github_key_usable
}

@test "accepts base64 GITHUB_SSH_KEY that arrives with CRLFs" {
  # Coolify has handed back CRLF-wrapped values before; openssl then failed
  # with an opaque libcrypto error.
  local b64
  b64="$(printf '%s\n' "$PRIVKEY" | base64 | sed 's/$/\r/')"
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e GITHUB_SSH_KEY="$b64"
  wait_ready
  assert_github_key_usable
}

@test "adds the trailing newline ssh requires to a base64 key without one" {
  # The only input that reaches the newline repair. $PRIVKEY has already lost
  # its trailing newline to the command substitution in generate_keypair, and
  # the PEM branch writes with `printf '%s\n'`, which puts one back
  # unconditionally -- so a "PEM without a newline" test is byte-for-byte the
  # raw-PEM test above and the repair is unreachable through it. base64 is
  # decoded straight to the file, so a payload whose decoded bytes stop short
  # is what actually needs fixing up.
  local b64
  b64="$(printf '%s' "$PRIVKEY" | base64 | tr -d '\n')"
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e GITHUB_SSH_KEY="$b64"
  wait_ready
  assert_github_key_usable

  run in_box tail -c1 "$GITHUB_KEY"
  [ -z "$output" ]
}

@test "accepts a PEM key that arrives with its trailing newline" {
  # What a real multiline Coolify variable hands over: the value keeps its
  # final newline and `printf '%s\n'` then adds a second one.
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e GITHUB_SSH_KEY="${PRIVKEY}"$'\n'
  wait_ready
  assert_github_key_usable
}

@test "survives a malformed GITHUB_SSH_KEY without blocking login" {
  # A bad key must never stop sshd: you need a way in to fix it.
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e GITHUB_SSH_KEY="this is not a key"
  wait_ready

  run box_logs
  [[ "$output" == *"warning: GITHUB_SSH_KEY"* ]]

  run in_box test -e "$GITHUB_KEY"
  [ "$status" -ne 0 ]
}

@test "writes no ssh client config when GITHUB_SSH_KEY is unset" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run in_box sh -c 'ls /etc/ssh/ssh_config.d/*github* /home/dev/.ssh/config 2>/dev/null'
  [ -z "$output" ]
}

@test "boots with a usable GitHub key even with no network" {
  # Boots race the network -- a Coolify restart ahead of its DNS, an egress
  # firewall, a flaky resolver. GitHub's host keys used to come from an
  # ssh-keyscan here, which under `set -e` aborted the entrypoint before
  # `exec sshd` and left a container nobody could log in to and fix. They are
  # pinned now, so a boot with no network still records them.
  # GITHUB_SSH_KEY has to be set or the GitHub setup is never reached.
  start_box --network none -e SSH_PUBLIC_KEYS="$PUBKEY" -e GITHUB_SSH_KEY="$PRIVKEY"
  wait_ready

  run in_box ssh-keygen -lf /etc/ssh/ssh_known_hosts
  [[ "$output" == *"SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU github.com (ED25519)"* ]]

  # Everything that does not need the network still has to have happened.
  run in_box stat -c '%U %a' "$GITHUB_KEY"
  [ "$output" = "dev 600" ]

  assert_ssh_uses_github_key
}

# --- env forwarding -----------------------------------------------------------

# `docker exec` hands the exec'd process the container's own environment -- the
# very `-e` values passed to `docker run`. Reading the variable back without
# clearing it first asserts nothing about .zshenv: these three tests passed
# with every `printf 'export ...'` line deleted from the entrypoint, which is
# the exact regression (d432f20) they were written to guard. `env -u` clears
# it, and every zsh sources /etc/zsh/zshenv, which reads the forwarded file.
@test "round-trips env values containing spaces, quotes and metacharacters" {
  local awkward='a b "c" '"'"'d'"'"' $e `f` \g'
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e ANTHROPIC_API_KEY="$awkward"
  wait_ready

  run as_dev env -u ANTHROPIC_API_KEY zsh -c 'printf %s "$ANTHROPIC_API_KEY"'
  [ "$status" -eq 0 ]
  [ "$output" = "$awkward" ]
}

@test "round-trips a multiline env value" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e ANTHROPIC_API_KEY=$'line one\nline two'
  wait_ready

  run as_dev env -u ANTHROPIC_API_KEY zsh -c 'printf %s "$ANTHROPIC_API_KEY"'
  [ "$status" -eq 0 ]
  [ "$output" = $'line one\nline two' ]
}

@test "forwards CLAUDE_* and CODEX_* vars and skips unset ones" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" \
    -e CLAUDE_CODE_USE_BEDROCK=1 -e CODEX_HOME=/home/dev/.codex
  wait_ready

  run as_dev env -u CLAUDE_CODE_USE_BEDROCK -u CODEX_HOME \
    zsh -c 'printf "%s|%s" "$CLAUDE_CODE_USE_BEDROCK" "$CODEX_HOME"'
  [ "$output" = "1|/home/dev/.codex" ]

  run in_box grep -c 'GH_TOKEN' /run/afkd/env.zsh
  [ "$output" = "0" ]

  run in_box stat -c '%U %a' /run/afkd/env.zsh
  [ "$output" = "dev 600" ]
}

# Compose passes a referenced-but-unset ${VAR} as an empty string, not as
# unset, so a deployment that declares every optional variable sets all of them.
# Forwarded as-is, an empty GH_TOKEN or ANTHROPIC_API_KEY reaches every session
# and reads as "this credential, and it is blank" to whatever looks for it.
@test "skips forwarded vars that are set but empty" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" \
    -e GH_TOKEN= -e ANTHROPIC_API_KEY= -e CLAUDE_CODE_USE_BEDROCK= -e CODEX_HOME=/home/dev/.codex
  wait_ready

  run in_box grep -cE 'GH_TOKEN|ANTHROPIC_API_KEY|CLAUDE_CODE_USE_BEDROCK' /run/afkd/env.zsh
  [ "$output" = "0" ]

  run as_dev env -u GH_TOKEN zsh -c '[ -z "${GH_TOKEN+x}" ] && printf %s "$CODEX_HOME"'
  [ "$status" -eq 0 ]
  [ "$output" = "/home/dev/.codex" ]
}

# The forwarded values are API keys and tokens. Written under /run they are
# rebuilt from the environment on every boot, so unsetting one on the
# deployment removes it from the box -- and none of them is ever written to
# home, which becomes a volume that would keep them.
@test "keeps forwarded secrets out of home" {
  local secret="sk-test-$RANDOM$RANDOM"
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e ANTHROPIC_API_KEY="$secret" \
    -e GH_TOKEN="$secret" -e NTFY_URL=https://ntfy.example.com/c -e NTFY_TOKEN="$secret"
  wait_ready

  run in_box grep -rlF "$secret" /home/dev /root
  [ -z "$output" ]
}

# --- Claude Code settings ----------------------------------------------------

@test "seeds a valid default settings.json" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run in_box jq -e '.permissions.defaultMode' /home/dev/.claude/settings.json
  [ "$status" -eq 0 ]

  run in_box jq -e '.hooks' /home/dev/.claude/settings.json
  [ "$status" -ne 0 ]
}

# The hooks are the deployment's, not the user's, so they live in Claude
# Code's managed settings: rebuilt every boot, merged by Claude over whatever
# the user has, and never written into home along with the token they carry.
NTFY_SETTINGS=/etc/claude-code/managed-settings.d/50-ntfy.json

# BOX_NAME arrives empty, as it does from a compose file that leaves it
# blank: no name means the titles carry none, not an empty "()".
@test "writes notification hooks to managed settings when NTFY_URL is set" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" \
    -e NTFY_URL=https://ntfy.example.com/claude -e NTFY_TOKEN=tk_test -e BOX_NAME=
  wait_ready

  run hook_argv "$(notification_hook_command)" '{"message":"permission needed"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARG[https://ntfy.example.com/claude]"* ]]
  [[ "$output" == *"ARG[Authorization: Bearer tk_test]"* ]]
  [[ "$output" == *"ARG[Title: Claude needs you]"* ]]

  run hook_argv "$(stop_hook_command)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARG[turn complete]"* ]]
  [[ "$output" == *"ARG[Title: Claude finished]"* ]]

  # A hook's stdout is read by Claude Code as its decision, so the ntfy
  # server's response must never reach it.
  run in_box jq -r '.hooks[][].hooks[].command' "$NTFY_SETTINGS"
  [ "$(grep -c -- '-o /dev/null' <<<"$output")" -eq 2 ]

  # It holds a bearer token, so it is readable by root and by the group of the
  # one user Claude Code runs as, and nobody else.
  run in_box stat -c '%U:%G %a' "$NTFY_SETTINGS"
  [ "$output" = "root:dev 640" ]

  run as_dev jq -e '.hooks.Stop' "$NTFY_SETTINGS"
  [ "$status" -eq 0 ]

  # The user's own settings stay untouched.
  run in_box jq -e '.hooks' /home/dev/.claude/settings.json
  [ "$status" -ne 0 ]
}

@test "writes no notification hooks when NTFY_URL is unset" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run in_box test -e "$NTFY_SETTINGS"
  [ "$status" -ne 0 ]
}

# Older images merged the hooks into the user's settings.json on every boot,
# token and all. A volume written by one still carries them: left there they
# would fire twice -- once from there, once from managed settings -- and keep
# the token in home. Only the entries this image wrote are removed.
@test "removes notification hooks an older image merged into settings.json" {
  local vol
  vol="$(make_volume)"
  seed_home "$vol" 'mkdir -p ~/.claude && cat > ~/.claude/settings.json' <<'JSON'
{
  "permissions": {"defaultMode": "plan"},
  "hooks": {
    "Notification": [{"hooks": [{"type": "command",
      "command": "jq -r .message | curl -s -H 'Authorization: Bearer tk_old' -H 'Title: Claude needs you' --data-binary @- https://ntfy.example.com/c"}]}],
    "Stop": [
      {"hooks": [{"type": "command",
        "command": "curl -s -H 'Authorization: Bearer tk_old' -H 'Title: Claude finished' -d 'turn complete' https://ntfy.example.com/c"}]},
      {"hooks": [{"type": "command", "command": "echo mine"}]}
    ],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "echo also mine"}]}]
  }
}
JSON

  HOME_VOL="$vol" start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run in_box grep -c tk_old /home/dev/.claude/settings.json
  [ "$output" = "0" ]

  run in_box jq -c '[.hooks.Stop[].hooks[].command]' /home/dev/.claude/settings.json
  [ "$output" = '["echo mine"]' ]

  run in_box jq -e '.hooks.Notification' /home/dev/.claude/settings.json
  [ "$status" -ne 0 ]

  run in_box jq -re '.hooks.PreToolUse[0].hooks[0].command' /home/dev/.claude/settings.json
  [ "$output" = "echo also mine" ]

  run in_box jq -re '.permissions.defaultMode' /home/dev/.claude/settings.json
  [ "$output" = "plan" ]
}

@test "locks down settings.json even with no notification hooks" {
  # The umask at creation, rather than the chmod after the merge.
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run in_box stat -c '%a' /home/dev/.claude/settings.json
  [ "$output" = "600" ]
}

@test "relocks a settings.json restored from a volume written by an older image" {
  # Volumes outlive images. A box redeployed onto this version has to repair
  # the 0644 file its predecessor left behind, not just get the mode right on
  # the files it creates itself.
  local vol
  vol="$(make_volume)"
  seed_home "$vol" 'mkdir -p ~/.claude && echo "{}" > ~/.claude/settings.json && chmod 644 ~/.claude/settings.json'

  HOME_VOL="$vol" start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run in_box stat -c '%a' /home/dev/.claude/settings.json
  [ "$output" = "600" ]
}

# --- hook command quoting ----------------------------------------------------
#
# The two hook commands are strings Claude Code hands to a shell. NTFY_TOKEN
# and NTFY_URL used to be spliced into hand-written quotes -- the token into
# "..." and the URL into '...' -- so a backtick, a $(...) or the matching quote
# broke out and ran as the agent. Every payload below did exactly that before
# the values were shell-quoted with %q.
#
# Asserting on the command string alone is not enough: one that reads fine can
# still be cutting a token in half. Swapping curl for a stub that prints its
# argv shows what the hook would actually send.
#
# The hook runs in the agent's session, which carries none of the box's own
# environment, so it runs here without BOX_NAME: a hook that read it at
# runtime instead of carrying it from boot would otherwise pass. The second
# argument is the hook's stdin, Claude's event.
stub_curl() {
  docker exec -i "$BOX" bash -s <<'STUB'
mkdir -p /tmp/stub
cat > /tmp/stub/curl <<'CURL'
#!/bin/bash
printf 'ARG[%s]\n' "$@"
CURL
chmod +x /tmp/stub/curl
STUB
}

hook_argv() {
  stub_curl
  docker exec -i "$BOX" env -u BOX_NAME \
    bash -c 'PATH=/tmp/stub:$PATH exec bash -c "$1"' _ "$1" <<<"${2:-}"
}

stop_hook_command() {
  in_box jq -re '.hooks.Stop[0].hooks[0].command' "$NTFY_SETTINGS"
}

notification_hook_command() {
  in_box jq -re '.hooks.Notification[0].hooks[0].command' "$NTFY_SETTINGS"
}

# The payloads write a file rather than echo a word: the word would also
# appear in the output as part of the token itself, so only a side effect
# distinguishes "carried through as data" from "ran".
# Takes the argv dump, because `run` below overwrites $output.
assert_not_injected() {
  # `id` in the payload would have substituted a uid line into the header.
  [[ "$1" != *"uid="* ]]

  run in_box test -e /tmp/pwned
  [ "$status" -ne 0 ]
}

@test "a token full of shell metacharacters cannot escape the hook command" {
  local nasty='tk`touch /tmp/pwned`$(touch /tmp/pwned)"; touch /tmp/pwned; id;'
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" \
    -e NTFY_URL=https://ntfy.example.com/claude -e NTFY_TOKEN="$nasty"
  wait_ready

  local cmd
  cmd="$(stop_hook_command)"

  # Still a command a shell will accept...
  run in_box bash -n -c "$cmd"
  [ "$status" -eq 0 ]

  # ...and the token arrives in curl's argv whole, not split at the quote.
  run hook_argv "$cmd"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARG[Authorization: Bearer ${nasty}]"* ]]

  assert_not_injected "$output"
}

@test "a url full of shell metacharacters cannot escape the hook command" {
  local nasty="https://ntfy.example.com/claude'; touch /tmp/pwned; id;#"
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e NTFY_URL="$nasty"
  wait_ready

  local cmd
  cmd="$(stop_hook_command)"

  run in_box bash -n -c "$cmd"
  [ "$status" -eq 0 ]

  run hook_argv "$cmd"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARG[${nasty}]"* ]]

  assert_not_injected "$output"
}

# --- which box this is ---------------------------------------------------------
#
# One deployment per account pages the same phone. BOX_NAME is what tells the
# notifications apart, and docker-compose.yaml makes it the hostname the
# prompt, tmux and herdr show.

@test "notification titles name the box when BOX_NAME is set" {
  start_box --hostname work -e SSH_PUBLIC_KEYS="$PUBKEY" \
    -e NTFY_URL=https://ntfy.example.com/claude -e BOX_NAME=work
  wait_ready

  run hook_argv "$(stop_hook_command)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARG[Title: Claude finished (work)]"* ]]

  run hook_argv "$(notification_hook_command)" '{"message":"permission needed"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARG[Title: Claude needs you (work)]"* ]]

  run box_logs
  [[ "$output" != *"BOX_NAME"* ]]
}

@test "a box name full of shell metacharacters cannot escape either hook command" {
  local nasty='w`touch /tmp/pwned`$(touch /tmp/pwned)'"'"'; touch /tmp/pwned; id;'
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" \
    -e NTFY_URL=https://ntfy.example.com/claude -e BOX_NAME="$nasty"
  wait_ready

  local stop notification
  stop="$(stop_hook_command)"
  notification="$(notification_hook_command)"

  run in_box bash -n -c "$stop"
  [ "$status" -eq 0 ]
  run in_box bash -n -c "$notification"
  [ "$status" -eq 0 ]

  run hook_argv "$stop"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARG[Title: Claude finished (${nasty})]"* ]]
  assert_not_injected "$output"

  run hook_argv "$notification" '{"message":"permission needed"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARG[Title: Claude needs you (${nasty})]"* ]]
  assert_not_injected "$output"
}

# Docker refuses a hostname over 64 bytes outright, but takes one with a space
# or an underscore, which then fails to resolve: every sudo complains. A name
# from Coolify can also carry a trailing CR. The box still boots; the log says
# why the name is wrong.
@test "warns about a BOX_NAME that is not a valid hostname" {
  local name
  for name in 'Work box' $'work\r' "$(printf 'a%.0s' {1..64})"; do
    boot_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e BOX_NAME="$name"
    wait_ready

    run box_logs
    [[ "$output" == *"warning: BOX_NAME"*"is not a valid hostname"* ]]
    cleanup_box
  done
}

# Run without Compose, or by a host that drops `hostname:`, the titles would
# name the box while the prompt still shows a container id.
@test "warns when the hostname is not BOX_NAME" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e BOX_NAME=work
  wait_ready

  run box_logs
  [[ "$output" == *"warning: the hostname is "*", not BOX_NAME (work)"* ]]
}

@test "never overwrites a settings.json from a persisted volume" {
  local vol
  vol="$(make_volume)"
  seed_home "$vol" \
    'mkdir -p ~/.claude && printf "%s" "{\"permissions\":{\"defaultMode\":\"plan\"},\"mine\":true}" > ~/.claude/settings.json'

  HOME_VOL="$vol" start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run in_box jq -re '.mine' /home/dev/.claude/settings.json
  [ "$output" = "true" ]

  run in_box jq -re '.permissions.defaultMode' /home/dev/.claude/settings.json
  [ "$output" = "plan" ]
}

# --- Memory --------------------------------------------------------------------

# Started in the background just before sshd, so it can trail the readiness
# signal by a moment.
earlyoom_pid() {
  local i pid
  for ((i = 0; i < 50; i++)); do
    if pid="$(in_box pgrep -x earlyoom)"; then
      echo "$pid"
      return 0
    fi
    sleep 0.1
  done
  echo "earlyoom is not running. logs:" >&2
  box_logs >&2
  return 1
}

# With no swap, a box that runs out of memory does not OOM-kill anything: it
# thrashes, and sshd and herdr stop answering while both are still up. earlyoom
# is what kills first. It runs as root, so it must not carry the agents' tokens
# along -- it hands its environment to the script it runs after a kill.
@test "runs earlyoom as root, holding none of the forwarded secrets" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e GH_TOKEN=gh_secret -e ANTHROPIC_API_KEY=sk_secret \
    -e NTFY_URL=https://ntfy.example.com/claude -e NTFY_TOKEN=tk_test -e BOX_NAME=work
  wait_ready

  local pid
  pid="$(earlyoom_pid)"

  run in_box ps -o user= -p "$pid"
  [ "$output" = "root" ]

  # sshd is root's; the rest of the way in is dev's, and avoided by name.
  run in_box sh -c "tr '\\0' ' ' < /proc/$pid/cmdline"
  [[ "$output" == *"--ignore-root-user"* ]]
  [[ "$output" == *"--avoid ^(sshd-session|herdr|tmux: server)\$"* ]]
  [[ "$output" == *"-N /usr/local/libexec/afkd/oom-notify"* ]]

  run in_box sh -c "tr '\\0' '\\n' < /proc/$pid/environ"
  [[ "$output" == *"NTFY_TOKEN=tk_test"* ]]
  [[ "$output" == *"BOX_NAME=work"* ]]
  [[ "$output" != *"gh_secret"* ]]
  [[ "$output" != *"sk_secret"* ]]
}

# Run the way earlyoom runs it: the environment the entrypoint started earlyoom
# with, plus the EARLYOOM_* variables it sets for the kill.
oom_notify() {
  stub_curl
  docker exec "$BOX" env -i PATH=/tmp/stub:/usr/bin:/bin "$@" /usr/local/libexec/afkd/oom-notify
}

# A process's command line can carry a token, and the ntfy server is a third
# party, so the page names the process and nothing it was started with.
@test "pages the phone after an earlyoom kill, and only when NTFY_URL is set" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run oom_notify NTFY_URL=https://ntfy.example.com/claude NTFY_TOKEN=tk_test BOX_NAME=work \
    EARLYOOM_NAME=claude EARLYOOM_PID=42 EARLYOOM_UID=1000 \
    'EARLYOOM_CMDLINE=curl -H Authorization:cmdline_secret https://example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARG[https://ntfy.example.com/claude]"* ]]
  [[ "$output" == *"ARG[Authorization: Bearer tk_test]"* ]]
  [[ "$output" == *"ARG[Title: Out of memory (work)]"* ]]
  [[ "$output" == *"ARG[stopped claude (pid 42) to keep the box reachable]"* ]]
  [[ "$output" != *"cmdline_secret"* ]]

  run oom_notify NTFY_URL= EARLYOOM_NAME=claude EARLYOOM_PID=42
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
