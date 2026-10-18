#!/usr/bin/env bats
#
# What the image is expected to contain. Versions are pinned in the Dockerfile
# and bumped by Renovate; these tests check the pin is what actually landed,
# which catches a release being re-tagged or an install script silently
# ignoring the requested version.

load helpers

# One box for the whole file. Every assertion below is a property of the
# *image*, so a fresh container per test bought nothing and cost ten boots --
# ten volume creations, ten `ssh-keygen -A`s, ten jq merges and ten waits on
# the readiness poll -- for one image. This is the slowest file in the suite
# and the dominant cost of the build-and-test job.
setup_file() {
  generate_keypair
  start_box -e SSH_PUBLIC_KEYS="$PUBKEY"
  wait_ready
}

teardown_file() {
  cleanup_box
}

dockerfile_arg() {
  sed -n "s/^ARG $1=//p" "${BATS_TEST_DIRNAME}/../Dockerfile"
}

@test "ships the expected toolchain" {
  local tool
  for tool in git gh tmux zsh jq rg fdfind curl wget python3 make htop \
    fzf starship glow git-spice gs herdr claude codex \
    mise node npm npx corepack yarn pnpm \
    vi vim editor man gcc g++ pkg-config \
    dig ping nc lsof strace file tree eza rsync xz zip ssh \
    t h; do
    run in_box sh -c "command -v $tool"
    [ "$status" -eq 0 ] || {
      echo "missing from image: $tool"
      false
    }
  done
}

@test "installs the pinned Claude Code version" {
  local want
  want="$(dockerfile_arg CLAUDE_CODE_VERSION)"
  [ -n "$want" ]

  run in_box claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"$want"* ]]
}

# Installed from Anthropic's apt repo rather than npm, so the agent no longer
# needs Node and apt verifies the package signature. Asserted through dpkg:
# a `claude` that merely exists could still be a stray npm or native install
# shadowing the packaged one.
@test "Claude Code comes from its apt package" {
  run in_box sh -c 'dpkg -S "$(readlink -f "$(command -v claude)")"'
  [ "$status" -eq 0 ]
  [[ "$output" == claude-code:* ]]
}

# The version is the image's to choose. A self-update would land on the
# writable layer, drift from the pin, and vanish on the next redeploy.
@test "Claude Code refuses to update itself" {
  run in_box claude update
  [[ "$output" == *"disabled"* ]]
}

@test "installs the pinned Codex version" {
  local want
  want="$(dockerfile_arg CODEX_VERSION)"
  [ -n "$want" ]

  run in_box codex --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"$want"* ]]
}

# Codex is installed from its release package rather than the bare binary
# because the package carries the ripgrep and bubblewrap it runs with. A
# symlink that resolves but has lost its package around it still prints a
# version, so the neighbours are checked directly.
@test "Codex ships with its bundled helpers" {
  run in_box sh -c 'dir="$(dirname "$(dirname "$(readlink -f "$(command -v codex)")")")"; \
    test -x "$dir/codex-path/rg" && test -x "$dir/codex-resources/bwrap"'
  [ "$status" -eq 0 ]
}

# The bare install already refuses `codex update` (it cannot tell how it was
# installed), but the startup check would still offer one on every launch.
# Read off doctor's effective config, which reports `true` without the system
# file.
@test "Codex does not check for updates on startup" {
  run in_box sh -c 'codex doctor 2>&1'
  grep -qE 'startup update check +false' <<<"$output"
}

# Neither agent is installed through npm any more; a leftover global install
# would shadow the pinned one depending on PATH order.
@test "no agent is installed through npm" {
  run in_box sh -c 'npm ls -g --depth=0 2>/dev/null'
  [[ "$output" != *"@anthropic-ai/claude-code"* ]]
  [[ "$output" != *"@openai/codex"* ]]
}

@test "runs on Debian 13 (trixie)" {
  run in_box sh -c '. /etc/os-release && echo "$VERSION_CODENAME"'
  [ "$output" = "trixie" ]
}

