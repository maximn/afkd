#!/usr/bin/env bats
#
# dotfiles-sync: the background loop that keeps a chezmoi repo in home applied.
# Each box gets a home seeded with a chezmoi source cloned from a bare repo in
# that same home, so a push to the bare repo is what a push from a laptop is.

load helpers

setup_file() {
  generate_keypair
}

teardown() {
  cleanup_box
}

# The remote is ~/remote.git and the working copy that pushes to it ~/work;
# chezmoi's own clone is the source directory. The run_after script records
# the environment chezmoi hands the repo's scripts.
seed_dotfiles() {
  HOME_VOL="$(make_volume)"
  seed_home "$HOME_VOL" '
    set -e
    git config --global user.name ci && git config --global user.email ci@test
    git init -q --bare ~/remote.git
    git clone -q ~/remote.git ~/work 2>/dev/null
    cd ~/work
    echo v1 > dot_synced
    echo v1 > dot_edited
    printf "#!/bin/sh\nenv > \"\$HOME/.apply-env\"\n" > run_after_record-env.sh
    git add -A && git commit -qm init && git push -q origin HEAD
    chezmoi init --apply file:///home/dev/remote.git'
}

push_change() {
  as_dev bash -c "cd ~/work && $1 && git commit -qam change && git push -q origin HEAD"
}

wait_for_content() {
  local file="$1" want="$2" i
  for ((i = 0; i < 60; i++)); do
    [ "$(as_dev cat "$file" 2>/dev/null)" = "$want" ] && return 0
    sleep 0.5
  done
  echo "$file never became '$want', it is '$(as_dev cat "$file" 2>/dev/null)'. logs:" >&2
  box_logs >&2
  return 1
}

sync_running() {
  in_box pgrep -u dev -f /usr/local/libexec/afkd/dotfiles-sync >/dev/null
}

@test "applies a change pushed to the dotfiles repo" {
  seed_dotfiles
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e DOTFILES_SYNC_INTERVAL=1
  wait_ready

  push_change 'echo v2 > dot_synced'
  wait_for_content /home/dev/.synced v2
}

@test "keeps a file edited on the box, applies the rest and pages once" {
  # The conflict outlives every pass, so with a one-second interval a page per
  # failure would be several pages by the time the assertions run.
  seed_dotfiles
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e DOTFILES_SYNC_INTERVAL=1 \
    -e NTFY_URL=http://127.0.0.1:8099/afkd -e BOX_NAME=ci
  wait_ready
  in_box sh -c 'python3 -c "
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        with open(\"/tmp/pages\", \"a\") as f:
            f.write(self.headers[\"Title\"] + \"\n\")
        self.send_response(200); self.end_headers()
http.server.HTTPServer((\"127.0.0.1\", 8099), H).serve_forever()
" >/dev/null 2>&1 &'
  sleep 1

  as_dev sh -c 'echo edited-on-box > ~/.edited'
  push_change 'echo v2 > dot_edited && echo v2 > dot_synced'
  wait_for_content /home/dev/.synced v2
  sleep 4

  run as_dev cat /home/dev/.edited
  [ "$output" = "edited-on-box" ]
  run in_box cat /tmp/pages
  [ "$output" = "Dotfiles sync failed (ci)" ]
}

@test "hands the repo's scripts a session's environment but not the ntfy token" {
  seed_dotfiles
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e DOTFILES_SYNC_INTERVAL=1 \
    -e GH_TOKEN=ghp_from_deployment -e NTFY_URL=http://127.0.0.1:9/afkd \
    -e NTFY_TOKEN=tk_secret
  wait_ready

  as_dev rm -f /home/dev/.apply-env
  push_change 'echo v2 > dot_synced'
  wait_for_content /home/dev/.synced v2

  run as_dev cat /home/dev/.apply-env
  [[ "$output" == *"GH_TOKEN=ghp_from_deployment"* ]]
  [[ "$output" == *"/home/dev/.local/bin"* ]]
  [[ "$output" != *"tk_secret"* ]]
  [[ "$output" != *"NTFY_URL"* ]]
}

@test "waits quietly for a home with no dotfiles repo" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e DOTFILES_SYNC_INTERVAL=1
  wait_ready
  sleep 3

  sync_running
  run box_logs
  [[ "$output" != *"dotfiles-sync"* ]]
}

@test "DOTFILES_SYNC_INTERVAL=0 turns the sync off" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e DOTFILES_SYNC_INTERVAL=0
  wait_ready

  ! sync_running
  run box_logs
  [[ "$output" == *"dotfiles sync: off"* ]]
}

@test "a DOTFILES_SYNC_INTERVAL that is not a number warns and syncs hourly" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e DOTFILES_SYNC_INTERVAL=1h
  wait_ready

  sync_running
  run box_logs
  [[ "$output" == *"DOTFILES_SYNC_INTERVAL 1h is not a number of seconds"* ]]
}
