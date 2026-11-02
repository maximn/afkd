#!/usr/bin/env bats
#
# dotfiles-sync: the pass at boot that catches a chezmoi repo in home up, and
# the ssh update a laptop runs while the box is up. Each box gets a home seeded
# with a chezmoi source cloned from a bare repo in that same home, so a push to
# the bare repo is what a push from a laptop is.

load helpers

setup_file() {
  generate_keypair
}

teardown() {
  cleanup_box
}

# The remote is ~/remote.git and the working copy that pushes to it ~/work;
# chezmoi's own clone is the source directory. The run_after script records
# the environment chezmoi hands the repo's scripts, and the seed removes what
# chezmoi init left there, so a record found later came from the box.
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
    printf "#!/bin/sh\nenv > \"\$HOME/.apply-env.tmp\" && mv \"\$HOME/.apply-env.tmp\" \"\$HOME/.apply-env\"\n" > run_after_record-env.sh
    git add -A && git commit -qm init && git push -q origin HEAD
    chezmoi init --apply file:///home/dev/remote.git
    rm ~/.apply-env'
}

push_while_down() {
  seed_home "$HOME_VOL" "set -e; cd ~/work; $1; git add -A; git commit -qm change; git push -q origin HEAD"
}

push_while_up() {
  as_dev bash -c "set -e; cd ~/work; $1; git add -A; git commit -qm change; git push -q origin HEAD"
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

wait_for_file() {
  local i
  for ((i = 0; i < 60; i++)); do
    as_dev test -e "$1" && return 0
    sleep 0.5
  done
  echo "$1 never appeared. logs:" >&2
  box_logs >&2
  return 1
}

sync_running() {
  in_box pgrep -u dev -f /usr/local/libexec/afkd/dotfiles-sync >/dev/null
}

wait_for_sync_to_exit() {
  local i
  for ((i = 0; i < 60; i++)); do
    sync_running || return 0
    sleep 0.5
  done
  echo "dotfiles-sync is still running" >&2
  return 1
}

@test "catches up at boot with a change pushed while the box was down, then exits" {
  seed_dotfiles
  push_while_down 'echo v2 > dot_synced'
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  wait_for_content /home/dev/.synced v2
  wait_for_sync_to_exit
}

@test "a laptop's ssh update reaches a running box" {
  seed_dotfiles
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -p 127.0.0.1::22
  wait_ready
  wait_for_file /home/dev/.apply-env
  wait_for_sync_to_exit
  push_while_up 'echo v2 > dot_synced'

  run ssh -n -i "$KEYFILE" -p "$(host_port)" \
    -o BatchMode=yes -o IdentitiesOnly=yes -o LogLevel=ERROR \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    dev@127.0.0.1 'zsh -c "chezmoi update --init --no-tty --keep-going --error-on-conflict"'
  echo "$output"
  [ "$status" -eq 0 ]
  run as_dev cat /home/dev/.synced
  [ "$output" = "v2" ]
}

@test "the pass at boot leaves nothing for a session's chezmoi to change" {
  # sshd sessions and the entrypoint start from different umasks, and chezmoi
  # derives a target's mode from the umask it runs under.
  seed_dotfiles
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -p 127.0.0.1::22
  wait_ready
  wait_for_file /home/dev/.apply-env
  wait_for_sync_to_exit

  run ssh -n -i "$KEYFILE" -p "$(host_port)" \
    -o BatchMode=yes -o IdentitiesOnly=yes -o LogLevel=ERROR \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    dev@127.0.0.1 'zsh -c "chezmoi status --exclude=scripts"'
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "at boot keeps a file edited on the box, applies the rest and pages" {
  # The repo's run_before script holds the pass until the test's ntfy listener
  # is up, which needs sshd up first, so this also proves the pass does not
  # hold up sshd.
  seed_dotfiles
  seed_home "$HOME_VOL" 'echo edited-on-box > ~/.edited'
  push_while_down '
    echo v2 > dot_edited
    echo v2 > dot_synced
    printf "#!/bin/sh\nuntil [ -e /tmp/listening ]; do sleep 0.2; done\n" > run_before_wait-for-listener.sh'
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" -e NTFY_URL=http://127.0.0.1:8099/afkd -e BOX_NAME=ci
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
  in_box touch /tmp/listening

  wait_for_content /home/dev/.synced v2
  wait_for_sync_to_exit

  run as_dev cat /home/dev/.edited
  [ "$output" = "edited-on-box" ]
  run in_box cat /tmp/pages
  [ "$output" = "Dotfiles sync failed (ci)" ]
}

@test "hands the repo's scripts a session's environment but not the ntfy token" {
  seed_dotfiles
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY" \
    -e GH_TOKEN=ghp_from_deployment -e NTFY_URL=http://127.0.0.1:9/afkd \
    -e NTFY_TOKEN=tk_secret
  wait_ready

  wait_for_file /home/dev/.apply-env
  run as_dev cat /home/dev/.apply-env
  [[ "$output" == *"GH_TOKEN=ghp_from_deployment"* ]]
  [[ "$output" == *"/home/dev/.local/bin"* ]]
  [[ "$output" != *"tk_secret"* ]]
  [[ "$output" != *"NTFY_URL"* ]]
}

@test "exits quietly on a home with no dotfiles repo" {
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready

  wait_for_sync_to_exit
  run box_logs
  [[ "$output" != *"dotfiles-sync"* ]]
}
