#!/usr/bin/env bash
# Shared helpers for the container suite. Every test boots the real image and
# asserts on the result, because every entrypoint bug this repo has shipped so
# far was only visible once the container was actually running.

IMAGE="${IMAGE:-afkd:ci}"
LABEL="afkd-ci"

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
  local v="afkd-ci-vol-$$-${RANDOM}"
  docker volume create --label "${LABEL}=1" "$v" >/dev/null
  echo "$v" >> "${BATS_FILE_TMPDIR}/volumes"
  echo "$v"
}

# Boots the image the way it is actually deployed: with home, its cache and
# the system state (the SSH host keys) each on a volume of its own. Extra
# `docker run` arguments are passed through. Set HOME_VOL, CACHE_VOL or
# SYSTEM_VOL beforehand to boot onto a volume an earlier container wrote --
# a seeded home, or host keys that have to survive a replacement.
start_box() {
  [ -n "${HOME_VOL:-}" ] || HOME_VOL="$(make_volume)"
  [ -n "${CACHE_VOL:-}" ] || CACHE_VOL="$(make_volume)"
  [ -n "${SYSTEM_VOL:-}" ] || SYSTEM_VOL="$(make_volume)"
  # Exported so a file-scoped setup_file can hand its box to the tests: bats
  # runs setup_file in a shell of its own.
  export HOME_VOL CACHE_VOL SYSTEM_VOL
  boot_box -v "${HOME_VOL}:/home/dev" -v "${CACHE_VOL}:/home/dev/.cache" \
    -v "${SYSTEM_VOL}:/var/lib/afkd" "$@"
}

# Boots the image with exactly the mounts given and no others: a bare
# `docker run`, an unseeded home, the legacy root layout.
boot_box() {
  BOX="afkd-ci-$$-${RANDOM}"
  export BOX
  docker run -d --name "$BOX" --label "${LABEL}=1" "$@" "$IMAGE" >/dev/null
}

# Writes into a home volume the way the user would have: as dev, so ownership
# is what a real session leaves behind. An empty volume is seeded from the
# image's /home/dev on this first mount, as it is in production. The script
# reads stdin, for fixtures passed as a heredoc.
seed_home() {
  local vol="$1"
  shift
  docker run --rm -i --label "${LABEL}=1" --user dev -v "${vol}:/home/dev" \
    --entrypoint bash "$IMAGE" -c "$@"
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

# The image ships a HEALTHCHECK, so Docker tracks a status of its own. That is
# a different signal from wait_ready: this one is what an orchestrator acts on,
# and it only turns green if Docker is running the probe and the probe passes.
# Docker issues the first one an interval in, so expect a wait on a young box.
wait_healthy() {
  local i status=""
  for ((i = 0; i < 120; i++)); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$BOX" 2>/dev/null)"
    case "$status" in
      healthy) return 0 ;;
      unhealthy) break ;;
      "") echo "container declares no healthcheck" >&2; return 1 ;;
    esac
    sleep 1
  done
  echo "container never became healthy (status: ${status:-unknown}). probes:" >&2
  docker inspect -f '{{json .State.Health}}' "$BOX" >&2
  return 1
}

in_box() {
  docker exec "$BOX" "$@"
}

# As the login user, the way an ssh session runs. docker exec takes HOME from
# the user's passwd entry, but not the working directory.
as_dev() {
  docker exec -u dev -w /home/dev "$BOX" "$@"
}

box_logs() {
  docker logs "$BOX" 2>&1
}

host_port() {
  docker port "$BOX" 22/tcp | head -1 | sed 's/.*://'
}

# Anything that escapes this (an interrupted run) is still labelled:
# `docker volume prune --filter label=afkd-ci=1` sweeps the lot.
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
  HOME_VOL=""
  CACHE_VOL=""
  SYSTEM_VOL=""
  return 0
}
