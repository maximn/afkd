# Security

## Reporting a vulnerability

Report privately through GitHub's
[security advisories](https://github.com/maximn/afkd/security/advisories/new).
Please don't open a public issue for anything exploitable.

## What this image is

A remote development box reachable over SSH. It is built to hold credentials:
your GitHub SSH key, `GH_TOKEN`, and the API keys for whichever coding agents
you run. Treat a deployed instance as equivalent in value to the accounts those
credentials belong to.

Design decisions that follow from that:

- **Key-based SSH only.** `sshd_config.d/99-afkd.conf` turns off
  password and keyboard-interactive authentication and refuses root logins
  outright, and the build fails unless `sshd -T` confirms every one of those
  took effect. The entrypoint refuses to boot with an empty
  `SSH_PUBLIC_KEYS` rather than come up unreachable.
- **Secrets are injected as environment variables**, never baked into the image
  or committed, and never written into home. The entrypoint rebuilds them on
  every boot outside the persisted volumes -- forwarded tokens and the GitHub
  key under `/run/afkd`, the ntfy hooks in Claude Code's managed
  settings -- so unsetting one on the deployment removes it from the box. Each
  is written `0600` under a `umask` so it is never briefly world-readable, and
  values interpolated into the notification hooks are shell-quoted rather than
  wrapped in hand-written quotes.
- **Authorized keys come only from `SSH_PUBLIC_KEYS`.** sshd reads a root-owned
  file the entrypoint rewrites on every boot, never `~/.ssh/authorized_keys`,
  so a key dropped from the deployment stops working on the next boot.
- **Sessions run as `dev`, not root.** It has passwordless `sudo`, so this is
  not a privilege boundary -- the box is single-user and dev is that user. What
  it buys is an agent that runs unattended without Claude Code's root guard
  in the way, and projects whose files are not root's. The SSH host keys live
  on their own volume, readable by root alone; secrets under
  `/run/afkd` are dev's, in a directory only root can write to.
- **The container has no added capabilities.** It used to be
  given `SYS_ADMIN`, `/dev/fuse` and `apparmor:unconfined`; those were for the
  Browserless/Playwright wiring the image no longer installs, and a capability
  nothing uses only widens what a compromise reaches. The only Docker option
  the image still wants is a raised `nofile` (set in `docker-compose.yaml`),
  which is a limit rather than a privilege. It is still not a sandbox: anyone who can log in has full control
  of the container, through `sudo`. Don't expose port 22 to the internet without a firewall,
  and don't share a box with people you wouldn't hand those credentials to.
- **The dotfiles sync runs your repo's code.** Once you have run
  `chezmoi init` on the box, it pulls and applies that repo on every boot, as
  dev and with `GH_TOKEN`, and a repo can carry scripts chezmoi runs on apply.
  Anyone who can push to that repo can run code on the box, so give push
  access only to whoever you would give a login. The ntfy settings are not
  passed to those scripts.
- **Agent permissions** are seeded in `~/.claude/settings.json` with a small
  deny list. That is a convenience, not a security boundary.

## Verifying the image

Every image CI publishes to `ghcr.io/maximn/afkd` is signed with
[cosign](https://github.com/sigstore/cosign)'s keyless signing. The signature
says the image was built by this repository's `ci.yml` on `main`:

```bash
cosign verify ghcr.io/maximn/afkd:main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/maximn/afkd/\.github/workflows/ci\.yml@refs/heads/main$'
```

Each architecture also carries a SLSA provenance attestation, recording the
commit, the workflow run and the build args, and an SPDX SBOM:

```bash
docker buildx imagetools inspect ghcr.io/maximn/afkd:main --format '{{json .Provenance}}'
docker buildx imagetools inspect ghcr.io/maximn/afkd:main --format '{{json .SBOM}}'
```

## Scope

Issues in this repository's `Dockerfile`, `entrypoint.sh` and helper scripts are
in scope. Vulnerabilities in the tools the image installs belong upstream.
