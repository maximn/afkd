# Claude Code Remote (Clawd)

## Connection

```bash
cc                  # attach to 'main' session (or create it)
cc <name>           # attach to named session (or create it)
cc wt               # new worktree session (auto-named), launches claude --worktree
cc wt <name>        # new named worktree session, launches claude --worktree
cc ls               # list all tmux sessions on the server
cc kill <name>      # kill a specific session
cc -h               # show help
```

## Server-side (via SSH or inside a session)

```bash
t                   # attach to 'main' session (or create it)
t <name>            # attach to named session
t wt                # new worktree session, launches claude --worktree
t wt <name>         # new named worktree session
t ls                # list sessions
t kill <name>       # kill session
```

## Server

- **Host**: <server-ip>
- **Port**: 2222
- **Provider**: <provider>
- **Platform**: Coolify (Dockerfile deployment)
- **Container**: node:20-slim + openssh-server + tmux + claude-code

## Setup

### SSH Config (~/.ssh/config)

```
Host cc
    HostName <server-ip>
    Port 2222
    User root
    IdentityFile ~/.ssh/id_ed25519
```

### Install `cc` locally

```bash
ln -sf /path/to/remote-claude/bin/cc ~/.local/bin/cc
chmod +x ~/.local/bin/cc
```

### First Login

```bash
ssh cc
claude login
```
