#!/bin/bash
# Agent Usage Bar update swap helper. Started detached by the app, which then quits.
#   aub-swap.sh <app-pid> <installed.app> <staged.app> <logfile>
# Waits for the app to exit, keeps the old bundle as AgentUsageBar.previous.app next to it,
# moves the staged bundle into place and opens it. If the new app is not running after ~15s
# it puts the previous bundle back and opens that. Every step is logged.
# AUB_OPEN_CMD overrides /usr/bin/open (tests only).
trap '' HUP

PID="${1:-}"; INSTALLED="${2:-}"; STAGED="${3:-}"; LOG="${4:-/dev/null}"
OPEN_CMD="${AUB_OPEN_CMD:-/usr/bin/open}"

log() { printf '%s swap: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null; }
fail() { log "ERROR: $*"; exit 1; }

case "$PID" in ''|*[!0-9]*) fail "bad pid '$PID'";; esac
case "$INSTALLED" in /*.app) ;; *) fail "installed path must be an absolute .app: '$INSTALLED'";; esac
case "$STAGED" in /*.app) ;; *) fail "staged path must be an absolute .app: '$STAGED'";; esac
[ -d "$INSTALLED" ] || fail "installed bundle not found: $INSTALLED"
[ -d "$STAGED" ] || fail "staged bundle not found: $STAGED"
[ "$INSTALLED" != "$STAGED" ] || fail "installed and staged are the same"

DIR="$(dirname "$INSTALLED")"
PREV="$DIR/AgentUsageBar.previous.app"
EXE_NAME="AgentUsageBar"

is_running() { pgrep -f -- "$1/Contents/MacOS/$EXE_NAME" >/dev/null 2>&1; }

log "start: pid=$PID installed=$INSTALLED staged=$STAGED"

# 1. Wait for the app to quit (up to 60s). Never replace a running bundle.
i=0
while kill -0 "$PID" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -le 120 ] || fail "app (pid $PID) did not quit within 60s; nothing was changed"
  sleep 0.5
done
log "app exited"

# 2. Keep the current bundle as .previous (replacing an older one), then move the new one in.
if [ -e "$PREV" ]; then
  log "removing older $PREV"
  rm -rf "$PREV" || fail "could not remove old previous bundle"
fi
mv "$INSTALLED" "$PREV" || fail "could not move current bundle aside; nothing was changed"
log "moved current bundle to $PREV"
if ! mv "$STAGED" "$INSTALLED"; then
  log "ERROR: could not move the new bundle into place; restoring the previous one"
  mv "$PREV" "$INSTALLED" && log "restored previous bundle"
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
  sleep "${AUB_SETTLE_SECONDS:-3}"
  is_running "$INSTALLED" || ok=0
fi

if [ "$ok" = 1 ]; then
  log "new app is running; update complete (previous kept at $PREV)"
  exit 0
fi

# 4. Rollback.
log "new app is not running; rolling back"
pkill -f -- "$INSTALLED/Contents/MacOS/$EXE_NAME" 2>/dev/null
rm -rf "$INSTALLED"
if mv "$PREV" "$INSTALLED"; then
  log "restored previous bundle; opening it"
  "$OPEN_CMD" "$INSTALLED" >>"$LOG" 2>&1
  exit 2
fi
fail "rollback failed; the previous bundle is still at $PREV"