# Node is no longer the base image's: mise installs it system-wide, outside
# any home directory, so a volume over home cannot hide it. Asserted through
# `zsh -c`, which reads /etc/zsh/zshenv the way an ssh command or an agent's
# shell does, rather than through the image ENV that only docker exec sees.
@test "provides the pinned Node to a non-interactive shell" {
  local want
  want="$(dockerfile_arg NODE_VERSION)"
  [ -n "$want" ]

  run in_box zsh -c 'node --version'
  [ "$status" -eq 0 ]
  [ "$output" = "v$want" ]
}

# The point of mise: a repo's .nvmrc picks its Node. Auto-install is off so
# the case needs no network, and the second half proves the file is actually
# read -- a version that is not installed has to be refused, not ignored.
@test "honours a project's .nvmrc" {
  local want
  want="$(dockerfile_arg NODE_VERSION)"

  run in_box zsh -c "mkdir -p /tmp/nvmrc && cd /tmp/nvmrc && echo $want > .nvmrc && mise current node"
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]

  run in_box zsh -c 'cd /tmp/nvmrc && echo 18.0.0 > .nvmrc && MISE_AUTO_INSTALL=0 node --version'
  [ "$status" -ne 0 ]
}

# The system Node is image-owned, and mise reshims only the user's own shim
# directory -- so a global install into it lands somewhere nothing on PATH
# points. npm's prefix is moved into home instead. Installed from a local
# directory so the case needs no registry.
@test "npm global installs land on PATH" {
  run in_box zsh -c 'mkdir -p /tmp/probe/bin \
    && printf "%s" "{\"name\":\"probe-cli\",\"version\":\"1.0.0\",\"bin\":{\"probe-cli\":\"bin/p.js\"}}" > /tmp/probe/package.json \
    && printf "#!/usr/bin/env node\nconsole.log(\"probe ok\")\n" > /tmp/probe/bin/p.js \
    && npm install -g /tmp/probe >/dev/null 2>&1 && probe-cli'
  [ "$status" -eq 0 ]
  [ "$output" = "probe ok" ]
}

# git, gh, git-spice, crontab and the agents' "open in editor" all reach for
# an editor, falling back to `vi` when none is set -- and the image had none,
# so every one of them failed. Resolved the way git does, so the assertion
# follows whatever git would actually launch.
@test "has an editor that git can launch" {
  run in_box zsh -c 'editor="$(git var GIT_EDITOR)" && command -v "${editor%% *}"'
  [ "$status" -eq 0 ]

  run in_box zsh -c 'echo "$EDITOR|$VISUAL"'
  [ "$output" = "vim|vim" ]
}

