# Contributing

## Ground rules

This image holds live credentials — SSH keys, GitHub tokens, agent API keys —
and it is the only way into a machine that has no password login. Two things
follow from that, and they shape most of the review feedback here:

1. **A broken entrypoint locks you out.** Anything that can fail during boot
   should warn and continue, not abort, unless the failure genuinely means
   nobody could log in anyway. `SSH_PUBLIC_KEYS` being empty is the one case
   that exits; a malformed `GITHUB_SSH_KEY` is not.
2. **Secrets arrive as environment variables and are never committed.** Values
   can contain spaces, quotes, `$` and newlines, so anything that writes them
   to a file quotes them properly. `.zshenv` uses `printf %q` for this reason.

## Working on it

```bash
docker build -t remote-claude-code:ci .
npm install -g bats
bats --print-output-on-failure tests/
```

Every test boots the image. If you change `entrypoint.sh`, add the case that
would have caught the bug — the existing tests in `tests/entrypoint.bats` each
correspond to a failure that reached production. Make sure the case you add can
actually fail: `docker exec` inherits the container's environment, so reading a
variable back without clearing it first asserts nothing.

The suite cleans up the volumes it creates. If a run is interrupted, they are
all labelled: `docker volume prune --filter label=rcc-ci=1`.

Before opening a PR:

```bash
shellcheck entrypoint.sh tests/*.bash
for f in bin/* git-aliases.zsh; do zsh -n "$f"; done
```

Both are globs, and CI runs the same two lines — add a script and it is
covered without anyone remembering to extend a list.

CI runs all of the above plus hadolint, actionlint, gitleaks and a Trivy scan
of the built image.

## What CI cannot check

The suite boots the image. It knows nothing about the deployment, so anything
that lives in Coolify rather than in this repo — environment variables, mounted
volumes, exposed ports — can be green here and broken in production.

The sharp edge is a *newly required* variable. `entrypoint.sh` exits when
`SSH_PUBLIC_KEYS` is empty, by design: no keys means nobody could log in. A
variable the running app has never been given turns a merge into a container
that refuses to boot, with CI still green. Set it on the deployment first, then
merge.

## Versions

Tool versions live in `ARG`s in the `Dockerfile`, each with a `# renovate:`
annotation directly above it, and each `ARG` sits immediately above the `RUN`
that consumes it so a bump invalidates one layer. Renovate opens the bump PRs;
CI proves the bumped image still boots. Don't replace a pin with `latest`.

## Commits

Conventional commits with a leading gitmoji, matching the existing history:

```
🐛 fix: quote forwarded env vars when writing .zshenv
✨ feat: add ch helper and pass the local TERM through to the box
⬆️ chore: bump herdr to 0.9.1
```
