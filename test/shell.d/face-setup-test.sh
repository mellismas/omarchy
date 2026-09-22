#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# omarchy-setup-security-face installs a package, enrols a face through a
# root-only daemon, and writes a PAM service. This runs it against stubs and
# protects the order that keeps a broken setup harmless: nothing is installed
# without an IR camera, and the PAM service is written only after enrolment
# has been verified with a live match. omarchy-remove-security-face must take
# the PAM service out before the package goes.

setup="$ROOT/bin/omarchy-setup-security-face"
remove="$ROOT/bin/omarchy-remove-security-face"

test_tmp=$(mktemp -d)
stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
pamd="$test_tmp/pam.d"
mkdir -p "$stub_bin" "$pamd"

cleanup() {
  rm -rf "$test_tmp"
  return 0
}
trap cleanup EXIT

# sudo runs nothing privileged here: it logs the call, maps a tee into the
# lock-face service onto the scratch pam.d, and otherwise answers from the
# same stubs the unprivileged path uses.
cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash

set -euo pipefail

printf 'sudo' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"

# The scripts run from copies retargeted at the scratch tree, so the paths
# arriving here are already inside it; anything else is refused.
case "${1:-}" in
  tee)
    [[ $2 == "$TEST_PAMD"/* ]] || { echo "unexpected tee target: $2" >&2; exit 97; }
    /usr/bin/cat >"$2"
    ;;
  rm)
    [[ $3 == "$TEST_PAMD"/* ]] || { echo "unexpected rm target: $3" >&2; exit 97; }
    /usr/bin/rm -f "$3"
    ;;
  faceauth|systemctl)
    exec "$@"
    ;;
  *)
    echo "unexpected sudo invocation: $*" >&2
    exit 97
    ;;
esac
SH

cat >"$stub_bin/faceauth" <<'SH'
#!/bin/bash

printf 'faceauth' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"

case "${1:-}" in
  enroll) [[ $TEST_ENROLL == ok ]] ;;
  auth)
    if [[ $TEST_AUTH == match ]]; then echo '{"result":"match","frames":2,"elapsed_ms":1500}'
    else echo '{"result":"no_match","frames":2,"elapsed_ms":4000}'; fi
    ;;
  *) : ;;
esac
SH

for cmd in omarchy-pkg-add omarchy-pkg-drop systemctl; do
  cat >"$stub_bin/$cmd" <<SH
#!/bin/bash

printf '$cmd' >>"\$TEST_LOG"
printf '\t%s' "\$@" >>"\$TEST_LOG"
printf '\n' >>"\$TEST_LOG"
[[ \${1:-} == is-active ]] && exit 0
exit 0
SH
done

cat >"$stub_bin/omarchy-pkg-missing" <<'SH'
#!/bin/bash

exit 0
SH

cat >"$stub_bin/omarchy-hw-ir-camera" <<'SH'
#!/bin/bash

[[ $TEST_CAMERA == present ]]
SH

cat >"$stub_bin/omarchy-hw-ir-camera-list" <<'SH'
#!/bin/bash

[[ $TEST_CAMERA == present ]] && echo "/dev/video2  ov7251 3-0060 (/dev/media0)"
exit 0
SH

chmod +x "$stub_bin"/*

# The scripts name the PAM service by its real path; a copy retargeted at the
# scratch tree keeps the host out of it. Both must name that path exactly once,
# so the copy cannot quietly stop standing for the command it copies.
occurrences=$(grep -c '/etc/pam.d/omarchy-lock-face' "$setup") || occurrences=0
(( occurrences == 1 )) || fail "setup names the lock-face PAM service exactly once" "found $occurrences occurrences"
occurrences=$(grep -c '/etc/pam.d/omarchy-lock-face' "$remove") || occurrences=0
(( occurrences == 2 )) || fail "removal names the lock-face PAM service exactly twice (the check and the rm)" "found $occurrences occurrences"
retarget() {
  sed -e "s|/etc/pam.d|$pamd|g" "$1"
}
setup_copy="$test_tmp/setup.sh"; retarget "$setup" >"$setup_copy"
remove_copy="$test_tmp/remove.sh"; retarget "$remove" >"$remove_copy"
! grep -q '/etc/pam.d' "$setup_copy" "$remove_copy" || fail "the retargeted copies name no real PAM path"
pass "the scripts name the PAM service once each, and the test drives retargeted copies"

run_script() {
  local script=$1 camera=$2 enroll=$3 auth=$4
  shift 4
  [[ $script == "$setup" ]] && script=$setup_copy
  [[ $script == "$remove" ]] && script=$remove_copy
  : >"$calls"
  TEST_LOG="$calls" TEST_PAMD="$pamd" TEST_CAMERA="$camera" TEST_ENROLL="$enroll" TEST_AUTH="$auth" \
    PATH="$stub_bin:$PATH" bash "$script" "$@" </dev/null >/dev/null 2>&1
}

# No IR camera: nothing is installed and nothing is written.
rm -f "$pamd/omarchy-lock-face"
run_script "$setup" absent ok match && fail "setup without an IR camera fails"
! grep -q omarchy-pkg-add "$calls" || fail "setup installs nothing without an IR camera" "$(cat "$calls")"
[[ ! -e $pamd/omarchy-lock-face ]] || fail "setup writes no PAM service without an IR camera"
pass "setup refuses without an IR camera before installing anything"

# Enrolment fails: no PAM service.
rm -f "$pamd/omarchy-lock-face"
run_script "$setup" present fail match && fail "setup with a failed enrolment fails"
[[ ! -e $pamd/omarchy-lock-face ]] || fail "setup writes no PAM service when enrolment fails"
pass "setup writes no PAM service when enrolment fails"

# Enrolment succeeds but the verification scan does not match: no PAM service.
rm -f "$pamd/omarchy-lock-face"
run_script "$setup" present ok nomatch && fail "setup with a failed verification fails"
[[ ! -e $pamd/omarchy-lock-face ]] || fail "setup writes no PAM service when verification fails"
grep -q $'faceauth\tauth\t--user' "$calls" || fail "setup verifies the enrolment with a scan" "$(cat "$calls")"
pass "setup writes no PAM service when the verification scan does not match"

# The good path: install, fetch, enable, enrol, verify, then the PAM service,
# closed by pam_deny.
rm -f "$pamd/omarchy-lock-face"
run_script "$setup" present ok match || fail "setup succeeds with a camera, an enrolment and a match" "$(cat "$calls")"
[[ -f $pamd/omarchy-lock-face ]] || fail "setup writes the lock-face PAM service"
grep -q 'pam_faceauth.so' "$pamd/omarchy-lock-face" || fail "the lock-face service names the face module"
grep -q 'pam_deny.so' "$pamd/omarchy-lock-face" || fail "the lock-face service is closed by pam_deny"
enrol_line=$(grep -n $'faceauth\tenroll' "$calls" | head -1 | cut -d: -f1)
tee_line=$(grep -n $'sudo\ttee' "$calls" | head -1 | cut -d: -f1)
(( enrol_line < tee_line )) || fail "the PAM service is written only after enrolment" "$(cat "$calls")"
grep -q $'omarchy-pkg-add\tomarchy-faceauth' "$calls" || fail "setup installs the package" "$(cat "$calls")"
grep -q $'faceauth\tmodels\tfetch' "$calls" || fail "setup fetches the models" "$(cat "$calls")"
pass "setup installs, enrols, verifies, and only then writes the lock-face PAM service"

# Never under sudo: the enrolment would be root's. EUID is read-only in
# bash, so the guard is asserted on the source.
grep -q '(( EUID == 0 ))' "$setup" || fail "setup refuses to run as root"
grep -q '(( EUID == 0 ))' "$remove" || fail "removal refuses to run as root"
pass "setup and removal carry the root guard"

# Removal takes the PAM service out before the package.
run_script "$remove" present ok match || fail "removal succeeds" "$(cat "$calls")"
[[ ! -e $pamd/omarchy-lock-face ]] || fail "removal deletes the lock-face PAM service"
rm_line=$(grep -n $'sudo\trm' "$calls" | head -1 | cut -d: -f1)
drop_line=$(grep -n 'omarchy-pkg-drop' "$calls" | head -1 | cut -d: -f1)
(( rm_line < drop_line )) || fail "the PAM service goes before the package" "$(cat "$calls")"
grep -q $'faceauth\ttemplates\tdelete' "$calls" || fail "removal deletes the templates by default" "$(cat "$calls")"
pass "removal takes the PAM service out first, deletes the templates, then drops the package"

: >"$calls"
run_script "$remove" present ok match --keep-templates || fail "removal with --keep-templates succeeds"
! grep -q $'templates\tdelete' "$calls" || fail "--keep-templates keeps the templates" "$(cat "$calls")"
pass "removal keeps the templates when asked"

run_script "$remove" present ok match --bogus && fail "removal rejects an unknown flag before deleting anything"
pass "removal rejects an unknown flag"