# `man` existing is not the point: a base whose dpkg excludes strip
# /usr/share/man installs it with nothing to read.
@test "man pages are installed, not stripped" {
  run in_box man -w git
  [ "$status" -eq 0 ]
  [[ "$output" == /usr/share/man/* ]]
}

# bin/cc is the laptop-side helper that ssh-es to the box. It used to be
# copied in as /usr/local/bin/cc, ahead of /usr/bin on PATH, so every `make`
# and node-gyp build on the box tried to ssh to a host called "cc".
@test "cc is the C compiler, not the laptop helper" {
  run in_box sh -c 'cc --version'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Free Software Foundation"* ]]

  run in_box sh -c 'ls /usr/local/bin/cc /usr/local/bin/ch 2>/dev/null'
  [ -z "$output" ]
}

# Native code is what agents hit in real repos: a Rust crate with openssl-sys,
# a Python sdist, an npm module with a binding.gyp. Linked through pkg-config
# against the headers the image ships, which is how those builds find them.
@test "compiles and links C against the shipped headers" {
  run in_box sh -c 'cd "$(mktemp -d)" \
    && printf "%s\n" "#include <openssl/ssl.h>" "#include <zlib.h>" "#include <ffi.h>" \
         "#include <stdio.h>" \
         "int main(void) { printf(\"%s %s\\n\", OPENSSL_VERSION_TEXT, zlibVersion()); return 0; }" > t.c \
    && cc t.c $(pkg-config --cflags --libs openssl zlib libffi) -o t && ./t'
  [ "$status" -eq 0 ]
  [[ "$output" == OpenSSL* ]]
}

# The case that motivated the toolchain: `npm install` on a package with a
# binding.gyp runs node-gyp, which needs a compiler, make and python. Pointed
# at the installed Node's own headers so the case needs no download.
@test "builds a native npm module" {
  run in_box zsh -c 'cd "$(mktemp -d)" \
    && printf "%s" "{\"name\":\"native-probe\",\"version\":\"1.0.0\",\"main\":\"build/Release/probe.node\"}" > package.json \
    && printf "%s" "{\"targets\":[{\"target_name\":\"probe\",\"sources\":[\"probe.c\"]}]}" > binding.gyp \
    && printf "%s\n" "#include <node_api.h>" \
         "static napi_value Init(napi_env env, napi_value exports) { return exports; }" \
         "NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)" > probe.c \
    && npm_config_nodedir="$(dirname "$(dirname "$(mise which node)")")" npm install --no-audit --no-fund >/dev/null 2>&1 \
    && node -e "require(\".\"); console.log(\"native ok\")"'
  [ "$status" -eq 0 ]
  [ "$output" = "native ok" ]
}

# In production /root/.local/share and /root/.cache are volumes, and Docker
# seeds an empty volume from whatever the image has at that path. Anything
# the build leaves there arrives once on a fresh deploy and never updates.
# Asserted against the image, since this file's shared box has run mise by now.
@test "bakes no mise state into home" {
  run docker run --rm --entrypoint sh "$IMAGE" -c \
    'ls -d /root/.local/share/mise /root/.cache/mise /root/.local/state/mise 2>/dev/null'
  [ -z "$output" ]
}

@test "installs the pinned fzf version" {
  local want
  want="$(dockerfile_arg FZF_VERSION)"
  [ -n "$want" ]

  run in_box fzf --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"$want"* ]]
}

@test "installs the pinned starship version" {
  local want
  want="$(dockerfile_arg STARSHIP_VERSION)"
  [ -n "$want" ]

  run in_box starship --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"$want"* ]]
}

# glow, git-spice and herdr are fetched as release *assets* rather than via an
# installer, so a renamed or re-tagged asset yields a file that exists and does
# not run. Presence is not enough for these -- execute them.
@test "installs the pinned glow version" {
  local want
  want="$(dockerfile_arg GLOW_VERSION)"
  [ -n "$want" ]

  run in_box glow --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"$want"* ]]
}

@test "installs the pinned git-spice version, reachable as gs" {
  local want
  want="$(dockerfile_arg GIT_SPICE_VERSION)"
  [ -n "$want" ]

  run in_box gs --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"$want"* ]]
}

@test "installs the pinned herdr version" {
  local want
  want="$(dockerfile_arg HERDR_VERSION)"
  [ -n "$want" ]

  run in_box herdr --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"$want"* ]]
}

# An interactive shell, the way a login gets one: /etc/zsh/zshrc and then
# ~/.zshrc. `zsh -i` is what makes zsh read rc files at all; its stray
# terminal chatter is dropped so only the probe's output is compared.
interactive() {
  in_box zsh -ic "$1" 2>/dev/null
}

@test "root logs into zsh with the shell config sourced" {
  run in_box getent passwd root
  [[ "$output" == *"zsh"* ]]

  run interactive 'alias gst'
  [ "$status" -eq 0 ]
  [[ "$output" == *"git status"* ]]
}

# eza gets names of its own. ls stays GNU ls, because an agent's shell can read
# the same config and parses what ls prints. --git is asserted by running it:
# a build without the git feature rejects the flag rather than ignoring it.
@test "lists with eza under ll/la/lt and leaves ls alone" {
  run interactive 'alias ll'
  [ "$status" -eq 0 ]
  [[ "$output" == *"eza -l --git"* ]]

  run interactive 'alias ls'
  [ "$status" -ne 0 ]

  run interactive 'll /'
  [ "$status" -eq 0 ]
  [[ "$output" == *"etc"* ]]
}

# The image's shell config lives under /etc and /usr/local/share, sourced from
# the system zshrc. Home is about to become a volume, and a volume keeps
# whatever it was first seeded with: config living there would stop receiving
# image updates on the first deploy.
@test "keeps image-owned shell config out of home" {
  run in_box sh -c 'ls -d /root/.omz-git /root/.git-aliases.zsh 2>/dev/null'
  [ -z "$output" ]
}

# ~/.zshrc is the user's to edit. Whatever is in it -- here, nothing of the
# image's at all -- the image's config still arrives.
@test "a ~/.zshrc of the user's own still gets the image's shell config" {
  in_box sh -c 'cp /root/.zshrc /tmp/zshrc.bak && echo "# mine" > /root/.zshrc'

  run interactive 'alias gst'
  in_box sh -c 'mv /tmp/zshrc.bak /root/.zshrc'
  [ "$status" -eq 0 ]
  [[ "$output" == *"git status"* ]]
}

# The g* shortcuts come from the oh-my-zsh git plugin, vendored at a pinned
# commit. There is no --version to check, so the pin is asserted structurally:
# a 40-char commit rather than a branch, and both files actually on disk. The
# behavioural half matters more -- a fetch that 404s leaves an empty file and a
# shell that still starts, just without any of the aliases.
@test "vendors the git plugin at a pinned commit" {
  local want
  want="$(dockerfile_arg OMZ_REF)"
  [[ "$want" =~ ^[0-9a-f]{40}$ ]]

  run in_box test -s /usr/local/share/remote-claude/zsh/omz/lib-git.zsh
  [ "$status" -eq 0 ]
  run in_box test -s /usr/local/share/remote-claude/zsh/omz/git.plugin.zsh
  [ "$status" -eq 0 ]
}

# gwip and git_main_branch exist only in the plugin, never in git-aliases.zsh,
# so they are what distinguishes "the plugin loaded" from "the overrides file
# loaded". gcm is the one deliberate divergence and is sourced after the
# plugin, so it has to win.
@test "loads the git plugin, with the local overrides winning" {
  run interactive 'alias gwip'
  [ "$status" -eq 0 ]
  [[ "$output" == *"git add -A"* ]]

  run interactive 'type git_main_branch'
  [ "$status" -eq 0 ]
  [[ "$output" == *"function"* ]]

  run interactive 'alias gcm'
  [ "$status" -eq 0 ]
  [[ "$output" == *"git checkout main"* ]]
}

@test "knows the ghostty terminfo the local client forwards" {
  run in_box infocmp xterm-ghostty
  [ "$status" -eq 0 ]
}

# Was a grep for `^PasswordAuthentication no` in /etc/ssh/sshd_config, which
# asserted the *mechanism* -- that a particular sed had rewritten a particular
# line. `sshd -T` prints the configuration as sshd has actually merged it,
# drop-in included, so this keeps holding however the setting gets there and
# stops holding the moment sshd disagrees. The Dockerfile runs the same check
# at build time; this one proves it survived into a booted container, where
# /etc/ssh has since been written over with the persisted host keys.
@test "sshd runs with the hardening drop-in in effect" {
  run in_box /usr/sbin/sshd -T
  [ "$status" -eq 0 ]

  # Regexes, not literals: sshd -T answers in its own spelling, and
  # prohibit-password comes back as the older synonym without-password.
  local kv
  for kv in 'passwordauthentication no' 'kbdinteractiveauthentication no' \
    'permitemptypasswords no' \
    'permitrootlogin (without-password|prohibit-password)' \
    'x11forwarding no' 'maxauthtries 4' \
    'clientaliveinterval 300' 'clientalivecountmax 2' \
    'authorizedkeysfile /etc/ssh/authorized_keys/%u'; do
    grep -qE "^${kv}$" <<<"$output" || {
      echo "not in effect: $kv"
      false
    }
  done
}

# Trivy caught these baked into the image: openssh-server's postinst generates
# them at build time, so every container from one image shared a host key and
# the entrypoint's `ssh-keygen -A` never replaced them. Asserted against the
# image rather than a running container, since the entrypoint creates them.
@test "bakes no ssh host keys into the image" {
  run docker run --rm "$IMAGE" sh -c 'ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l'
  [ "$status" -eq 0 ]
  [ "${output//[[:space:]]/}" = "0" ]
}

# The healthcheck lived only as a field in coolify.md, so every deployment that
# was not Coolify had none -- and a box whose entrypoint died before `exec
# sshd` looked no different from a healthy one. Docker starts probing one
# interval in, so this is normally already green by the time it is asked: the
# file shares a box and this test runs last.
@test "reports itself healthy once sshd is up" {
  run docker inspect -f '{{if .Config.Healthcheck}}yes{{end}}' "$IMAGE"
  [ "$output" = "yes" ]

  wait_healthy
}
