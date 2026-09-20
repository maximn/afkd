#!/usr/bin/env bash
# Shared helpers for the container suite. Every test boots the real image and
# asserts on the result, because every entrypoint bug this repo has shipped so
# far was only visible once the container was actually running.

IMAGE="${IMAGE:-remote-claude-code:ci}"
LABEL="rcc-ci"

# One throwaway keypair per test file: used both as the SSH login key and as
# the GITHUB_SSH_KEY payload, so tests can assert the key survived the trip.
generate_keypair() {
  local dir="${BATS_FILE_TMPDIR}/key"
  mkdir -p "$dir"
  ssh-keygen -q -t ed25519 -N '' -C 'ci@test' -f "$dir/id"
  export KEYFILE="$dir/id"
  export PUBKEY
  PUBKEY="$(cat "$dir/id.pub")"
  export PRIVKEY
  PRIVKEY="$(cat "$dir/id")"
  # ssh-keygen -y prints no comment, so compare against the bare type+blob.
  export PUBKEY_BARE
  PUBKEY_BARE="$(cut -d' ' -f1,2 <<<"$PUBKEY")"
}

# Recorded in a file rather than a shell array. Every caller is `$(make_volume)`
# -- a command substitution, so the function body runs in a subshell and an
# array append here dies with it. The volumes then outlive the run: each one
# holds the ssh host *private* keys the entrypoint persisted.
make_volume() {
  local v="rcc-ci-vol-$$-${RANDOM}"
  docker volume create --label "${LABEL}=1" "$v" >/dev/null
  echo "$v" >> "${BATS_FILE_TMPDIR}/volumes"
  echo "$v"
}

# Boots the image the way it is actually deployed: with a volume on
# /root/.config, where the SSH host keys are persisted. Extra `docker run`
# arguments are passed through. Set CONFIG_VOL beforehand to reuse a volume
# from an earlier container (host-key persistence).
start_box() {
  [ -n "${CONFIG_VOL:-}" ] || CONFIG_VOL="$(make_volume)"
  BOX="rcc-ci-$$-${RANDOM}"
  docker run -d --name "$BOX" --label "${LABEL}=1" \
    -v "${CONFIG_VOL}:/root/.config" "$@" "$IMAGE" >/dev/null
}

# sshd is the last thing the entrypoint does, so it running means the whole
# entrypoint ran. This is the same signal as the deployment healthcheck.
wait_ready() {
  local i
  for ((i = 0; i < 150; i++)); do
    if docker exec "$BOX" pgrep -x sshd >/dev/null 2>&1; then
      return 0
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$BOX" 2>/dev/null)" != "true" ]; then
      break
    fi
    sleep 0.2
  done
  echo "container did not come up. logs:" >&2
  docker logs "$BOX" >&2
  return 1
}

in_box() {
  docker exec "$BOX" "$@"
}

box_logs() {
  docker logs "$BOX" 2>&1
}

host_port() {
  docker port "$BOX" 22/tcp | head -1 | sed 's/.*://'
}

# Anything that escapes this (an interrupted run) is still labelled:
# `docker volume prune --filter label=rcc-ci=1` sweeps the lot.
cleanup_box() {
  [ -n "${BOX:-}" ] && docker rm -f "$BOX" >/dev/null 2>&1
  local vols="${BATS_FILE_TMPDIR}/volumes" v
  if [ -f "$vols" ]; then
    while read -r v; do
      [ -n "$v" ] && docker volume rm -f "$v" >/dev/null 2>&1
    done < "$vols"
    : > "$vols"
  fi
  BOX=""
  CONFIG_VOL=""
  return 0
}
