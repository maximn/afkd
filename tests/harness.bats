#!/usr/bin/env bats
#
# The harness itself. `make_volume` spent its whole life appending to a shell
# array from inside a command substitution, so the append died with the
# subshell, `cleanup_box` iterated over nothing, and every local `bats tests/`
# left ~25 volumes behind -- each holding the ssh host *private* keys the
# entrypoint had just persisted into it. A helper that silently does nothing is
# the same false confidence a test that cannot fail is, so it gets tests too.
#
# These touch volumes only: no image, no boot, a second or so for the file.

load helpers

teardown() {
  cleanup_box
}

@test "make_volume creates the volume and records it for cleanup" {
  local v
  v="$(make_volume)"

  run docker volume inspect "$v"
  [ "$status" -eq 0 ]

  run grep -cx "$v" "${BATS_FILE_TMPDIR}/volumes"
  [ "$output" = "1" ]
}

@test "cleanup_box removes every volume the test created" {
  local a b
  a="$(make_volume)"
  b="$(make_volume)"

  cleanup_box

  run docker volume inspect "$a"
  [ "$status" -ne 0 ]

  run docker volume inspect "$b"
  [ "$status" -ne 0 ]
}

@test "every volume carries the label that sweeps up an interrupted run" {
  local v
  v="$(make_volume)"

  run docker volume ls -q --filter "label=${LABEL}=1" --filter "name=${v}"
  [ "$output" = "$v" ]
}
