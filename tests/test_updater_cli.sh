#!/bin/bash
# End-to-end checks of the self-updater engine. Never touches ~/Applications or the real
# ~/Library/Application Support/AgentUsageBar: everything runs against temp dirs.
#
#   tests/test_updater_cli.sh <test-build.app> <normal-build.app> [source-repo-with-tag] [tag]
#
# <test-build.app>   built with   AUB_TEST_BUILD=1 INSTALL_DIR=<dir> ./build.sh
# <normal-build.app> built with   INSTALL_DIR=<dir> ./build.sh
# source-repo        a local clone that has the tag (default ~/Documents/agent-usage-bar, tag v0.2.2)
set -u
TESTAPP="${1:?test-build .app}"; NORMAL="${2:?normal-build .app}"
SRC="${3:-$HOME/Documents/agent-usage-bar}"; TAG="${4:-v0.2.2}"
TB="$TESTAPP/Contents/MacOS/AgentUsageBar"; NB="$NORMAL/Contents/MacOS/AgentUsageBar"
W="$(mktemp -d "${TMPDIR:-/tmp}/aub-cli-test.XXXXXX")"; W="$(cd "$W" && pwd -P)"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $*"; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# --- basics on both builds
for b in "$TB" "$NB"; do
  check "$(basename "$(dirname "$(dirname "$(dirname "$b")")")") --version" '[ "$("$b" --version)" = "Agent Usage Bar $(sed -n 1p "$(dirname "$0")/../VERSION")" ]'
  out="$("$b" --selftest 2>&1)"; check "selftest ($out)" 'echo "$out" | grep -Eq "selftest: ([0-9]+)/\1 passed"'
  check "--check-icons" '"$b" --check-icons | grep -q "claude:"'
done

# --- release build has no test hooks compiled in (and its CLI ignores them)
# (Short literals such as AUB_SUPPORT_DIR are stored inline by Swift, so only longer ones are greppable;
# the behavioural check below covers AUB_UPDATE_REPO and --fake-version.)
for s in AUB_OPEN_CMD AUB_SETTLE_SECONDS update-swap-test; do
  check "test build contains '$s'" 'strings "$TB" | grep -q -- "$s"'
  check "normal build does not contain '$s'" '! strings "$NB" | grep -q -- "$s"'
done
out="$(AUB_UPDATE_REPO=evil/repo "$NB" --update-check --fake-version 0.0.1 2>&1)"
check "normal build ignores AUB_UPDATE_REPO and --fake-version" 'echo "$out" | grep -q "repo: aishwaryasingh51/agent-usage-bar" && ! echo "$out" | grep -q "current: 0.0.1"'

# --- update check against the real repo (network)
out="$("$TB" --update-check 2>&1)"; echo "$out" | sed 's/^/     /'
check "update-check: latest v0.2.2" 'echo "$out" | grep -q "latest: v0.2.2"'
out="$("$TB" --update-check --fake-version 0.2.1 2>&1)"
check "update-check with --fake-version 0.2.1: newer yes" 'echo "$out" | grep -q "newer: yes"'

# --- dry-run with a hostile global git setup: must pass twice in a row
H="$W/home"; mkdir -p "$H/hooks"
cat >"$H/hooks/post-checkout" <<'EOF'
#!/bin/sh
echo "GLOBAL HOOK RAN" >&2
exit 1
EOF
chmod +x "$H/hooks/post-checkout"
cat >"$H/.gitconfig" <<EOF
[url "git@github.com:"]
	insteadOf = https://github.com/
[url "ssh://nowhere.invalid/"]
	insteadOf = $SRC
[core]
	hooksPath = $H/hooks
	fsmonitor = true
[credential]
	helper = !echo password=leaked
EOF
S="$W/support"
for n in 1 2; do
  out="$(HOME="$H" AUB_SUPPORT_DIR="$S" "$TB" --update-dry-run --update-tag "$TAG" --update-source "$SRC" 2>&1)"
  echo "$out" | grep -E "^(stage|RESULT|tag)" | sed 's/^/     /'
  check "dry-run $n (hostile global git config) succeeds" 'echo "$out" | grep -q "^RESULT: ok tag=$TAG"'
  check "dry-run $n: global hook did not run" '! grep -q "GLOBAL HOOK RAN" "$S/logs/update.log"'
  check "dry-run $n: lock released" '[ ! -e "$S/update.lock" ]'
done
check "dry-run: staged app is verified $TAG" '"$S/staging/AgentUsageBar.app/Contents/MacOS/AgentUsageBar" --version | grep -q "${TAG#v}"'
check "dry-run: checkout remote is the raw configured path" '[ "$(git -C "$S/src" config --get remote.origin.url)" = "$SRC" ]'

