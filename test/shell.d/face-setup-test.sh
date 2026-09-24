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
backups="$test_tmp/backups"
mkdir -p "$stub_bin" "$pamd" "$backups"

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

# Every path under /etc/pam.d or /var/backups/faceauth is redirected into the
# scratch tree, so the real scripts run unchanged and never touch the host.
map() { local p=$1; p=${p/#\/etc\/pam.d/$TEST_PAMD}; p=${p/#\/var\/backups\/faceauth/$TEST_BACKUPS}; printf '%s' "$p"; }

case "${1:-}" in
  tee)
    /usr/bin/cat >"$(map "$2")"
    ;;
  rm)
    shift; args=(); for a in "$@"; do [[ $a == -* ]] && args+=("$a") || args+=("$(map "$a")"); done
    /usr/bin/rm "${args[@]}"
    ;;
  sed)
    [[ $2 == -i && ( $3 == 1i* || $3 == '/pam_faceauth\.so/d' ) ]] || { echo "unexpected sed: $*" >&2; exit 97; }
    /usr/bin/sed -i "$3" "$(map "$4")"
    ;;
  test)
    [[ $2 == -f ]] || { echo "unexpected test: $*" >&2; exit 97; }
    [[ -f $(map "$3") ]]
    ;;
  cmp)
    [[ $2 == -s && $3 == - ]] || { echo "unexpected cmp: $*" >&2; exit 97; }
    /usr/bin/cmp -s - "$(map "$4")"
    ;;
  install)
    [[ $2 == -dm700 ]] || { echo "unexpected install: $*" >&2; exit 97; }
    /usr/bin/install -dm700 "$(map "$3")"
    ;;
  cp)
    /usr/bin/cp -p "$(map "$3")" "$(map "$4")"
    ;;
  touch)
    /usr/bin/touch "$(map "$2")"
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
  calibrate) : ;;
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

# The scripts read /etc/pam.d directly (unprivileged reads) before asking sudo
# to write; a copy retargeted at the scratch tree keeps the host out of it.
# Both must name the lock-face service exactly as expected, so the copy cannot
# quietly stop standing for the command it copies.
occurrences=$(grep -c '/etc/pam.d/omarchy-lock-face' "$setup") || occurrences=0
(( occurrences == 1 )) || fail "setup names the lock-face PAM service exactly once" "found $occurrences occurrences"
occurrences=$(grep -c '/etc/pam.d/omarchy-lock-face' "$remove") || occurrences=0
(( occurrences == 2 )) || fail "removal names the lock-face PAM service exactly twice (the check and the rm)" "found $occurrences occurrences"
retarget() {
  sed -e "s|/etc/pam.d|$pamd|g" -e "s|/var/backups/faceauth|$backups|g" "$1"
}
setup_copy="$test_tmp/setup.sh"; retarget "$setup" >"$setup_copy"
remove_copy="$test_tmp/remove.sh"; retarget "$remove" >"$remove_copy"
! grep -qE '/etc/pam\.d|/var/backups/faceauth' "$setup_copy" "$remove_copy" || fail "the retargeted copies name no real path"
pass "the scripts name the PAM service as expected, and the test drives retargeted copies"

