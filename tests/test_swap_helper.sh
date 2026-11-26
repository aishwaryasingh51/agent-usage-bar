#!/bin/bash
# Tests for App/Resources/aub-swap.sh using fake app bundles in a temp dir (never touches a real install).
# Usage: tests/test_swap_helper.sh        Exit status 0 = all passed.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWAP="$ROOT/App/Resources/aub-swap.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/aub-swap-test.XXXXXX")"; W="$(cd "$W" && pwd -P)"
trap 'pkill -f -- "$W" 2>/dev/null; rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $*"; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# A fake app: Contents/MacOS/AgentUsageBar is a copy of /bin/sleep (so `ps` shows the bundle path).
# <dir>/GOOD marks a "healthy" bundle: the fake open command only starts those.
mkapp() { # path tag good
  mkdir -p "$1/Contents/MacOS"; cp /bin/sleep "$1/Contents/MacOS/AgentUsageBar"
  codesign --force --sign - "$1/Contents/MacOS/AgentUsageBar" >/dev/null 2>&1; echo "$2" >"$1/TAG"
  [ "${3:-good}" = good ] && touch "$1/GOOD"
}
cat >"$W/open.sh" <<'EOF'
#!/bin/bash
echo "open $1" >>"$(dirname "$0")/open.log"
[ -e "$1/GOOD" ] && { nohup "$1/Contents/MacOS/AgentUsageBar" 600 >/dev/null 2>&1 & }
exit 0
EOF
chmod +x "$W/open.sh"
runswap() { # installed staged backup [extra]; dead pid so the helper starts at once
  AUB_OPEN_CMD="$W/open.sh" AUB_SETTLE_SECONDS=1 /bin/bash "$SWAP" 999999 "$1" "$2" "$W/log" "$3" "${4---test-hooks}"
}
reset() { pkill -f -- "$W" 2>/dev/null; rm -rf "$W/case" "$W/log" "$W/open.log"; mkdir -p "$W/case"; }

# 1. Success: new bundle in place and running, old one saved as backup.
reset; I="$W/case/Apps/AgentUsageBar.app"; B="$W/case/support/previous/AgentUsageBar.app"
mkapp "$I" old; mkapp "$W/case/staging/AgentUsageBar.app" new
runswap "$I" "$W/case/staging/AgentUsageBar.app" "$B"; rc=$?
check "success: exit 0" '[ $rc = 0 ]'
check "success: new bundle installed" '[ "$(cat "$I/TAG")" = new ]'
check "success: old bundle kept in support/previous" '[ "$(cat "$B/TAG")" = old ]'
check "success: nothing left in Apps but the app" '[ "$(ls "$W/case/Apps")" = AgentUsageBar.app ]'

# 2. Rollback: new bundle never starts -> previous restored and opened.
reset; I="$W/case/Apps/AgentUsageBar.app"; B="$W/case/support/previous/AgentUsageBar.app"
mkapp "$I" old; mkapp "$W/case/staging/AgentUsageBar.app" new bad
runswap "$I" "$W/case/staging/AgentUsageBar.app" "$B"; rc=$?
check "rollback: exit 2" '[ $rc = 2 ]'
check "rollback: old bundle restored" '[ "$(cat "$I/TAG")" = old ]'
check "rollback: backup slot emptied" '[ ! -e "$B" ]'

# 3. Refusal: running from the backup copy (installed == backup) -> nothing deleted.
reset; B="$W/case/support/previous/AgentUsageBar.app"
mkapp "$B" old; mkapp "$W/case/staging/AgentUsageBar.app" new
runswap "$B" "$W/case/staging/AgentUsageBar.app" "$B"; rc=$?
check "backup-copy: refused" '[ $rc = 1 ] && grep -q "backup copy" "$W/log"'
check "backup-copy: nothing deleted" '[ "$(cat "$B/TAG")" = old ] && [ -d "$W/case/staging/AgentUsageBar.app" ]'

# 3b. Same, with the old *.previous.app layout / a previous/ folder holding the installed app.
reset; I="$W/case/Apps/AgentUsageBar.previous.app"; mkapp "$I" old; mkapp "$W/case/staging/AgentUsageBar.app" new
runswap "$I" "$W/case/staging/AgentUsageBar.app" "$W/case/support/previous/AgentUsageBar.app"; rc=$?
check "name *.previous.app: refused, nothing deleted" '[ $rc = 1 ] && [ "$(cat "$I/TAG")" = old ]'
reset; I="$W/case/support/previous/AgentUsageBar.app"; mkapp "$I" old; mkapp "$W/case/staging/AgentUsageBar.app" new
runswap "$I" "$W/case/staging/AgentUsageBar.app" "$W/case/other/previous/AgentUsageBar.app"; rc=$?
check "installed inside a previous/ folder: refused, nothing deleted" '[ $rc = 1 ] && [ "$(cat "$I/TAG")" = old ]'

