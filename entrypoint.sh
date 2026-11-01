#!/bin/bash
# -u, because every guard in this file keys off an environment variable and a
# typo'd name reads as "unset": the guard then silently skips the thing it was
# written to protect. Every genuinely optional input below is spelled ${VAR:-}
# to say out loud that it may be absent, which makes a bare ${TYPO} an error
# rather than an empty string.
#
# -o pipefail changes nothing here today -- the pipelines that remain are
# either an `if` condition or explicitly guarded -- and is set so that the next
# pipeline added does not quietly report only its last command. Same reasoning
# as the SHELL line in the Dockerfile.
set -euo pipefail

# Everything the deployment hands over at boot -- forwarded tokens, the GitHub
# key -- is written here rather than into home. It is rebuilt from the
# environment on every boot, so unsetting a value on the deployment removes it
# from the box, and home (a volume, which keeps whatever lands in it) never
# holds a secret it did not put there itself.
#
# The files are dev's, since dev's shell and git read them; the directory is
# root's, so nothing but this script decides what is in it.
RUNTIME_DIR=/run/afkd
install -d -m 750 -o root -g dev "$RUNTIME_DIR"

# SSH host keys, on the system-state volume (HostKey in the drop-in) so the
# box keeps its identity across redeploys. Created on first boot, one per
# type, and never replaced.
HOST_KEYS=/var/lib/afkd/ssh
install -d -m 755 /var/lib/afkd
install -d -m 700 "$HOST_KEYS"

# Images before the dev user kept the keys in /root/.config. That volume is
# still mounted on the deploy that runs afkd-migrate, and adopting its keys
# here, before sshd starts, is what lets the box come up as the same host.
if ! compgen -G "$HOST_KEYS/ssh_host_*_key" >/dev/null \
   && compgen -G "/root/.config/ssh_host_*_key" >/dev/null; then
  cp /root/.config/ssh_host_*_key* "$HOST_KEYS/"
  chown root:root "$HOST_KEYS"/ssh_host_*
  chmod 600 "$HOST_KEYS"/ssh_host_*_key
  echo "adopted the SSH host keys an older image kept in /root/.config"
fi
for type in ed25519 ecdsa rsa; do
  if [ ! -f "$HOST_KEYS/ssh_host_${type}_key" ]; then
    ssh-keygen -q -t "$type" -N '' -f "$HOST_KEYS/ssh_host_${type}_key"
  fi
done

# Home is a volume, and Docker seeds an empty one from the image's /home/dev,
# ownership included. Where that did not happen the directory is root's and
# empty, and is simply handed to dev. One that is root's and holds anything
# is somebody's data -- most likely the old /root volumes mounted at the new
# path -- and taking it over is not this script's call. Refusing to boot would
# lock out the one person who can fix it, so it warns and carries on.
claim_for_dev() {
  local dir="$1" mode="$2" owner
  mkdir -p "$dir"
  owner="$(stat -c %U "$dir")"
  [ "$owner" = dev ] && return 0
  # The cache volume is mounted inside home, so its mount point is there even
  # in a home that has never held anything.
  if [ -z "$(find "$dir" -mindepth 1 -maxdepth 1 ! -path /home/dev/.cache -print -quit)" ]; then
    chown dev:dev "$dir"
    chmod "$mode" "$dir"
    return 0
  fi
  echo "warning: $dir is owned by $owner, not dev, and is not empty; leaving it as it is." \
       "If it holds the root-era volumes, run 'sudo afkd-migrate'; otherwise 'sudo chown -R dev:dev $dir'." >&2
  return 1
}

# SSH authorized keys. Password auth is off, so no keys means no way in and a
# container that looks healthy while being unreachable. Fail loudly instead.
if [ -z "${SSH_PUBLIC_KEYS:-}" ]; then
  echo "error: SSH_PUBLIC_KEYS is empty - nothing could log in. Set it to one public key per line." >&2
  exit 1
fi
# Root-owned and outside home, the only file sshd reads keys from
# (AuthorizedKeysFile in the drop-in). An authorized_keys in home would
# outlive the key's removal from SSH_PUBLIC_KEYS for as long as the volume
# under it does.
install -d -m 755 /etc/ssh/authorized_keys
(umask 022; printf '%s\n' "${SSH_PUBLIC_KEYS}" > /etc/ssh/authorized_keys/dev)
chmod 644 /etc/ssh/authorized_keys/dev

# Home itself. Its contents are written by home-init, as dev; a failure there
# costs a default settings file, not the way in, so it warns and carries on.
if claim_for_dev /home/dev 700; then
  claim_for_dev /home/dev/.cache 755 || true
  runuser -u dev -- /usr/local/libexec/afkd/home-init \
    || echo "warning: could not set up /home/dev; see the lines above" >&2
