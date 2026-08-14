#!/usr/bin/env bash
#
# hdev session hook. Install it on SessionStart and SessionEnd — see the
# "Clean up when the session ends" section of SKILL.md.
#
# The argument says which event this is. It comes from settings.json, so
# nothing here has to guess at the shape of the hook payload.
#
#   end    reap finished jobs, then report what is left. A job VM bills until
#          something deletes it, and nothing else does.
#   start  report only. A running job is meant to outlive the session — that
#          is the whole point of hdev — so this never deletes anything.
#
# Both paths are safe to run when hdev is not installed or has no jobs.
set -u

command -v hdev >/dev/null 2>&1 || exit 0

STATE="${HDEV_STATE_DIR:-$HOME/.config/hdev}"
JOBS="$STATE/jobs.tsv"

[ -s "$JOBS" ] || exit 0

# `hdev reap` deletes the VM of every job that has finished, failed or
# vanished. It keeps running, starting and usage-limited jobs. Its output goes
# to a file because a SessionEnd hook has no terminal left to print to.
#
# Set HDEV_REAP_IDLE to a duration (for example 1h) to also clear a job whose
# agent stopped writing files that long ago. That is opt-in: deleting a job
# that still reports as running is a bigger decision than this hook should
# make on its own.
if [ "${1:-}" = end ]; then
  if [ -n "${HDEV_REAP_IDLE:-}" ]; then
    hdev reap --idle "$HDEV_REAP_IDLE" >"$STATE/last-reap.log" 2>&1 || true
  else
    hdev reap >"$STATE/last-reap.log" 2>&1 || true
  fi
fi

[ -s "$JOBS" ] || exit 0

count="$(wc -l < "$JOBS" | tr -d ' ')"
names="$(cut -f1 "$JOBS" | paste -sd' ' -)"

printf '{"systemMessage":"hdev: %s VM(s) still up and billing — %s. Run: hdev ps"}\n' \
  "$count" "$names"