# 4. Other refusals: odd names, dot-dot paths, staged == backup, wrong backup location.
reset; I="$W/case/Apps/Other.app"; mkapp "$I" old; mkapp "$W/case/staging/AgentUsageBar.app" new
runswap "$I" "$W/case/staging/AgentUsageBar.app" "$W/case/support/previous/AgentUsageBar.app"; rc=$?
check "installed not named AgentUsageBar.app: refused" '[ $rc = 1 ] && [ "$(cat "$I/TAG")" = old ]'
reset; I="$W/case/Apps/AgentUsageBar.app"; mkapp "$I" old; mkapp "$W/case/staging/AgentUsageBar.app" new
runswap "$W/case/Apps/../Apps/AgentUsageBar.app" "$W/case/staging/AgentUsageBar.app" "$W/case/support/previous/AgentUsageBar.app"; rc=$?
check "path with /../: refused" '[ $rc = 1 ] && [ "$(cat "$I/TAG")" = old ]'
runswap "$I" "$W/case/staging/AgentUsageBar.app" "$W/case/support/AgentUsageBar.app"; rc=$?
check "backup not in a previous/ folder: refused" '[ $rc = 1 ] && [ "$(cat "$I/TAG")" = old ]'
runswap "$I" "$W/case/support/previous/AgentUsageBar.app" "$W/case/support/previous/AgentUsageBar.app"; rc=$?
check "staged == backup: refused" '[ $rc = 1 ] && [ "$(cat "$I/TAG")" = old ]'
runswap "$I" "$I" "$W/case/support/previous/AgentUsageBar.app"; rc=$?
check "staged == installed: refused" '[ $rc = 1 ] && [ "$(cat "$I/TAG")" = old ]'

# 5. Test hooks are ignored without the explicit flag (no open command override takes effect).
reset; I="$W/case/Apps/AgentUsageBar.app"; mkapp "$I" old; mkapp "$W/case/staging/AgentUsageBar.app" new
AUB_OPEN_CMD="$W/open.sh" /bin/bash "$SWAP" notapid "$I" "$W/case/staging/AgentUsageBar.app" "$W/log" "$W/case/support/previous/AgentUsageBar.app"; rc=$?
check "no --test-hooks: env override ignored and logged" 'grep -q "ignoring AUB_OPEN_CMD" "$W/log" && [ ! -e "$W/open.log" ]'

# 6. Process detection is literal: paths with ( [ + and a decoy whose path contains the real one as a substring.
reset; BASE="$W/case/Apps (x) [1] +a"
I="$BASE/AgentUsageBar.app"; DECOY="$W/case/home$BASE/AgentUsageBar.app"   # ends with the real path
B="$W/case/support/previous/AgentUsageBar.app"
mkapp "$I" old; mkapp "$W/case/staging/AgentUsageBar.app" new; mkapp "$DECOY" decoy
# Make the staged one start fine; and run a decoy copy that must survive the swap.
nohup "$DECOY/Contents/MacOS/AgentUsageBar" 600 >/dev/null 2>&1 & DPID=$!
runswap "$I" "$W/case/staging/AgentUsageBar.app" "$B"; rc=$?
check "special chars: new app seen as running (no false rollback)" '[ $rc = 0 ] && [ "$(cat "$I/TAG")" = new ]'
check "special chars: decoy copy untouched" 'kill -0 $DPID 2>/dev/null && [ -d "$DECOY" ]'
# Rollback must kill only the exact path, not the decoy.
reset2() { rm -rf "$BASE" "$W/case/staging" "$W/case/support" "$W/log"; }
ps -axo pid=,comm= | while read -r p c; do [ "$c" = "$I/Contents/MacOS/AgentUsageBar" ] && kill "$p"; done; sleep 0.3
reset2; mkapp "$I" old; mkapp "$W/case/staging/AgentUsageBar.app" new bad
# a bad new app that IS running something at the decoy path must not count as running; decoy stays alive
runswap "$I" "$W/case/staging/AgentUsageBar.app" "$B"; rc=$?
check "decoy running does not make a dead new app look healthy" '[ $rc = 2 ] && [ "$(cat "$I/TAG")" = old ]'
check "rollback leaves the decoy process alone" 'kill -0 $DPID 2>/dev/null'
kill $DPID 2>/dev/null

echo "swap-helper tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
