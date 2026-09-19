#!/usr/bin/env bats
#
# The end-to-end contract: a real SSH login from outside the container. This
# is the only assertion that proves the box is actually usable -- password auth
# is disabled, so a broken authorized_keys means a healthy-looking, unreachable
# container.

load helpers

setup_file() {
  generate_keypair
}

teardown() {
  cleanup_box
}

ssh_box() {
  ssh -i "$KEYFILE" -p "$(host_port)" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o LogLevel=ERROR \
    root@127.0.0.1 "$@"
}

wait_ssh() {
  local i
  for ((i = 0; i < 30; i++)); do
    if ssh_box true >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "ssh never became available. logs:" >&2
  box_logs >&2
  return 1
}

@test "accepts a login with the configured public key" {
  start_box -p 127.0.0.1::22 -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready
  wait_ssh

  run ssh_box 'echo connected'
  [ "$status" -eq 0 ]
  [ "$output" = "connected" ]
}

@test "rejects a login with an unknown key" {
  start_box -p 127.0.0.1::22 -e SSH_PUBLIC_KEYS="ssh-ed25519 AAAAnotyourkey nobody@nowhere"
  wait_ready

  run ssh_box 'echo connected'
  [ "$status" -ne 0 ]
}

@test "forwarded env vars reach a non-interactive ssh command" {
  # The whole point of writing .zshenv: an agent started over ssh, with no
  # interactive shell anywhere, still sees its API keys.
  start_box -p 127.0.0.1::22 -e SSH_PUBLIC_KEYS="$PUBKEY" \
    -e ANTHROPIC_API_KEY='sk-test with spaces $and metachars'
  wait_ready
  wait_ssh

  run ssh_box 'printf %s "$ANTHROPIC_API_KEY"'
  [ "$status" -eq 0 ]
  [ "$output" = 'sk-test with spaces $and metachars' ]
}

@test "persists the ssh host key across container replacement" {
  # Redeploys must not trip REMOTE HOST IDENTIFICATION HAS CHANGED.
  CONFIG_VOL="$(make_volume)"
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready
  local before
  before="$(in_box ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub)"

  docker rm -f "$BOX" >/dev/null
  BOX=""

  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready
  local after
  after="$(in_box ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub)"

  [ -n "$before" ]
  [ "$before" = "$after" ]
}
