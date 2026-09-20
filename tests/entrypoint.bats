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
  run docker run --rm --label "${LABEL}=1" -v "${vol}:/root/.config" "$IMAGE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SSH_PUBLIC_KEYS is empty"* ]]
}

@test "refuses to start when SSH_PUBLIC_KEYS is empty" {
  local vol
  vol="$(make_volume)"
  run docker run --rm --label "${LABEL}=1" -v "${vol}:/root/.config" \
    -e SSH_PUBLIC_KEYS= "$IMAGE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SSH_PUBLIC_KEYS is empty"* ]]
}

@test "boots with no volumes mounted" {
  # Nothing in the image creates /root/.config, but the entrypoint copies host
  # keys into it on first boot. A deployment always mounts a volume there; a
  # bare `docker run` must still work, or the image is undebuggable locally.
  BOX="rcc-ci-$$-${RANDOM}"
  docker run -d --name "$BOX" --label "${LABEL}=1" \
    -e SSH_PUBLIC_KEYS="$PUBKEY" "$IMAGE" >/dev/null
  wait_ready
}

@test "installs every public key line with locked-down permissions" {
  start_box -e SSH_PUBLIC_KEYS="${PUBKEY}"$'\n'"ssh-ed25519 AAAAsecondkey other@host"
  wait_ready

  run in_box wc -l /root/.ssh/authorized_keys
  [[ "$output" == 2* ]]

  run in_box grep -cF "$PUBKEY_BARE" /root/.ssh/authorized_keys
  [ "$output" = "1" ]

  run in_box stat -c '%a' /root/.ssh
  [ "$output" = "700" ]

  run in_box stat -c '%a' /root/.ssh/authorized_keys
  [ "$output" = "600" ]
}

# --- git identity ------------------------------------------------------------

@test "sets the git identity from the environment" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" \
    -e GIT_USER_NAME='Ada Lovelace' -e GIT_USER_EMAIL='ada@example.com'
  wait_ready

  run in_box git config --global user.name
  [ "$output" = 'Ada Lovelace' ]

  run in_box git config --global user.email
  [ "$output" = 'ada@example.com' ]
}

@test "leaves the git identity unset rather than inventing one" {
  # These used to fall back to the name and email of this repo's author, so
  # every other deployment committed under an identity that had never touched
  # the code. An unset identity makes git say so at commit time; a wrong one
  # is silent and ends up in history.
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run in_box git config --global user.name
  [ "$status" -ne 0 ]

  run in_box git config --global user.email
  [ "$status" -ne 0 ]

  run box_logs
  [[ "$output" == *"GIT_USER_NAME and/or GIT_USER_EMAIL are unset"* ]]
}

@test "warns when only half the git identity is set" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e GIT_USER_NAME='Ada Lovelace'
  wait_ready

  run in_box git config --global user.name
  [ "$output" = 'Ada Lovelace' ]

  run in_box git config --global user.email
  [ "$status" -ne 0 ]

  run box_logs
  [[ "$output" == *"GIT_USER_NAME and/or GIT_USER_EMAIL are unset"* ]]
}

# --- GITHUB_SSH_KEY ----------------------------------------------------------
#
# The key must come out usable whichever form Coolify hands it over in. The
# strongest assertion available is that ssh-keygen can derive the matching
# public key from the file the entrypoint wrote.

assert_github_key_usable() {
  # ssh-keygen echoes the comment stored in the private key, so compare the
  # type and blob only.
  run in_box sh -c 'ssh-keygen -y -f /root/.ssh/github_ed25519 | cut -d" " -f1,2'
  [ "$status" -eq 0 ]
  [ "$output" = "$PUBKEY_BARE" ]

  run in_box stat -c '%a' /root/.ssh/github_ed25519
  [ "$output" = "600" ]

  run in_box grep -q 'IdentityFile /root/.ssh/github_ed25519' /root/.ssh/config
  [ "$status" -eq 0 ]
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

  run in_box tail -c1 /root/.ssh/github_ed25519
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

  run in_box test -e /root/.ssh/github_ed25519
  [ "$status" -ne 0 ]
}

@test "writes no ssh client config when GITHUB_SSH_KEY is unset" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run in_box test -e /root/.ssh/config
  [ "$status" -ne 0 ]
}

@test "boots with a usable GitHub key even with no network" {
  # ssh-keyscan exits non-zero when github.com does not resolve, which is any
  # boot that races the network -- a Coolify restart ahead of its DNS, an
  # egress firewall, a flaky resolver. Unguarded under `set -e` that aborted
  # the entrypoint before `exec sshd`, leaving a container nobody could log in
  # to and fix. GITHUB_SSH_KEY has to be set or the keyscan is never reached.
  start_box --network none -e SSH_PUBLIC_KEYS="$PUBKEY" -e GITHUB_SSH_KEY="$PRIVKEY"
  wait_ready

  run box_logs
  [[ "$output" == *"could not reach github.com"* ]]

  # Everything that does not need the network still has to have happened.
  run in_box stat -c '%a' /root/.ssh/github_ed25519
  [ "$output" = "600" ]

  run in_box grep -q 'IdentityFile /root/.ssh/github_ed25519' /root/.ssh/config
  [ "$status" -eq 0 ]
}

# --- .zshenv forwarding ------------------------------------------------------

