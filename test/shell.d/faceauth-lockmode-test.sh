#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Super+Ctrl+Shift+L switches the walk-away lock between default and secure mode
# through faceauth, refreshes the bar widget and says which mode it is now.
# With the watch off, or without faceauth, it does nothing at all.

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/faceauth" <<'S'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
if [[ $1 == presence && $2 == mode ]]; then
  if [[ -n ${3:-} && -n ${STUB_REFUSE:-} ]]; then echo "presence mode: $STUB_REFUSE" >&2; exit 1; fi
  [[ ${STUB_FAIL:-0} == 0 || -z ${3:-} ]] || exit 1
  if [[ -n ${3:-} ]]; then echo "$3" > "$STUB_MODE"; fi
  extra=""
  [[ ${STUB_NOSECURE:-0} == 0 ]] || extra=',"secure_available":false'
  echo "{\"presence\":{\"mode\":\"$(cat "$STUB_MODE")\",\"watching\":${STUB_WATCHING:-true}$extra}}"
fi
S
printf '#!/bin/bash\necho "notify: $*" >> "$STUB_LOG"\n' > "$tmp/bin/omarchy-notification-send"
printf '#!/bin/bash\necho "shell: $*" >> "$STUB_LOG"\n' > "$tmp/bin/omarchy-shell"
chmod +x "$tmp/bin"/*
export STUB_LOG=$tmp/log STUB_MODE=$tmp/mode
# The notices come from this tree's catalog, whatever checkout the session runs.
export OMARCHY_PATH="$ROOT"
run() { : > "$STUB_LOG"; PATH="$tmp/bin:$PATH" bash "$ROOT/bin/omarchy-faceauth-lockmode" "$@"; }

# The script under test switches the walk-away mode of whatever faceauth it
# finds, and a developer's machine may have the real one. Every run must
# resolve faceauth to the stub, or to nothing at all.
[[ $(PATH="$tmp/bin:$PATH" command -v faceauth) == "$tmp/bin/faceauth" ]] || fail "the runs resolve faceauth to the stub, never an installed one"
pass "the runs resolve faceauth to the stub, never an installed one"

echo default > "$STUB_MODE"
run
grep -q '^presence mode secure$' "$STUB_LOG" || fail "default mode switches to secure" "$(cat "$STUB_LOG")"
pass "default mode switches to secure"
grep -q 'shell: -q omarchy.faceauth.presence refresh' "$STUB_LOG" || fail "the bar widget is told to refresh" "$(cat "$STUB_LOG")"
pass "the bar widget is told to refresh"
grep -q 'notify: .*secure' "$STUB_LOG" || fail "the new mode is announced" "$(cat "$STUB_LOG")"
pass "the new mode is announced"
run
grep -q '^presence mode default$' "$STUB_LOG" || fail "secure mode switches back to default" "$(cat "$STUB_LOG")"
pass "secure mode switches back to default"

STUB_FAIL=1 run
grep -q 'notify: -u low Walk-away lock The mode could not be changed' "$STUB_LOG" || fail "a switch the daemon refuses is reported" "$(cat "$STUB_LOG")"
! grep -q 'shell:' "$STUB_LOG" || fail "a refused switch refreshes nothing" "$(cat "$STUB_LOG")"
pass "a switch the daemon refuses is reported and refreshes nothing"

# A switch the daemon refuses with a reason says that reason, not a guess.
echo default > "$STUB_MODE"
STUB_REFUSE="the camera has not been opened since faceauth started" run
grep -q "notify: -u low Walk-away lock the camera has not been opened since faceauth started" "$STUB_LOG" || fail "the daemon's reason is shown" "$(cat "$STUB_LOG")"
! grep -q 'shell:' "$STUB_LOG" || fail "a refused switch refreshes nothing" "$(cat "$STUB_LOG")"
pass "a switch the daemon refuses says the daemon's reason"

# A camera that cannot flash its IR light cannot hold the secure mode's
# promise, and the daemon says so: the chord does not ask for it and says
# why, rather than reporting a failure.
echo default > "$STUB_MODE"
STUB_NOSECURE=1 run
! grep -q '^presence mode secure$' "$STUB_LOG" || fail "secure is not asked for on a camera that cannot flash" "$(cat "$STUB_LOG")"
grep -q "notify: -u low Walk-away lock: secure is not available .*IR light" "$STUB_LOG" || fail "the chord says why secure is not available" "$(cat "$STUB_LOG")"
! grep -q 'could not be changed' "$STUB_LOG" || fail "it is not reported as a failure" "$(cat "$STUB_LOG")"
pass "on a camera that cannot flash, the chord stays in default and says why"

STUB_WATCHING=false run
! grep -q '^presence mode [a-z]' "$STUB_LOG" || fail "with the watch off (or the user not enrolled) nothing changes" "$(cat "$STUB_LOG")"
! grep -q 'notify\|shell:' "$STUB_LOG" || fail "with the watch off nothing is said" "$(cat "$STUB_LOG")"
pass "with the watch off (or the user not enrolled) the chord changes and says nothing"

# Without faceauth: a PATH of only what the script needs, so an installed
# faceauth cannot be reached. The notification and shell stubs log, so a
# run that got past the missing-command check would show.
nofa=$tmp/no-faceauth
mkdir -p "$nofa"
for cmd in bash; do ln -s "$(command -v "$cmd")" "$nofa/$cmd"; done
ln -s "$ROOT/bin/omarchy-cmd-present" "$nofa/omarchy-cmd-present"
ln -s "$tmp/bin/omarchy-notification-send" "$nofa/omarchy-notification-send"
ln -s "$tmp/bin/omarchy-shell" "$nofa/omarchy-shell"
! PATH="$nofa" command -v faceauth >/dev/null || fail "the no-faceauth run cannot reach any faceauth"
( PATH="$nofa"; : > "$STUB_LOG"; bash "$ROOT/bin/omarchy-faceauth-lockmode"; [[ ! -s $STUB_LOG ]] ) || fail "without faceauth installed the chord does nothing"
pass "without faceauth installed the chord does nothing"

# One binding, one command: the chord takes no hold and passes no argument.
bindings="$ROOT/default/hypr/bindings/faceauth.lua"
(( $(grep -c 'o.bind(' "$bindings") == 1 )) || fail "Super+Ctrl+Shift+L is one binding" "$(cat "$bindings")"
grep -q 'o.bind("SUPER + CTRL + SHIFT + L", "Cycle face walk-away lock mode", "omarchy-faceauth-lockmode")' "$bindings" || fail "the binding runs the script with no argument" "$(cat "$bindings")"
grep -q 'if o.cmd_present("faceauth") then' "$bindings" || fail "the binding is listed only where faceauth is installed" "$(cat "$bindings")"
pass "Super+Ctrl+Shift+L is one binding, listed only where faceauth is installed"