fi

# Git identity. Deliberately no fallback: these used to default to the name and
# email of this repo's author, so every deployment but one committed under an
# identity that had never touched the code -- silently, which is how a wrong
# author ends up in history and stays there. Unset is the better failure:
# git refuses to commit and prints exactly what to set.
#
# Warned about at boot rather than exited on, because it costs you a commit,
# not a way into the box.
#
# System-level, in /etc/gitconfig: the identity belongs to the deployment, a
# ~/.gitconfig of the user's own still overrides it, and nothing is written
# into home.
if [ -n "${GIT_USER_NAME:-}" ]; then
  git config --system user.name "${GIT_USER_NAME}"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
  git config --system user.email "${GIT_USER_EMAIL}"
fi
if [ -z "${GIT_USER_NAME:-}" ] || [ -z "${GIT_USER_EMAIL:-}" ]; then
  echo "warning: GIT_USER_NAME and/or GIT_USER_EMAIL are unset - git will refuse to commit until you set them." >&2
fi

# GitHub SSH key (via GITHUB_SSH_KEY env var). Under the runtime directory
# like every other secret, and wired in through the system ssh_config.d, so
# ~/.ssh/config stays the user's own.
GITHUB_KEY="$RUNTIME_DIR/github_ed25519"
if [ -n "${GITHUB_SSH_KEY:-}" ]; then
  # This has flip-flopped between base64 and raw four times (see 246779d,
  # 68e6a7f, f39b1d7): each form works in one Coolify setup and breaks the
  # other, and the docs have been out of sync with the code since 45350b9.
  # Accept both and stop guessing. CRs are stripped because Coolify can hand
  # back CRLF, which makes openssl fail with an opaque libcrypto error (ce7058e).
  # umask so the key is never briefly world-readable between write and chmod.
  # A bash substring match rather than `printf | grep -q`: under pipefail a
  # grep that finds its match and exits first leaves printf to die of SIGPIPE,
  # and the pipeline then reports 141 even though the key is a PEM. Only a key
  # larger than the pipe buffer could actually trigger it, which is not a key
  # anyone has -- but the match needs no subprocess either way.
  if [[ "${GITHUB_SSH_KEY}" == *"-----BEGIN"* ]]; then
    (umask 077; printf '%s\n' "${GITHUB_SSH_KEY}" | sed 's/\r$//' > "$GITHUB_KEY")
  else
    (umask 077; printf '%s' "${GITHUB_SSH_KEY}" | tr -d '\r\n' | base64 -d > "$GITHUB_KEY" 2>/dev/null) || true
  fi

  # A bad key must not stop sshd from coming up - you need a way in to fix it.
  if grep -q -- '-----BEGIN' "$GITHUB_KEY" 2>/dev/null; then
    # ssh rejects a key file whose last line has no trailing newline
    if [ -n "$(tail -c1 "$GITHUB_KEY")" ]; then
      echo >> "$GITHUB_KEY"
    fi
    chown dev:dev "$GITHUB_KEY"
    chmod 600 "$GITHUB_KEY"
    gh_key_ok=1
  else
    echo "warning: GITHUB_SSH_KEY is neither a PEM private key nor base64-encoded one; skipping GitHub SSH setup" >&2
    rm -f "$GITHUB_KEY"
    gh_key_ok=0
  fi
fi

if [ "${gh_key_ok:-0}" = "1" ]; then
  # GitHub's published host keys (api.github.com/meta), not an ssh-keyscan at
  # boot. A keyscan trusts whatever answers as github.com when the box starts
  # -- a hostile resolver or a hop on the path gets its own key recorded, and
  # git over ssh then talks to it without a prompt -- and it appended a fresh
  # line on every boot. Pinned keys need no network either, so a boot that
  # races DNS still gets a working known_hosts. If GitHub ever rotates, this
  # list changes with a commit, the way their announcement says to.
  # ED25519 fingerprint SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
  while read -r key; do
    grep -qxF "github.com ${key}" /etc/ssh/ssh_known_hosts 2>/dev/null \
      || echo "github.com ${key}" >> /etc/ssh/ssh_known_hosts
  done <<'GITHUB_HOST_KEYS'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
GITHUB_HOST_KEYS
  cat > /etc/ssh/ssh_config.d/50-github.conf <<SSHCFG
Host github.com
  IdentityFile ${GITHUB_KEY}
  IdentitiesOnly yes
SSHCFG
  chmod 644 /etc/ssh/ssh_config.d/50-github.conf
fi

