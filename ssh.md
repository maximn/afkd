# Local Machine Setup

## SSH Config (`~/.ssh/config`)

```
# clawd - claude code remote
Host cc
    HostName <server-ip>
    Port 2222
    User root
    IdentityFile ~/.ssh/id_ed25519
```

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

Inside a tmux session, run `claude` or `codex` to start coding.

Detach from tmux with `Ctrl+b d` — the session keeps running. Reconnect anytime with `cc`.

## Troubleshooting

If you get "REMOTE HOST IDENTIFICATION HAS CHANGED" after recreating volumes:
```
ssh-keygen -R '[<server-ip>]:2222'
```
