# Local Machine Setup

## SSH Config (`~/.ssh/config`)

```
# clawd - claude code remote
Host cc
    HostName <server-ip>
    Port 2222
    User dev
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

`dev` is the only account that can log in; root is refused even with an
authorized key. It has passwordless `sudo` for anything that needs root.

`IdentitiesOnly yes` stops ssh offering every key in your agent before this
one. The box allows four authentication attempts and each offered key spends
one, so without it a well-stocked agent can be refused with "Too many
authentication failures" while holding the right key.

## Shell Function (add to `~/.zshrc`)

```zsh
# cc - SSH into Claude Code remote (Clawd)
#   cc           → attach/create tmux session "main"
#   cc myproject → attach/create tmux session "myproject"
#   cc --raw     → plain SSH, no tmux
#   cc --list    → list active tmux sessions
cc() {
  if [[ "$1" == "--raw" ]]; then
    ssh cc
  elif [[ "$1" == "--list" ]]; then
    ssh cc "tmux list-sessions 2>/dev/null || echo 'No active sessions'"
  else
    local session="${1:-main}"
    ssh -t cc "TERM=xterm-256color tmux new-session -A -s '$session'"
  fi
}
```

## Usage

```bash
cc              # SSH + tmux session "main"
cc myproject    # SSH + tmux session "myproject"
cc --raw        # plain SSH, no tmux
cc --list       # list active tmux sessions
```

## Remote `t` Command

When connected via plain SSH (e.g., from a phone), use the `t` command on the remote machine:

```bash
t              # attach/create tmux session "main"
t work         # attach/create tmux session "work"
t -l           # list active sessions
t -k work      # kill session "work"
```

Inside a tmux session, run `claude` or `codex` to start coding.

Detach from tmux with `Ctrl+b d` — the session keeps running. Reconnect anytime with `cc` or `t`.

## Troubleshooting

If you get "REMOTE HOST IDENTIFICATION HAS CHANGED" after recreating the system volume:
```
ssh-keygen -R '[<server-ip>]:2222'
```
