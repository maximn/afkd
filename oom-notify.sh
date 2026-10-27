#!/bin/bash
# Run by earlyoom after every kill (-N in entrypoint.sh), as root, with only
# the environment the entrypoint handed earlyoom: PATH, the ntfy settings and
# BOX_NAME, plus the EARLYOOM_* variables describing what was killed.
#
# A kill on a box nobody is attached to is otherwise invisible until someone
# comes back to a pane whose agent is gone, so it pages the same phone the
# agents' own hooks do. earlyoom has already logged the kill to the container
# log either way.
#
# EARLYOOM_CMDLINE is deliberately not sent: it is whatever a process was
# started with, a token on a curl command line included, and the ntfy server
# is a third party.
set -uo pipefail

[ -n "${NTFY_URL:-}" ] || exit 0

auth=()
if [ -n "${NTFY_TOKEN:-}" ]; then
  auth=(-H "Authorization: Bearer ${NTFY_TOKEN}")
fi

exec curl -s -o /dev/null --max-time 10 "${auth[@]}" \
  -H "Title: Out of memory${BOX_NAME:+ (${BOX_NAME})}" -H 'Priority: high' -H 'Tags: warning' \
  --data-binary "stopped ${EARLYOOM_NAME:-a process} (pid ${EARLYOOM_PID:-?}) to keep the box reachable" \
  "${NTFY_URL}"
