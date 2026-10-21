# Changelog

## [0.2.0](https://github.com/maximn/remote-claude-code/compare/v0.1.0...v0.2.0) (2026-10-21)


### ⚠ BREAKING CHANGES

* 👤 run as a non-root dev user with the whole home persisted ([#45](https://github.com/maximn/remote-claude-code/issues/45))

### Features

* ✨ ship glow for reading Markdown on the box ([c4cbeba](https://github.com/maximn/remote-claude-code/commit/c4cbebafb90aff5411a7d53b73c8cbc9eb7b8ef2))
* 🐳 deploy from a docker-compose.yaml ([#50](https://github.com/maximn/remote-claude-code/issues/50)) ([a712561](https://github.com/maximn/remote-claude-code/commit/a71256114dec43c32e50e42573bea159004f61d6))
* 👤 run as a non-root dev user with the whole home persisted ([#45](https://github.com/maximn/remote-claude-code/issues/45)) ([a50f13a](https://github.com/maximn/remote-claude-code/commit/a50f13ae19a16e72ab0cdb9495535a90a053c158))
* 📋 pbcopy that copies to your local clipboard over OSC 52 ([#55](https://github.com/maximn/remote-claude-code/issues/55)) ([9e7315c](https://github.com/maximn/remote-claude-code/commit/9e7315caa3d1b348aab0781d091a8da652348da7))
* 📦 publish the image to GHCR and deploy it from CI ([#54](https://github.com/maximn/remote-claude-code/issues/54)) ([1fe81a7](https://github.com/maximn/remote-claude-code/commit/1fe81a7218fc963c3cce36a207197d7122c54b38))
* 🔐 keep secrets and image-owned config out of home ([#44](https://github.com/maximn/remote-claude-code/issues/44)) ([6cde747](https://github.com/maximn/remote-claude-code/commit/6cde7477824ed2b52e2b6a0503f68f48fa3cf49a))
* 🗂️ add eza as ll, la and lt, leaving ls alone ([#47](https://github.com/maximn/remote-claude-code/issues/47)) ([31079f9](https://github.com/maximn/remote-claude-code/commit/31079f9eedd13c0efcd84455caf9b253006099c3))
* 🧰 add an editor, man pages and a native build toolchain ([#43](https://github.com/maximn/remote-claude-code/issues/43)) ([335c9f6](https://github.com/maximn/remote-claude-code/commit/335c9f6753f25b828f07fc93a372b135f7cc4044))


### Bug Fixes

* 🌐 install every locale so a forwarded LANG works ([#48](https://github.com/maximn/remote-claude-code/issues/48)) ([8975d5a](https://github.com/maximn/remote-claude-code/commit/8975d5a61532a390bbad51f15cf9665daa191cbb))
* 🔧 rewrite /root paths in tool config when migrating to dev ([#49](https://github.com/maximn/remote-claude-code/issues/49)) ([7f14b64](https://github.com/maximn/remote-claude-code/commit/7f14b6440a88b6d7326bd057ff608fcc01c58424))


### Image toolchain

* 🐧 base the image on debian:trixie, with mise providing Node ([#42](https://github.com/maximn/remote-claude-code/issues/42)) ([c4ed393](https://github.com/maximn/remote-claude-code/commit/c4ed39358021208a48dd40386a89a33312c336bd))
* 📦 install Claude Code and Codex as native packages ([#41](https://github.com/maximn/remote-claude-code/issues/41)) ([f0ef1f3](https://github.com/maximn/remote-claude-code/commit/f0ef1f3ceeabaea3385cd1f2d5548023bb60d880))

## 0.1.0 (2026-10-14)


### Features

* 🏷️ cut versioned releases from conventional commits ([#36](https://github.com/maximn/remote-claude-code/issues/36)) ([9dda24c](https://github.com/maximn/remote-claude-code/commit/9dda24c09321c1346e5196e4ef08ee4b64b27e2c))


### Image toolchain

* **deps:** update image toolchain ([#37](https://github.com/maximn/remote-claude-code/issues/37)) ([dad25c5](https://github.com/maximn/remote-claude-code/commit/dad25c5f57386772e168529b6038e3344a1d613b))
