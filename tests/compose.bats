#!/usr/bin/env bats
#
# docker-compose.yaml is the deployment: what Coolify's Compose build pack
# runs and what it lists as the variables to fill in. The settings it carries
# -- the volumes, the fd limit, the published port -- used to live in a host's
# UI, where nothing tested them and recreating the app quietly lost them.

load helpers

COMPOSE_FILE="${BATS_TEST_DIRNAME}/../docker-compose.yaml"

setup_file() {
  generate_keypair
}

# Compose interpolates from the caller's environment, so a GH_TOKEN or LANG
# that happens to be set on the machine running the suite would leak into the
# box under test. Only what docker itself needs is passed through.
compose() {
  env -i PATH="$PATH" HOME="$HOME" ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} \
    "$@"
}

# The image under test rather than a fresh build of the context, so this file
# checks the same image as every other, and fast.
compose_up() {
  PROJECT="rcc-ci-compose-$$-${RANDOM}"
  export PROJECT
  printf 'services:\n  remote-claude:\n    image: %s\n' "$IMAGE" \
    > "${BATS_TEST_TMPDIR}/image.yaml"
  compose SSH_PUBLIC_KEYS="$PUBKEY" SSH_PORT=127.0.0.1:0 \
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" -f "${BATS_TEST_TMPDIR}/image.yaml" \
    up -d --no-build --pull never --quiet-pull >/dev/null 2>&1
  BOX="$(compose SSH_PUBLIC_KEYS="$PUBKEY" \
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" ps -q remote-claude)"
  export BOX
}

teardown() {
  if [ -n "${PROJECT:-}" ]; then
    compose SSH_PUBLIC_KEYS=unused docker compose -p "$PROJECT" -f "$COMPOSE_FILE" \
      down -v >/dev/null 2>&1
  fi
  PROJECT=""
}

compose_config() {
  compose SSH_PUBLIC_KEYS="$PUBKEY" docker compose -f "$COMPOSE_FILE" config --format json
}

# Coolify refuses to deploy while a :? variable is empty. Without it the box
# would deploy, pass its healthcheck and be impossible to log into.
@test "will not start without SSH_PUBLIC_KEYS" {
  run compose docker compose -f "$COMPOSE_FILE" config
  [ "$status" -ne 0 ]
  [[ "$output" == *SSH_PUBLIC_KEYS* ]]
}

# A variable the image reads but the compose file does not name never reaches
# the container, and Coolify never offers it.
@test "declares every variable .env.example documents" {
  local documented declared
  # CLAUDE_* and CODEX_* are open-ended families, shown there by example.
  documented="$(sed -nE 's/^#?([A-Z][A-Z0-9_]*)=.*/\1/p' "${BATS_TEST_DIRNAME}/../.env.example" \
    | grep -vE '^(CLAUDE|CODEX)_' | sort -u)"
  declared="$(compose_config | jq -r '.services["remote-claude"].environment | keys[]' | sort -u)"
  [ "$documented" = "$declared" ] || {
    diff <(echo "$documented") <(echo "$declared")
    false
  }
}

# Coolify builds every service that has a `build:` before it pulls the rest, so
# one left here puts the image build back on the host: minutes of downtime,
# gigabytes of build cache on its disk, and a box running an image CI never
# tested. CI publishes the image; the deployment only pulls it.
@test "pulls the published image rather than building on the host" {
  run compose_config
  [ "$status" -eq 0 ]
  [ "$(jq -r '.services["remote-claude"].build' <<<"$output")" = null ]
  [ "$(jq -r '.services["remote-claude"].image' <<<"$output")" = ghcr.io/maximn/remote-claude-code:main ]

  run compose SSH_PUBLIC_KEYS="$PUBKEY" IMAGE_TAG=0123abc \
    docker compose -f "$COMPOSE_FILE" config --format json
  [ "$(jq -r '.services["remote-claude"].image' <<<"$output")" = ghcr.io/maximn/remote-claude-code:0123abc ]
}

@test "boots with its volumes, fd limit and port" {
  compose_up
  wait_ready

  run in_box sh -c 'ulimit -n'
  [ "$output" = "65536" ]

  run docker inspect -f '{{range .Mounts}}{{.Type}} {{.Destination}}{{"\n"}}{{end}}' "$BOX"
  [ "$(sort <<<"$output" | sed '/^$/d')" = $'volume /home/dev\nvolume /home/dev/.cache\nvolume /var/lib/remote-claude' ]

  run in_box stat -c '%U %a' /home/dev /home/dev/.cache
  [ "$output" = $'dev 700\ndev 755' ]

  run docker port "$BOX" 22/tcp
  [ "$status" -eq 0 ]
  [[ "$output" == 127.0.0.1:* ]]
}

# Every optional variable is declared, so on a deployment that sets none of
# them each one arrives as an empty string. None of them may switch a feature
# on or reach a session as a blank credential.
@test "leaves optional variables off when they are not set" {
  compose_up
  wait_ready

  run in_box sh -c 'printenv GH_TOKEN; printenv NTFY_URL'
  [ "$output" = "" ]
  run in_box cat /run/remote-claude/env.zsh
  [ "$output" = "" ]
  run in_box test -e /etc/claude-code/managed-settings.d/50-ntfy.json
  [ "$status" -ne 0 ]
  run in_box test -e /run/remote-claude/github_ed25519
  [ "$status" -ne 0 ]
}
