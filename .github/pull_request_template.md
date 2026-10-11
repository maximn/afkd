<!-- The title is the commit: this repo squash-merges, so whatever is in the
     title box lands on main verbatim and release-please parses it to pick the
     next version and write the changelog. Conventional commit, type first,
     gitmoji after the colon -- `fix: 🔒 ...`, not `🔒 fix: ...`. The "PR title"
     check enforces it; the type table in CONTRIBUTING.md says which type puts
     a change in the changelog and which hides it. -->

## What changed

<!-- One or two lines. Why, not just what. -->

## Verification

<!-- CI builds the image and runs tests/ against it, including a real SSH login
     from outside the container -- so "the tests pass" does not need saying
     here. This section is for what CI cannot see: anything checked by hand on
     a real box, anything you know is untested, and any change that needs the
     deployment updated before it merges (a newly required env var, a new
     mounted path). See "What CI cannot check" in CONTRIBUTING.md. -->
