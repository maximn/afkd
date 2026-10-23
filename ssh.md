# Local Machine Setup

## SSH Config (`~/.ssh/config`)

```
Host afk
    HostName <server-ip>
    Port 2222
    User dev
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

`afk` is the host the `afk` command connects to. Under another name, set
`AFK_HOST` to it.

`dev` is the only account that can log in; root is refused even with an
authorized key. It has passwordless `sudo` for anything that needs root.

`IdentitiesOnly yes` stops ssh offering every key in your agent before this
one. The box allows four authentication attempts and each offered key spends
one, so without it a well-stocked agent can be refused with "Too many
authentication failures" while holding the right key.

## The `afk` command

Symlink it from a checkout of this repo:

```bash
ln -sf "$PWD/bin/afk" ~/.local/bin/afk
```

```bash
afk              # SSH + tmux session "main"
afk myproject    # SSH + tmux session "myproject"
afk ls           # list tmux sessions
afk kill work    # kill session "work"
afk herdr        # SSH + the default herdr session
afk ssh          # plain SSH, no multiplexer
```

The same `afk` is on the box, where it skips the SSH: over plain SSH from a
phone, run `afk`, `afk work` or `afk ls` there. For herdr from a phone, see
[phone.md](phone.md).

Inside a tmux session, run `claude` or `codex` to start coding.

Detach from tmux with `Ctrl+b d` — the session keeps running. Reconnect
anytime with `afk`.

## Troubleshooting

If you get "REMOTE HOST IDENTIFICATION HAS CHANGED" after recreating the system volume:
```
ssh-keygen -R '[<server-ip>]:2222'
```
