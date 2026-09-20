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
    fzf starship git-spice gs herdr claude codex \
    t h cc ch; do
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

# git-spice and herdr are fetched as release *assets* rather than via an
# installer, so a renamed or re-tagged asset yields a file that exists and does
# not run. Presence is not enough for these two -- execute them.
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

@test "root logs into zsh with the shell config sourced" {
  run in_box getent passwd root
  [[ "$output" == *"zsh"* ]]

  run in_box grep -q 'source /root/.git-aliases.zsh' /root/.zshrc
  [ "$status" -eq 0 ]

  run in_box zsh -c 'source /root/.zshrc >/dev/null 2>&1; alias gst'
  [ "$status" -eq 0 ]
  [[ "$output" == *"git status"* ]]
}

@test "knows the ghostty terminfo the local client forwards" {
  run in_box infocmp xterm-ghostty
  [ "$status" -eq 0 ]
}

@test "disables ssh password authentication" {
  run in_box grep -qE '^PasswordAuthentication no' /etc/ssh/sshd_config
  [ "$status" -eq 0 ]
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
