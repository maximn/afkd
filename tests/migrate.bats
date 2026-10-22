#!/usr/bin/env bats
#
# afkd-migrate: the one-shot move from the root-era layout -- a volume per
# directory under /root -- into dev's home. It runs once per deployment, on
# data nobody can regenerate, so the legacy volumes are seeded the way the old
# image left them and the result is checked file by file.

load helpers

setup_file() {
  generate_keypair
}

teardown() {
  cleanup_box
}

# One volume per path, as the old deployment mounted them, written as root
# the way the old image wrote everything. Claude Code keys its per-project
# state by absolute path, so the fixture includes one project under /root/dev
# and one elsewhere that must come through untouched.
seed_legacy() {
  LEGACY_CLAUDE="$(make_volume)"
  LEGACY_CONFIG="$(make_volume)"
  LEGACY_CODEX="$(make_volume)"
  LEGACY_DEV="$(make_volume)"
  LEGACY_SHARE="$(make_volume)"
  CACHE_VOL="$(make_volume)"
  docker run --rm -i --label "${LABEL}=1" \
    -v "${LEGACY_CLAUDE}:/root/.claude" -v "${LEGACY_CONFIG}:/root/.config" \
    -v "${LEGACY_CODEX}:/root/.codex" -v "${LEGACY_DEV}:/root/dev" \
    -v "${LEGACY_SHARE}:/root/.local/share" -v "${CACHE_VOL}:/root/.cache" \
    --entrypoint bash "$IMAGE" -s <<'SEED'
set -e
mkdir -p /root/.claude/hooks /root/.claude/plugins /root/.config/herdr /root/.config/other
printf '#!/bin/sh\n' > /root/.claude/hooks/state.sh
cat > /root/.claude/settings.json <<'JSON'
{"permissions":{"defaultMode":"plan"},
 "hooks":{"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"bash '/root/.claude/hooks/state.sh' session"}]}]}}
JSON
echo '{"official":{"installLocation":"/root/.claude/plugins/marketplaces/official"}}' \
  > /root/.claude/plugins/known_marketplaces.json
printf '[projects."/root/dev"]\ntrust_level = "trusted"\n' > /root/.codex/config.toml
cat > /root/.codex/hooks.json <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash '/root/.codex/state.sh' session"}]}]}}
JSON
printf '[worktree]\ndirectory = "/root/dev/wt"\n' > /root/.config/herdr/config.toml
echo 'workdir=/root/dev/x' > /root/.config/other/app.conf
echo '{"oauthAccount":{"emailAddress":"ada@example.com"},"projects":{"/root/dev/app":{"hasTrustDialogAccepted":true},"/srv/other":{"x":1}}}' \
  > /root/.claude/.claude.json
mkdir -p /root/.claude/projects/-root-dev-app /root/.claude/projects/-srv-other
echo '{"cwd":"/root/dev/app"}' > /root/.claude/projects/-root-dev-app/session.jsonl
echo '{}' > /root/.claude/projects/-srv-other/session.jsonl
mkdir -p /root/.config/gh
echo 'github.com: {}' > /root/.config/gh/hosts.yml
ssh-keygen -A >/dev/null
cp /etc/ssh/ssh_host_*_key* /root/.config/
echo '{"token":"t"}' > /root/.codex/auth.json
git init -q /root/dev/app
mkdir -p /root/.local/share/JetBrains
echo plugin > /root/.local/share/JetBrains/plugin
mkdir -p /root/.cache/npm
echo blob > /root/.cache/npm/blob
SEED
  export LEGACY_CLAUDE LEGACY_CONFIG LEGACY_CODEX LEGACY_DEV LEGACY_SHARE CACHE_VOL
}

# The migration deploy: the new image with the new volumes, the old ones still
# mounted at their old paths, and the old cache volume reused as the new one.
start_legacy_box() {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" \
    -v "${LEGACY_CLAUDE}:/root/.claude" -v "${LEGACY_CONFIG}:/root/.config" \
    -v "${LEGACY_CODEX}:/root/.codex" -v "${LEGACY_DEV}:/root/dev" \
    -v "${LEGACY_SHARE}:/root/.local/share"
  wait_ready
}

@test "moves a root-era deployment into dev's home" {
  seed_legacy
  start_legacy_box

  run as_dev sudo -n afkd-migrate
  [ "$status" -eq 0 ]

  # The user's own settings win over the default the entrypoint seeded.
  run as_dev jq -r '.permissions.defaultMode' .claude/settings.json
  [ "$output" = "plan" ]

  # Claude Code's state file sits at the top of home now that all of home is
  # persisted, rather than behind a symlink into the .claude volume.
  run as_dev jq -r '.oauthAccount.emailAddress' .claude.json
  [ "$output" = "ada@example.com" ]
  run as_dev test -e .claude/.claude.json
  [ "$status" -ne 0 ]

  # Projects moved from /root/dev to /home/dev/dev, so their trust, history
  # and resumable sessions are re-keyed to follow them.
  run as_dev jq -c '.projects | keys' .claude.json
  [ "$output" = '["/home/dev/dev/app","/srv/other"]' ]
  run as_dev ls .claude/projects
  [ "$output" = $'-home-dev-dev-app\n-srv-other' ]

  run as_dev cat .config/gh/hosts.yml .codex/auth.json .local/share/JetBrains/plugin .cache/npm/blob
  [ "$output" = $'github.com: {}\n{"token":"t"}\nplugin\nblob' ]

  # Host keys belong to the system volume, where the entrypoint has already
  # adopted them; a copy in home would be readable by dev.
  run as_dev sh -c 'ls .config/ssh_host_* 2>/dev/null'
  [ -z "$output" ]

  # Everything is dev's, the reused cache included, so git trusts the repos
  # and nothing needs sudo to update.
  run in_box find /home/dev ! -user dev
  [ -z "$output" ]
  run as_dev git -C dev/app status --short
  [ "$status" -eq 0 ]
}

# Tools keep absolute paths in their own config, not only in .claude.json. Left
# pointing into /root -- which dev cannot even traverse -- a hook fails on every
# start ("bash: /root/.claude/hooks/...: Permission denied"), Codex forgets which
# projects it trusts and herdr puts worktrees outside the persisted home. All of
# it was found on the first real migration.
@test "rewrites /root paths in the tools' config" {
  seed_legacy
  start_legacy_box

  run as_dev sudo -n afkd-migrate
  [ "$status" -eq 0 ]

  run as_dev jq -r '.hooks.SessionStart[0].hooks[0].command' .claude/settings.json
  [ "$output" = "bash '/home/dev/.claude/hooks/state.sh' session" ]
  run as_dev jq -r '.official.installLocation' .claude/plugins/known_marketplaces.json
  [ "$output" = "/home/dev/.claude/plugins/marketplaces/official" ]
  run as_dev jq -r '.hooks.SessionStart[0].hooks[0].command' .codex/hooks.json
  [ "$output" = "bash '/home/dev/.codex/state.sh' session" ]
  run as_dev grep -x '\[projects."/home/dev/dev"\]' .codex/config.toml
  [ "$status" -eq 0 ]
  run as_dev grep -x 'directory = "/home/dev/dev/wt"' .config/herdr/config.toml
  [ "$status" -eq 0 ]

  # And the hook the error came from actually runs as dev.
  run as_dev zsh -c "$(jq -r '.hooks.SessionStart[0].hooks[0].command' /home/dev/.claude/settings.json)"
  [ "$status" -eq 0 ]

  # Transcripts are a record of what happened at the time, under the old path.
  run as_dev cat .claude/projects/-home-dev-dev-app/session.jsonl
  [ "$output" = '{"cwd":"/root/dev/app"}' ]
}

# A config file the script knows nothing about is not rewritten blind, but it
# is not left to be found by its symptoms either.
@test "names the files it did not rewrite that still mention /root" {
  seed_legacy
  start_legacy_box

  run as_dev sudo -n afkd-migrate
  [ "$status" -eq 0 ]
  [[ "$output" == *"/home/dev/.config/other/app.conf"* ]]
  [[ "$output" != *"session.jsonl"* ]]

  run as_dev cat .config/other/app.conf
  [ "$output" = "workdir=/root/dev/x" ]
}

# The runbook was written against a deployment with every volume; the first
# real one had no cache and no .local/share volume at all. Whatever subset a
# deployment has, migrating it works, and a brand-new cache volume is dev's.
@test "migrates a deployment that only ever had some of the volumes" {
  local claude dev
  claude="$(make_volume)"
  dev="$(make_volume)"
  docker run --rm -i --label "${LABEL}=1" \
    -v "${claude}:/root/.claude" -v "${dev}:/root/dev" \
    --entrypoint bash "$IMAGE" -s <<'SEED'
set -e
echo '{"projects":{"/root/dev/app":{}}}' > /root/.claude/.claude.json
git init -q /root/dev/app
SEED
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -v "${claude}:/root/.claude" -v "${dev}:/root/dev"
  wait_ready

  run as_dev sudo -n afkd-migrate
  [ "$status" -eq 0 ]

  run as_dev jq -c '.projects | keys' .claude.json
  [ "$output" = '["/home/dev/dev/app"]' ]
  run in_box find /home/dev ! -user dev
  [ -z "$output" ]
  run as_dev git -C dev/app status --short
  [ "$status" -eq 0 ]
}

@test "--dry-run reports the plan and changes nothing" {
  seed_legacy
  start_legacy_box

  run as_dev sudo -n afkd-migrate --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"/root/.claude"* ]]

  run as_dev test -e .claude.json
  [ "$status" -ne 0 ]
  run in_box stat -c '%U' /home/dev/.cache/npm/blob
  [ "$output" = "root" ]

  # Nor does it count as the run: the real one still goes ahead.
  run as_dev sudo -n afkd-migrate
  [ "$status" -eq 0 ]
}

# A second run would copy the old tree back over whatever has been done in
# the new home since -- settings changed, sessions written.
@test "refuses to run a second time without --force" {
  seed_legacy
  start_legacy_box
  as_dev sudo -n afkd-migrate >/dev/null

  run as_dev sudo -n afkd-migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *"already migrated"* ]]

  run as_dev sudo -n afkd-migrate --force
  [ "$status" -eq 0 ]
}

@test "refuses to run without root" {
  seed_legacy
  start_legacy_box

  run as_dev afkd-migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *"sudo afkd-migrate"* ]]
}

# The likeliest mistake is running it after the old volumes were already
# unmounted. Succeeding quietly there would read as "migrated".
@test "fails when no legacy volume is mounted" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  run as_dev sudo -n afkd-migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to migrate"* ]]
}
