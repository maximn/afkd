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
   to a file quotes them properly. The forwarded-env file uses `printf %q`
   for this reason. They are written under `/run/afkd` or `/etc`,
   never into home: home is persisted, and a secret that lands there outlives
   its removal from the deployment.

## Working on it

```bash
docker build -t afkd:ci .
npm install -g bats
bats --print-output-on-failure tests/
```

Every test boots the image. `start_box` mounts the three volumes a deployment
has; `as_dev` runs a command as the login user, which is what a session is, so
reach for it over `in_box` (root) for anything a user would do. Fixtures for
a home go in through `seed_home`, which writes as dev so ownership comes out
the way a real session leaves it.

If you change `entrypoint.sh` or `home-init.sh`, add the case that
would have caught the bug — the existing tests in `tests/entrypoint.bats` each
correspond to a failure that reached production. Make sure the case you add can
actually fail: `docker exec` inherits the container's environment, so reading a
variable back without clearing it first asserts nothing.

The suite cleans up the volumes it creates. If a run is interrupted, they are
all labelled: `docker volume prune --filter label=afkd-ci=1`.

Before opening a PR:

```bash
shellcheck ./*.sh tests/*.bash
for f in bin/* zsh/* git-aliases.zsh; do zsh -n "$f"; done
```

Both are globs, and CI runs the same two lines — add a script and it is
covered without anyone remembering to extend a list.

CI runs all of the above plus hadolint, actionlint and gitleaks. A PR builds
and tests the image on amd64 only, and skips the build entirely when it touches
nothing the image reads (docs, `scripts/`, Renovate config). `main` builds both
architectures and Trivy-scans them before it publishes.

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

Conventional commits, with the gitmoji *after* the type:

```
fix: 🐛 quote forwarded env vars when writing .zshenv
feat: ✨ add ch helper and pass the local TERM through to the box
build: ⬆️ bump herdr to 0.9.1
```

The repo squash-merges, so the pull request title *is* the commit that lands on
`main`. `scripts/check-pr-title.mjs` lints the title on every PR, including when
only the title is edited.

The emoji used to come first (`🔒 fix: ...`), which conventional-commit parsers
read as a commit with no type. Type first, emoji in the subject, keeps both
conventions and parses.

The type says what kind of change it is:

| Type | Use for |
|---|---|
| `feat` | Something the box can do that it could not before |
| `fix` | Something that was broken |
| `perf` | Faster or smaller, same behaviour |
| `build` | Anything that changes what is *in* the image, including Renovate's toolchain bumps |
| `revert` | Undoing an earlier commit |
| `docs` `style` `refactor` `test` `ci` `chore` | Everything that leaves the box as it was |

Mark a breaking change -- one that needs the deployment changed when it lands
-- with `!` after the type.

## Deploys

There are no versioned releases. Every push to `main` that passes CI and changes
the image publishes `ghcr.io/maximn/afkd` as `:<commit sha>` and `:main`, and
the deploy job tells Coolify to pull it, so `main` is what runs. A push that
changes nothing the image reads -- the list in `ci.yml`'s `changes` job --
neither publishes nor deploys, so docs merge without restarting the box. To
roll back, pin `IMAGE_TAG` to the sha of an earlier commit that published
([coolify.md](coolify.md#image-and-deploys)).
