# Security

## Reporting a vulnerability

Report privately through GitHub's
[security advisories](https://github.com/maximn/remote-claude-code/security/advisories/new).
Please don't open a public issue for anything exploitable.

## What this image is

A remote development box reachable over SSH. It is built to hold credentials:
your GitHub SSH key, `GH_TOKEN`, and the API keys for whichever coding agents
you run. Treat a deployed instance as equivalent in value to the accounts those
credentials belong to.

Design decisions that follow from that:

- **Key-based SSH only.** `sshd_config.d/99-remote-claude.conf` turns off
  password and keyboard-interactive authentication and restricts root to
  `prohibit-password`, and the build fails unless `sshd -T` confirms every one
  of those took effect. The entrypoint refuses to boot with an empty
  `SSH_PUBLIC_KEYS` rather than come up unreachable.
- **Secrets are injected as environment variables**, never baked into the image
  or committed, and never written into home. The entrypoint rebuilds them on
  every boot outside the persisted volumes -- forwarded tokens and the GitHub
  key under `/run/remote-claude`, the ntfy hooks in Claude Code's managed
  settings -- so unsetting one on the deployment removes it from the box. Each
  is written `0600` under a `umask` so it is never briefly world-readable, and
  values interpolated into the notification hooks are shell-quoted rather than
  wrapped in hand-written quotes.
- **Authorized keys come only from `SSH_PUBLIC_KEYS`.** sshd reads a root-owned
  file the entrypoint rewrites on every boot, never `~/.ssh/authorized_keys`,
  so a key dropped from the deployment stops working on the next boot.
- **The container runs as root, with no added capabilities.** It used to be
  given `SYS_ADMIN`, `/dev/fuse` and `apparmor:unconfined`; those were for the
  Browserless/Playwright wiring the image no longer installs, and a capability
  nothing uses only widens what a compromise reaches. The only Docker option
  the image still wants is a raised `nofile`, which is a limit rather than a
  privilege. It is still not a sandbox: anyone who can log in has full control
  of the container. Don't expose port 22 to the internet without a firewall,
  and don't share a box with people you wouldn't hand those credentials to.
- **Agent permissions** are seeded in `/root/.claude/settings.json` with a small
  deny list. That is a convenience, not a security boundary.

## Scope

Issues in this repository's `Dockerfile`, `entrypoint.sh` and helper scripts are
in scope. Vulnerabilities in the tools the image installs belong upstream.
