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

@test "adds the trailing newline ssh requires to a PEM key" {
  local pem_no_newline
  pem_no_newline="$(printf '%s' "$PRIVKEY")"
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e GITHUB_SSH_KEY="$pem_no_newline"
  wait_ready
  assert_github_key_usable

  run in_box tail -c1 /root/.ssh/github_ed25519
  [ -z "$output" ]
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

@test "round-trips env values containing spaces, quotes and metacharacters" {
  local awkward='a b "c" '"'"'d'"'"' $e `f` \g'
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e ANTHROPIC_API_KEY="$awkward"
  wait_ready

  run in_box zsh -c 'source /root/.zshenv; printf %s "$ANTHROPIC_API_KEY"'
  [ "$status" -eq 0 ]
  [ "$output" = "$awkward" ]
}

@test "round-trips a multiline env value" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e ANTHROPIC_API_KEY=$'line one\nline two'
  wait_ready

  run in_box zsh -c 'source /root/.zshenv; printf %s "$ANTHROPIC_API_KEY"'
  [ "$status" -eq 0 ]
  [ "$output" = $'line one\nline two' ]
}

@test "forwards CLAUDE_* and CODEX_* vars and skips unset ones" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" \
    -e CLAUDE_CODE_USE_BEDROCK=1 -e CODEX_HOME=/root/.codex
  wait_ready

  run in_box zsh -c 'source /root/.zshenv; printf "%s|%s" "$CLAUDE_CODE_USE_BEDROCK" "$CODEX_HOME"'
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
