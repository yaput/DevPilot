#!/usr/bin/env bash
# Runs a debug build of DevPilot next to the installed app without touching it: its own data
# directory, settings and Keychain entries, and no clean-up of processes it did not start.
#
#   scripts/run-isolated.sh               # reuse the isolated data from last time (or start empty)
#   scripts/run-isolated.sh --snapshot    # first copy the real tickets, plans, runs and repository
#                                         # settings; provider settings and tokens are not copied
#
# DEVPILOT_DATA_DIR picks the data directory (default: $TMPDIR/devpilot-isolated). Do not start
# runs or local runs from the copy: it shares the real worktrees.
set -euo pipefail

cd "$(dirname "$0")/.."

DATA_DIR="${DEVPILOT_DATA_DIR:-${TMPDIR:-/tmp}/devpilot-isolated}"
SUITE="dev.devpilot.DevPilot.isolated"
REAL_DATA="$HOME/Library/Application Support/DevPilot"

if [[ "${1:-}" == "--snapshot" ]]; then
  rm -rf "$DATA_DIR"
  mkdir -p "$DATA_DIR"
  # .backup gives a consistent copy of a database the installed app may be writing to.
  sqlite3 "$REAL_DATA/devpilot.sqlite" ".backup '$DATA_DIR/devpilot.sqlite'"
  [[ -d "$REAL_DATA/artifacts" ]] && cp -R "$REAL_DATA/artifacts" "$DATA_DIR/"
  defaults delete "$SUITE" >/dev/null 2>&1 || true
  for key in workspaceSettings agentSettings; do
    if value="$(defaults export dev.devpilot.DevPilot - | plutil -extract "$key" raw -o - - 2>/dev/null)"; then
      defaults write "$SUITE" "$key" -data "$(printf '%s' "$value" | base64 -D | xxd -p | tr -d '\n')"
    fi
  done
fi

mkdir -p "$DATA_DIR"
swift build
echo "Isolated DevPilot, data in $DATA_DIR"
DEVPILOT_DATA_DIR="$DATA_DIR" exec .build/debug/DevPilot