run_script() {
  local script=$1 camera=$2 enroll=$3 auth=$4
  shift 4
  [[ $script == "$setup" ]] && script=$setup_copy
  [[ $script == "$remove" ]] && script=$remove_copy
  : >"$calls"
  # keep_pam=1 leaves the sudo stack as the previous run left it.
  (( ${keep_pam:-0} )) || printf 'auth include system-auth\n' >"$pamd/sudo"
  TEST_LOG="$calls" TEST_PAMD="$pamd" TEST_BACKUPS="$backups" TEST_CAMERA="$camera" TEST_ENROLL="$enroll" TEST_AUTH="$auth" \
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
! grep -q pam_faceauth "$pamd/sudo" || fail "setup leaves the sudo stack alone when verification fails"
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
grep -q 'pam_faceauth.so socket=/run/faceauth/sock consent' "$pamd/sudo" || fail "setup puts a consent line on the sudo stack" "$(cat "$pamd/sudo")"
grep -q '^auth      sufficient pam_faceauth.so' "$pamd/sudo" || fail "the sudo consent line is sufficient: a shake falls to the terminal prompt" "$(cat "$pamd/sudo")"
[[ $(head -1 "$pamd/sudo") == *pam_faceauth.so* ]] || fail "the consent line is the first line of the sudo stack"
[[ -f $backups/sudo.pre-face ]] || fail "setup backs up the sudo stack before changing it"
[[ -f $pamd/polkit-1 && -f $backups/polkit-1.created-by-faceauth ]] || fail "setup creates polkit-1 when absent and remembers that it did"
grep -q 'pam_faceauth.so' "$pamd/polkit-1" || fail "the created polkit-1 carries the consent line"
grep -q '^auth      \[success=done auth_err=die default=ignore\] pam_faceauth.so' "$pamd/polkit-1" || fail "the polkit consent line ends the stack on the user's no so the agent can cancel" "$(cat "$pamd/polkit-1")"
# The walk-through records the gestures after the looks, in the same run
# as the enrolment; setup no longer makes a separate calibration call.
grep -q $'faceauth\tenroll.*--guided' "$calls" || fail "setup enrols through the walk-through, which records the person's gestures" "$(cat "$calls")"
grep -q $'faceauth\tcalibrate' "$calls" && fail "setup makes no separate calibration call" "$(cat "$calls")"
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
! grep -q pam_faceauth "$pamd/sudo" || fail "removal takes the consent line off the sudo stack" "$(cat "$pamd/sudo")"
[[ ! -e $pamd/polkit-1 ]] || fail "removal deletes the polkit-1 file that setup created"
pass "removal takes the PAM service out first, deletes the templates, then drops the package"

: >"$calls"
run_script "$remove" present ok match --keep-templates || fail "removal with --keep-templates succeeds"
! grep -q $'templates\tdelete' "$calls" || fail "--keep-templates keeps the templates" "$(cat "$calls")"
pass "removal keeps the templates when asked"

run_script "$remove" present ok match --bogus && fail "removal rejects an unknown flag before deleting anything"
pass "removal rejects an unknown flag"

# The backup is restored only when nothing but our line changed since it was
# taken. A FIDO2 line added after face was set up must survive removal.
rm -rf "$backups"; mkdir -p "$backups"; rm -f "$pamd/polkit-1"
run_script "$setup" present ok match || fail "setup succeeds before the later change" "$(cat "$calls")"
[[ -f $backups/sudo.pre-face ]] || fail "setup backs up the sudo stack"
/usr/bin/sed -i '2i auth sufficient pam_u2f.so cue' "$pamd/sudo"
keep_pam=1 run_script "$remove" present ok match || fail "removal succeeds after a later change" "$(cat "$calls")"
grep -q pam_u2f.so "$pamd/sudo" || fail "removal keeps a pam_u2f line added after setup" "$(cat "$pamd/sudo")"
! grep -q pam_faceauth "$pamd/sudo" || fail "removal still takes our line off a changed stack" "$(cat "$pamd/sudo")"
[[ $(grep -c . "$pamd/sudo") == 2 ]] || fail "removal leaves the changed stack otherwise as it was" "$(cat "$pamd/sudo")"
grep -q $'sudo\tsed\t-i' "$calls" || fail "a changed stack is stripped, not restored" "$(cat "$calls")"
pass "removal strips only our line when the stack changed after setup"

# Nothing else changed: the backup is restored, then deleted so a later run
# cannot replay it.
rm -rf "$backups"; mkdir -p "$backups"; rm -f "$pamd/polkit-1"
run_script "$setup" present ok match || fail "setup succeeds before an unchanged removal" "$(cat "$calls")"
keep_pam=1 run_script "$remove" present ok match || fail "removal succeeds on an unchanged stack" "$(cat "$calls")"
[[ $(cat "$pamd/sudo") == "auth include system-auth" ]] || fail "removal restores the backed-up sudo stack" "$(cat "$pamd/sudo")"
grep -q $'sudo\tcp' "$calls" || fail "an unchanged stack is restored from the backup" "$(cat "$calls")"
[[ ! -e $backups/sudo.pre-face ]] || fail "removal deletes the backup it restored"
pass "removal restores the backup on an unchanged stack and deletes it"