# `docker exec` hands the exec'd process the container's own environment -- the
# very `-e` values passed to `docker run`. Reading the variable back without
# clearing it first asserts nothing about .zshenv: these three tests passed
# with every `printf 'export ...'` line deleted from the entrypoint, which is
# the exact regression (d432f20) they were written to guard. `env -u` clears
# it, and zsh sources .zshenv on its own, so the explicit `source` can go too.
@test "round-trips env values containing spaces, quotes and metacharacters" {
  local awkward='a b "c" '"'"'d'"'"' $e `f` \g'
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e ANTHROPIC_API_KEY="$awkward"
  wait_ready

  run in_box env -u ANTHROPIC_API_KEY zsh -c 'printf %s "$ANTHROPIC_API_KEY"'
  [ "$status" -eq 0 ]
  [ "$output" = "$awkward" ]
}

@test "round-trips a multiline env value" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e ANTHROPIC_API_KEY=$'line one\nline two'
  wait_ready

  run in_box env -u ANTHROPIC_API_KEY zsh -c 'printf %s "$ANTHROPIC_API_KEY"'
  [ "$status" -eq 0 ]
  [ "$output" = $'line one\nline two' ]
}

@test "forwards CLAUDE_* and CODEX_* vars and skips unset ones" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" \
    -e CLAUDE_CODE_USE_BEDROCK=1 -e CODEX_HOME=/root/.codex
  wait_ready

  run in_box env -u CLAUDE_CODE_USE_BEDROCK -u CODEX_HOME \
    zsh -c 'printf "%s|%s" "$CLAUDE_CODE_USE_BEDROCK" "$CODEX_HOME"'
  [ "$output" = "1|/root/.codex" ]

  run in_box grep -c 'GH_TOKEN' /root/.zshenv
  [ "$output" = "0" ]

  run in_box stat -c '%a' /root/.zshenv
  [ "$output" = "600" ]
}

# --- Claude Code settings ----------------------------------------------------

@test "seeds a valid default settings.json" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run in_box jq -e '.permissions.defaultMode' /root/.claude/settings.json
  [ "$status" -eq 0 ]

  run in_box jq -e '.hooks' /root/.claude/settings.json
  [ "$status" -ne 0 ]
}

@test "merges notification hooks when NTFY_URL is set" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" \
    -e NTFY_URL=https://ntfy.example.com/claude -e NTFY_TOKEN=tk_test
  wait_ready

  run in_box jq -re '.hooks.Notification[0].hooks[0].command' /root/.claude/settings.json
  [ "$status" -eq 0 ]
  [[ "$output" == *"ntfy.example.com/claude"* ]]
  [[ "$output" == *"tk_test"* ]]

  run in_box jq -re '.hooks.Stop[0].hooks[0].command' /root/.claude/settings.json
  [ "$status" -eq 0 ]
  [[ "$output" == *"turn complete"* ]]

  # The merge must not clobber what was already there.
  run in_box jq -e '.permissions.defaultMode' /root/.claude/settings.json
  [ "$status" -eq 0 ]

  # This file now holds a bearer token. authorized_keys, github_ed25519 and
  # .zshenv have all had a mode assertion since the day they were written; the
  # one file holding a token was the only one without, and it was 0644.
  run in_box stat -c '%a' /root/.claude/settings.json
  [ "$output" = "600" ]
}

@test "locks down settings.json even with no notification hooks" {
  # The umask at creation, rather than the chmod after the merge.
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run in_box stat -c '%a' /root/.claude/settings.json
  [ "$output" = "600" ]
}

@test "relocks a settings.json restored from a volume written by an older image" {
  # Volumes outlive images. A box redeployed onto this version has to repair
  # the 0644 file its predecessor left in /root/.claude, not just get the mode
  # right on the files it creates itself.
  local vol
  vol="$(make_volume)"
  docker run --rm --label "${LABEL}=1" -v "${vol}:/root/.claude" \
    --entrypoint sh "$IMAGE" -c \
    'echo "{}" > /root/.claude/settings.json; chmod 644 /root/.claude/settings.json'

  start_box -v "${vol}:/root/.claude" -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run in_box stat -c '%a' /root/.claude/settings.json
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
hook_argv() {
  docker exec -i "$BOX" bash -s -- "$1" <<'STUB'
mkdir -p /tmp/stub
cat > /tmp/stub/curl <<'CURL'
#!/bin/bash
printf 'ARG[%s]\n' "$@"
CURL
chmod +x /tmp/stub/curl
PATH=/tmp/stub:$PATH bash -c "$1"
STUB
}

stop_hook_command() {
  in_box jq -re '.hooks.Stop[0].hooks[0].command' /root/.claude/settings.json
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

@test "never overwrites a settings.json from a persisted volume" {
  local vol
  vol="$(make_volume)"
  docker run --rm --label "${LABEL}=1" -v "${vol}:/root/.claude" \
    --entrypoint sh "$IMAGE" -c \
    'printf "%s" "{\"permissions\":{\"defaultMode\":\"plan\"},\"mine\":true}" > /root/.claude/settings.json'

  start_box -v "${vol}:/root/.claude" -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run in_box jq -re '.mine' /root/.claude/settings.json
  [ "$output" = "true" ]

  run in_box jq -re '.permissions.defaultMode' /root/.claude/settings.json
  [ "$output" = "plan" ]
}
