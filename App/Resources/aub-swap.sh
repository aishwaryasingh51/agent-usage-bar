#!/bin/bash
# Agent Usage Bar update swap helper. Started detached by the app, which then quits.
#   aub-swap.sh <app-pid> <installed.app> <staged.app> <logfile> <backup.app> [--test-hooks]
# Waits for the app to exit, moves the installed bundle to <backup.app> (the app passes
# <support>/previous/AgentUsageBar.app), moves the staged bundle into place and opens it.
# If the new app is not running after ~15s it puts the backup back and opens that.
# This file is copied out of the app at update time, so each update runs the helper of the
# version being replaced; keep it small. Every step is logged.
# --test-hooks (only ever passed by test builds) lets AUB_OPEN_CMD / AUB_SETTLE_SECONDS apply.
trap '' HUP

PID="${1:-}"; INSTALLED="${2:-}"; STAGED="${3:-}"; LOG="${4:-/dev/null}"; BACKUP="${5:-}"
OPEN_CMD=/usr/bin/open
SETTLE=3
log() { printf '%s swap: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null; }
fail() { log "ERROR: $*"; exit 1; }

if [ "${6:-}" = "--test-hooks" ]; then
  OPEN_CMD="${AUB_OPEN_CMD:-$OPEN_CMD}"; SETTLE="${AUB_SETTLE_SECONDS:-$SETTLE}"
elif [ -n "${AUB_OPEN_CMD:-}${AUB_SETTLE_SECONDS:-}" ]; then
  log "ignoring AUB_OPEN_CMD/AUB_SETTLE_SECONDS (test hooks not enabled)"
fi

# Every path must be absolute, free of . / .. components, and end in .app; nothing is deleted before these pass.
safe_app() {
  case "$1" in /*.app) ;; *) return 1;; esac
  case "$1/" in */../*|*/./*|*//*) return 1;; esac
  return 0
}
case "$PID" in ''|*[!0-9]*) fail "bad pid '$PID'";; esac
safe_app "$INSTALLED" || fail "installed path must be a plain absolute .app path: '$INSTALLED'"
safe_app "$STAGED" || fail "staged path must be a plain absolute .app path: '$STAGED'"
safe_app "$BACKUP" || fail "backup path must be a plain absolute .app path: '$BACKUP'"
EXE_NAME="AgentUsageBar"
[ "$(basename "$INSTALLED")" = "$EXE_NAME.app" ] || fail "installed bundle must be named $EXE_NAME.app: '$INSTALLED'"
[ "$(basename "$BACKUP")" = "$EXE_NAME.app" ] && [ "$(basename "$(dirname "$BACKUP")")" = "previous" ] \
  || fail "backup must be .../previous/$EXE_NAME.app: '$BACKUP'"
# Updating from the backup copy would delete the running app; refuse.
[ "$INSTALLED" != "$BACKUP" ] || fail "this is the backup copy; open the installed $EXE_NAME.app to update"
[ "$(basename "$(dirname "$INSTALLED")")" != "previous" ] || fail "this is the backup copy; open the installed $EXE_NAME.app to update"
[ "$INSTALLED" != "$STAGED" ] && [ "$STAGED" != "$BACKUP" ] || fail "installed, staged and backup must be three different bundles"
[ -d "$INSTALLED" ] || fail "installed bundle not found: $INSTALLED"
[ -d "$STAGED" ] || fail "staged bundle not found: $STAGED"

# PIDs whose executable path is exactly this string (literal compare: no regex, no substring).
pids_of() { ps -axo pid=,comm= 2>/dev/null | while read -r p c; do [ "$c" = "$1" ] && printf '%s\n' "$p"; done; }
is_running() { [ -n "$(pids_of "$1/Contents/MacOS/$EXE_NAME")" ]; }

log "start: pid=$PID installed=$INSTALLED staged=$STAGED backup=$BACKUP"

# 1. Wait for the app to quit (up to 60s). Never replace a running bundle.
i=0
while kill -0 "$PID" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -le 120 ] || fail "app (pid $PID) did not quit within 60s; nothing was changed"
  sleep 0.5
done
log "app exited"
# Another instance of the same installed bundle (open -n) would keep matching is_running and mask a broken new build.
is_running "$INSTALLED" && fail "another instance of $INSTALLED is still running; nothing was changed"

# 2. Move the current bundle to the backup spot (replacing an older backup), then the new one in.
mkdir -p "$(dirname "$BACKUP")" || fail "could not create the backup folder"
if [ -e "$BACKUP" ]; then
  log "removing older backup $BACKUP"
  rm -rf "$BACKUP" || fail "could not remove old backup"
fi
mv "$INSTALLED" "$BACKUP" || fail "could not move current bundle aside; nothing was changed"
log "moved current bundle to $BACKUP"
if ! mv "$STAGED" "$INSTALLED"; then
  log "ERROR: could not move the new bundle into place; restoring the previous one"
  rm -rf "$INSTALLED"   # a failed cross-volume move can leave a partial copy
  if mv "$BACKUP" "$INSTALLED"; then log "restored previous bundle"
  else log "ERROR: could not restore the previous bundle from $BACKUP"; exit 1; fi
  "$OPEN_CMD" "$INSTALLED" >>"$LOG" 2>&1
  exit 1
fi
log "moved new bundle into $INSTALLED"

# 3. Open the new app and wait up to ~15s for it to be running; then make sure it stays up.
"$OPEN_CMD" "$INSTALLED" >>"$LOG" 2>&1 || log "open returned an error"
ok=0
for _ in $(seq 1 30); do
  if is_running "$INSTALLED"; then ok=1; break; fi
  sleep 0.5
done
if [ "$ok" = 1 ]; then
  sleep "$SETTLE"
  is_running "$INSTALLED" || ok=0
fi

if [ "$ok" = 1 ]; then
  log "new app is running; update complete (previous kept at $BACKUP)"
  exit 0
fi

# 4. Rollback: stop only processes running exactly this bundle's executable, then restore.
log "new app is not running; rolling back"
for p in $(pids_of "$INSTALLED/Contents/MacOS/$EXE_NAME"); do kill "$p" 2>/dev/null; done
sleep 1
for p in $(pids_of "$INSTALLED/Contents/MacOS/$EXE_NAME"); do kill -9 "$p" 2>/dev/null; done
rm -rf "$INSTALLED"
if mv "$BACKUP" "$INSTALLED"; then
  log "restored previous bundle; opening it"
  "$OPEN_CMD" "$INSTALLED" >>"$LOG" 2>&1
  exit 2
fi
fail "rollback failed; the previous bundle is still at $BACKUP"