# --- a staging dir the updater did not create is never deleted
S2="$W/support2"; mkdir -p "$S2/staging"; echo keep >"$S2/staging/precious.txt"
out="$(AUB_SUPPORT_DIR="$S2" "$TB" --update-dry-run --update-tag "$TAG" --update-source "$SRC" 2>&1)"
check "foreign staging folder: refused and kept" 'echo "$out" | grep -q "RESULT: FAILED" && [ -f "$S2/staging/precious.txt" ]'

# --- a stale lock is cleared, a live one blocks
S3="$W/support3"; mkdir -p "$S3/update.lock"; echo 999999 >"$S3/update.lock/pid"
out="$(AUB_SUPPORT_DIR="$S3" "$TB" --update-dry-run --update-tag v9.9.9 --update-source "$SRC" 2>&1)"
check "stale lock cleared (fails later on the missing tag, not on the lock)" 'echo "$out" | grep -q "RESULT: FAILED" && ! echo "$out" | grep -q "already running"'
sleep 60 & LP=$!
mkdir -p "$S3/update.lock"; echo $LP >"$S3/update.lock/pid"
out="$(AUB_SUPPORT_DIR="$S3" "$TB" --update-dry-run --update-tag "$TAG" --update-source "$SRC" 2>&1)"
check "live lock blocks a second update" 'echo "$out" | grep -q "already running"'
check "blocked run leaves the holder's lock intact" '[ "$(cat "$S3/update.lock/pid")" = "$LP" ]'
mkdir -p "$S3/update.lock"; rm -f "$S3/update.lock/pid"
out="$(AUB_SUPPORT_DIR="$S3" "$TB" --update-dry-run --update-tag "$TAG" --update-source "$SRC" 2>&1)"
check "fresh lock with no pid yet counts as live" 'echo "$out" | grep -q "already running" && [ -d "$S3/update.lock" ]'
rmdir "$S3/update.lock" 2>/dev/null
kill $LP 2>/dev/null

# --- swap launched by the app (test build) hands the right arguments to the helper
mkfake() { mkdir -p "$1/Contents/MacOS"; cp /bin/sleep "$1/Contents/MacOS/AgentUsageBar"; codesign --force --sign - "$1/Contents/MacOS/AgentUsageBar" >/dev/null 2>&1; echo "$2" >"$1/TAG"; touch "$1/GOOD"; }
cat >"$W/open.sh" <<'EOF'
#!/bin/bash
[ -e "$1/GOOD" ] && { nohup "$1/Contents/MacOS/AgentUsageBar" 600 >/dev/null 2>&1 & }
exit 0
EOF
chmod +x "$W/open.sh"
S4="$W/support4"; INST="$W/Apps/AgentUsageBar.app"; STG="$W/stg/AgentUsageBar.app"
mkdir -p "$W/Apps"; cp -R "$TESTAPP" "$INST"; echo old >"$INST/TAG"; mkfake "$STG" new
AUB_SUPPORT_DIR="$S4" AUB_OPEN_CMD="$W/open.sh" AUB_SETTLE_SECONDS=1 "$INST/Contents/MacOS/AgentUsageBar" --update-swap-test "$STG" >/dev/null 2>&1
sleep 8
check "app-launched swap: new installed, old backed up in support/previous" '[ "$(cat "$INST/TAG")" = new ] && [ "$(cat "$S4/previous/AgentUsageBar.app/TAG")" = old ]'
check "app-launched swap: log says complete" 'grep -q "update complete" "$S4/logs/update.log"'
pkill -f -- "$W/Apps" 2>/dev/null

# --- running from the backup copy: the app refuses to update, nothing deleted
for where in "$S4/previous/AgentUsageBar.app" "$W/Apps/AgentUsageBar.previous.app"; do
  [ -d "$where" ] || { mkdir -p "$(dirname "$where")"; cp -R "$TESTAPP" "$where"; }
  mkfake "$W/stg2/AgentUsageBar.app" new2
  out="$(AUB_SUPPORT_DIR="$S4" "$where/Contents/MacOS/AgentUsageBar" --update-swap-test "$W/stg2/AgentUsageBar.app" 2>&1)"
  check "backup copy ($(basename "$where")): update refused" 'echo "$out" | grep -q "This is the backup copy"'
  check "backup copy ($(basename "$where")): nothing deleted" '[ -d "$where" ] && [ -d "$W/stg2/AgentUsageBar.app" ]'
done

echo "updater CLI tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