# Forward container env vars to SSH sessions. Values can hold spaces, quotes
# or newlines (an API key with a $, a multiline token), so each one is emitted
# with %q rather than by line-parsing `env` -- one unquoted value would
# otherwise corrupt itself and every export after it. bash's %q output is
# valid zsh, including the $'...' form it uses for newlines.
#
# Empty counts as unset. Compose hands a declared-but-unset ${VAR} to the
# container as an empty string, and an empty GH_TOKEN or API key in every
# session reads as a blank credential rather than none.
#
# Sourced by /etc/zsh/afkd.zshenv, which every zsh reads. Written
# under a umask like the GitHub key above: this file holds GH_TOKEN and every
# agent API key, and a plain redirect creates it 0644 and leaves it that way
# until the chmod. The chmod stays for the case where the file already exists,
# since a redirect truncates it without touching its mode.
FORWARDED_ENV="$RUNTIME_DIR/env.zsh"
(umask 077
  for name in GH_TOKEN OPENAI_API_KEY ANTHROPIC_API_KEY \
              "${!CODEX_@}" "${!CLAUDE_@}"; do
    [ -n "${!name:-}" ] || continue
    printf 'export %s=%q\n' "$name" "${!name}"
  done > "$FORWARDED_ENV"
)
chown dev:dev "$FORWARDED_ENV"
chmod 600 "$FORWARDED_ENV"

