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

# SSH_USER picks who logs in; every case but the root one is dev, the only
# account sshd lets through. SSH_SEND_ENV names variables to forward the way a
# real client's SendEnv does; nothing is forwarded by default, so a test does
# not depend on the locale of the machine running it.
ssh_box() {
  ssh -i "$KEYFILE" -p "$(host_port)" \
    ${SSH_SEND_ENV:+-o "SendEnv=$SSH_SEND_ENV"} \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o LogLevel=ERROR \
    -o IdentitiesOnly=yes \
    "${SSH_USER:-dev}@127.0.0.1" "$@"
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

# Claude Code refuses --dangerously-skip-permissions as root, and every tool
# that writes into a project wrote root-owned files. A session is dev's.
@test "logs in as the unprivileged dev user" {
  start_box -p 127.0.0.1::22 -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready
  wait_ssh

  run ssh_box 'id -un; id -u; echo "$HOME"'
  [ "$status" -eq 0 ]
  [ "$output" = $'dev\n1000\n/home/dev' ]
}

# Root by key was the only way in before; now nothing should log in as root,
# not even the key that gets dev in. Administration goes through sudo.
@test "refuses root even with an authorized key" {
  start_box -p 127.0.0.1::22 -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready
  wait_ssh

  SSH_USER=root wait_auth_refusal
}

# The box is still single-user and the user still owns it: apt, the
# migration, anything else under /etc. sudo is how, without a password,
# since none is ever set.
@test "dev can sudo without a password" {
  start_box -p 127.0.0.1::22 -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready
  wait_ssh

  run ssh_box 'sudo -n id -un'
  [ "$status" -eq 0 ]
  [ "$output" = "root" ]
}

# wait_ready only polls for the sshd *process*, which execs before it binds, so
# "ssh exited non-zero" is also satisfied by connection refused. This returns 0
# only once sshd has answered and turned the login down, and fails outright if
# one is ever let through.
wait_auth_refusal() {
  local i out
  for ((i = 0; i < 60; i++)); do
    if out="$(ssh_box 'echo connected' 2>&1)"; then
      echo "login succeeded with a key that is not in authorized_keys" >&2
      return 1
    fi
    if [[ "$out" == *"Permission denied"* ]]; then
      return 0
    fi
    sleep 0.5
  done
  echo "sshd never answered. last attempt: ${out}" >&2
  box_logs >&2
  return 1
}

@test "rejects a login with an unknown key" {
  # This waited for nothing and asserted only that ssh failed, so it passed on
  # a not-yet-listening daemon -- and would have kept passing with
  # authorized_keys handling broken wide open.
  start_box -p 127.0.0.1::22 -e SSH_PUBLIC_KEYS="ssh-ed25519 AAAAnotyourkey nobody@nowhere"
  wait_ready

  wait_auth_refusal
}

# Home is a volume, and a volume outlives every key rotation. A key
# that once made it into ~/.ssh/authorized_keys -- written by an older image,
# or added by hand -- must not keep working after it leaves SSH_PUBLIC_KEYS:
# sshd reads the root-owned file the entrypoint rebuilds, and nothing in home.
@test "ignores a key left behind in ~/.ssh/authorized_keys" {
  start_box -p 127.0.0.1::22 -e SSH_PUBLIC_KEYS="ssh-ed25519 AAAAnotyourkey nobody@nowhere"
  wait_ready
  as_dev sh -c "mkdir -p ~/.ssh && printf '%s\n' '$PUBKEY' > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

  wait_auth_refusal
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

# A client's ssh forwards LANG and LC_* (Debian's and macOS's defaults both
# do) and sshd accepts them, so a session runs in whatever locale the laptop
# is in. One the box lacks makes every locale-aware tool -- man, perl, git's
# pager -- open with "cannot set locale" before doing its job.
@test "a locale forwarded from the client is installed" {
  start_box -p 127.0.0.1::22 -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready
  wait_ssh

  local lang
  for lang in en_US.UTF-8 de_DE.UTF-8 ja_JP.UTF-8; do
    LANG="$lang" SSH_SEND_ENV=LANG run ssh_box \
      'printf "%s\n" "$LANG"; locale 2>&1 >/dev/null'
    [ "$status" -eq 0 ]
    [ "$output" = "$lang" ] || {
      echo "LANG=$lang: $output"
      false
    }
  done
}

@test "persists the ssh host key across container replacement" {
  # Redeploys must not trip REMOTE HOST IDENTIFICATION HAS CHANGED. The keys
  # live on the system volume, so this reuses that one alone: a fresh home
  # must not cost the box its identity.
  SYSTEM_VOL="$(make_volume)"
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready
  local before
  before="$(in_box ssh-keygen -lf /var/lib/afkd/ssh/ssh_host_ed25519_key.pub)"

  docker rm -f "$BOX" >/dev/null
  BOX=""
  HOME_VOL=""
  CACHE_VOL=""

  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready
  local after
  after="$(in_box ssh-keygen -lf /var/lib/afkd/ssh/ssh_host_ed25519_key.pub)"

  [ -n "$before" ]
  [ "$before" = "$after" ]
}
