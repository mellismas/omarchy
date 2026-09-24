#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Super+Alt+L: a tap cycles the walk-away lock mode through faceauth, a hold
# leaves a marker so the release that follows it is not taken for a tap.

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/faceauth" <<'S'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
if [[ $1 == presence && $2 == mode ]]; then
  if [[ -n ${3:-} ]]; then echo "$3" > "$STUB_MODE"; fi
  echo "{\"presence\":{\"mode\":\"$(cat "$STUB_MODE")\",\"watching\":${STUB_WATCHING:-true}}}"
fi
S
printf '#!/bin/bash\necho "notify: $*" >> "$STUB_LOG"\n' > "$tmp/bin/omarchy-notification-send"
printf '#!/bin/bash\necho "shell: $*" >> "$STUB_LOG"\n' > "$tmp/bin/omarchy-shell"
chmod +x "$tmp/bin"/*
export STUB_LOG=$tmp/log STUB_MODE=$tmp/mode XDG_RUNTIME_DIR=$tmp
run() { : > "$STUB_LOG"; PATH="$tmp/bin:$PATH" bash "$ROOT/bin/omarchy-faceauth-lockmode" "$@"; }

echo default > "$STUB_MODE"
run tap
grep -q '^presence mode secure$' "$STUB_LOG" && pass "a tap in default mode switches to secure" || fail "a tap in default mode switches to secure"
grep -q 'shell: -q omarchy.faceauth.presence refresh' "$STUB_LOG" && pass "the bar widget is told to refresh" || fail "the bar widget is told to refresh"
grep -q 'notify: .*secure' "$STUB_LOG" && pass "the new mode is announced" || fail "the new mode is announced"
run tap
grep -q '^presence mode default$' "$STUB_LOG" && pass "a tap in secure mode switches back to default" || fail "a tap in secure mode switches back to default"

STUB_WATCHING=false run tap
! grep -q '^presence mode [a-z]' "$STUB_LOG" && pass "with the watch off (or the user not enrolled) a tap changes nothing" || fail "with the watch off a tap changes nothing"
! grep -q 'notify' "$STUB_LOG" && pass "and says nothing" || fail "and says nothing"
STUB_WATCHING=false run hold
! grep -q 'notify' "$STUB_LOG" && pass "with the watch off a hold is silent too" || fail "with the watch off a hold is silent too"
( PATH="$tmp/empty:/usr/bin:/bin"; mkdir -p "$tmp/empty"; : > "$STUB_LOG"; bash "$ROOT/bin/omarchy-faceauth-lockmode" tap; [[ ! -s $STUB_LOG ]] ) && pass "without faceauth installed the chord does nothing" || fail "without faceauth installed the chord does nothing"

run hold
[[ -e $tmp/omarchy-faceauth-lockmode.hold ]] && pass "a hold leaves its marker" || fail "a hold leaves its marker"
! grep -q '^presence mode [a-z]' "$STUB_LOG" && pass "a hold never cycles the mode" || fail "a hold never cycles the mode"
run tap
[[ ! -e $tmp/omarchy-faceauth-lockmode.hold ]] && pass "the release after a hold clears the marker" || fail "the release after a hold clears the marker"
! grep -q '^presence mode [a-z]' "$STUB_LOG" && pass "and is not taken for a tap" || fail "and is not taken for a tap"
run tap
grep -q '^presence mode' "$STUB_LOG" && pass "the next tap cycles again" || fail "the next tap cycles again"