# BOX_NAME is meant to be the hostname too -- docker-compose.yaml sets both --
# but nothing checks it on the way in. Docker refuses a hostname over 64 bytes
# but takes shorter ones that then fail to resolve: with a space in it, every
# sudo complains. A host that runs the image without Compose never sets the
# hostname at all, so the titles would name a box the prompt does not. Neither
# stops a login, so both only warn.
if [ -n "${BOX_NAME:-}" ]; then
  if ! [[ "${BOX_NAME}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    printf 'warning: BOX_NAME %q is not a valid hostname - use up to 63 lowercase letters, digits and hyphens.\n' "${BOX_NAME}" >&2
  elif [ "$(hostname)" != "${BOX_NAME}" ]; then
    echo "warning: the hostname is $(hostname), not BOX_NAME (${BOX_NAME}) - run it with --hostname ${BOX_NAME}, as docker-compose.yaml does." >&2
  fi
fi

# Agent lifecycle notifications. Rebuilt on every boot from NTFY_URL, so the
# wiring stays declarative. This is what lets a detached session page a phone
# instead of needing someone attached.
#
# They are the deployment's hooks, not the user's, so they go into Claude
# Code's managed settings: Claude merges them over whatever the user has,
# nothing in home is touched, and the token never lands on a volume. Readable
# by root and the dev group alone, since it carries the token.
#
# These two strings are commands Claude Code hands to a shell, so every
# argument that comes from the environment -- the URL, the token, the titles
# carrying BOX_NAME -- goes through one %q pass over the whole curl argv rather
# than being spliced in by hand. Hand-written quotes -- the token in "..." and
# the URL in '...' -- held only until a value contained the matching quote or,
# for the double-quoted one, anything the shell expands. All four of these ran
# as the agent's own user when the hook fired -- the first two without even
# needing a quote, since the shell expands those inside "...":
#
#   NTFY_TOKEN   tk`cmd`   |   tk$(cmd)   |   tk"; cmd;
#   NTFY_URL     https://host/topic'; cmd;
#
# jq's --arg does the JSON quoting, which is a different layer and never
# covered any of this.
#
# curl's -o /dev/null is not tidiness. A command hook's stdout is Claude Code's
# control channel: JSON there is read as the hook's decision, and a Stop hook
# that prints {"decision":"block","reason":"..."} keeps the turn going with the
# reason handed to the model as an instruction. Without -o, whoever answers at
# NTFY_URL -- the ntfy server, or anything on the path to an http:// one --
# could write that JSON and steer an agent with no one attached.
NTFY_SETTINGS=/etc/claude-code/managed-settings.d/50-ntfy.json
if [ -n "${NTFY_URL:-}" ]; then
  ntfy_auth=()
  if [ -n "${NTFY_TOKEN:-}" ]; then
    ntfy_auth=(-H "Authorization: Bearer ${NTFY_TOKEN}")
  fi
  # Several boxes can page the same phone; BOX_NAME says which one it was.
  box_suffix="${BOX_NAME:+ (${BOX_NAME})}"
  printf -v needs_you '%q ' curl -s -o /dev/null "${ntfy_auth[@]}" \
    -H "Title: Claude needs you${box_suffix}" -H 'Priority: high' -H 'Tags: warning' \
    --data-binary @- "${NTFY_URL}"
  needs_you="jq -r '.message // \"needs attention\"' | ${needs_you% }"
  printf -v finished '%q ' curl -s -o /dev/null "${ntfy_auth[@]}" \
    -H "Title: Claude finished${box_suffix}" -H 'Tags: white_check_mark' \
    -d 'turn complete' "${NTFY_URL}"
  finished="${finished% }"

  # A notification-config failure must never stop sshd from coming up.
  mkdir -p "$(dirname "$NTFY_SETTINGS")"
  if ! (umask 077
        jq -n --arg needs_you "${needs_you}" --arg finished "${finished}" \
          '{hooks: {Notification: [{hooks: [{type: "command", command: $needs_you}]}],
                    Stop:         [{hooks: [{type: "command", command: $finished}]}]}}' \
          > "$NTFY_SETTINGS") 2>/dev/null; then
    echo "warning: could not write the notification hooks" >&2
    rm -f "$NTFY_SETTINGS"
  fi
  { chown root:dev "$NTFY_SETTINGS" && chmod 640 "$NTFY_SETTINGS"; } 2>/dev/null || true
fi

# Memory. A few agents running builds or test suites at once can ask for more
# than the host has, and with no swap the kernel then kills nothing: it drops
# the code of every running program instead and reads it straight back from
# disk, which counts as progress, so its own OOM killer never fires. A 4 GB
# box sat like that for hours -- CPUs pinned, the disk reading flat out, sshd
# and herdr both up and neither able to answer -- until it was power-cycled.
#
# earlyoom acts before that point: below 10% of memory available it sends the
# process with the highest oom_score a SIGTERM, and below 5% a SIGKILL -- on
# a host with swap, only once that is nearly full as well. That loses one
# agent's turn rather than the whole box.
#
# Never root's processes, so never sshd itself. The dev-owned ones that are
# the way back in -- the session sshd runs for a login, herdr, the tmux
# server -- are picked only once nothing else is left; the panes make
# themselves the first choice in afkd.zshenv.
#
# Started with an empty environment plus what the notifier needs: it would
# otherwise hold every token forwarded above and pass them all to the script
# it runs after a kill. It reads /proc/meminfo, which in a container is the
# host's -- the right total for docker-compose.yaml, which sets no memory
# limit. -r 3600 leaves an hourly memory line in the container log, enough
# to see what a box was doing before it went quiet.
#
# In the background, so it cannot hold up sshd; once sshd is exec'd below,
# earlyoom is its child, and an earlyoom that exits is reaped by it.
env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  NTFY_URL="${NTFY_URL:-}" NTFY_TOKEN="${NTFY_TOKEN:-}" BOX_NAME="${BOX_NAME:-}" \
  earlyoom -r 3600 --ignore-root-user \
    --avoid '^(sshd-session|herdr|tmux: server)$' \
    -N /usr/local/libexec/afkd/oom-notify &

# Dotfiles catch-up: one chezmoi update per boot, for whatever was pushed while
# the box was down. A no-op until the user has run `chezmoi init`.
#
# As dev, since everything it writes is dev's home, and with an empty
# environment plus what it needs, as for earlyoom above: the tokens a session
# gets, it reads through zsh the way a session does, rather than inheriting
# every variable the container was given. In the background, so a slow apply
# cannot hold up sshd.
runuser -u dev -- env -i PATH=/usr/local/bin:/usr/bin:/bin \
  HOME=/home/dev USER=dev LOGNAME=dev SHELL=/usr/bin/zsh \
  NTFY_URL="${NTFY_URL:-}" NTFY_TOKEN="${NTFY_TOKEN:-}" BOX_NAME="${BOX_NAME:-}" \
  /usr/local/libexec/afkd/dotfiles-sync &

# nofile is raised by docker-compose.yaml, which a host that runs the image
# some other way -- a bare `docker run`, an older Dockerfile-based Coolify app --
# does not read. A JetBrains backend then hits EMFILE partway through indexing
# while the healthcheck (sshd is up) stays green, so print the limit actually in
# effect where the container log shows it.
fd_limit="$(ulimit -n)"
case "$fd_limit" in
  '' | *[!0-9]*) echo "nofile limit: ${fd_limit}" ;;  # "unlimited"
  *)
    if [ "$fd_limit" -lt 4096 ]; then
      echo "warning: nofile limit is ${fd_limit} - too low for a JetBrains backend. Run it with --ulimit nofile=65536:65536, as docker-compose.yaml does." >&2
    else
      echo "nofile limit: ${fd_limit}"
    fi
    ;;
esac

exec /usr/sbin/sshd -D
