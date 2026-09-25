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
store="$test_tmp/store"
out="$test_tmp/out.log"
mkdir -p "$stub_bin" "$pamd" "$backups" "$store"

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

# Every path under /etc/pam.d, /var/backups/faceauth or /var/lib/faceauth is
# redirected into the scratch tree, so the real scripts run unchanged and
# never touch the host.
map() { local p=$1; p=${p/#\/etc\/pam.d/$TEST_PAMD}; p=${p/#\/var\/backups\/faceauth/$TEST_BACKUPS}; p=${p/#\/var\/lib\/faceauth/$TEST_STORE}; printf '%s' "$p"; }

case "${1:-}" in
  tee)
    /usr/bin/cat >"$(map "$2")"
    ;;
  rm)
    shift; args=(); for a in "$@"; do [[ $a == -* ]] && args+=("$a") || args+=("$(map "$a")"); done
    /usr/bin/rm "${args[@]}"
    ;;
  sed)
    # Setup inserts at line 1 or after a fingerprint or FIDO2 line; removal
    # and a replaced hand-edited line delete by pattern. Nothing else.
    [[ $2 == -i && ( $3 =~ ^([0-9]+[ai]) || $3 == '/pam_faceauth\.so/d' ) ]] || { echo "unexpected sed: $*" >&2; exit 97; }
    /usr/bin/sed -i "$3" "$(map "$4")"
    ;;
  test)
    [[ $2 == -f || $2 == -d ]] || { echo "unexpected test: $*" >&2; exit 97; }
    [[ $2 == -f && -f $(map "$3") || $2 == -d && -d $(map "$3") ]]
    ;;
  find)
    # The store is root-only on a real machine, so the deletion runs under
    # sudo with the patterns spelled out as paths; every argument that names
    # the store is mapped, the rest (predicates, parentheses) pass through.
    (( ${TEST_FIND_FAIL:-0} == 0 )) || exit 1
    shift; args=(); for a in "$@"; do args+=("$(map "$a")"); done
    /usr/bin/find "${args[@]}"
    ;;
  cmp)
    [[ $2 == -s && $3 == - ]] || { echo "unexpected cmp: $*" >&2; exit 97; }
    /usr/bin/cmp -s - "$(map "$4")"
    ;;
  install)
    [[ $2 == -dm700 ]] || { echo "unexpected install: $*" >&2; exit 97; }
    /usr/bin/install -dm700 "$(map "$3")"
    ;;
  rmdir)
    /usr/bin/rmdir "$(map "$2")"
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
  doctor)
    # The rows setup reads, in the daemon's --json shape. TEST_DOCTOR picks
    # which of the two camera rows fails; the real doctor exits 1 on a fail
    # row and still prints every row, so the stub does the same.
    ir=pass; illuminator=pass; rc=0
    [[ ${TEST_DOCTOR:-pass} == ir-fail ]] && { ir=fail; rc=1; }
    [[ ${TEST_DOCTOR:-pass} == illuminator-warn ]] && illuminator=warn
    printf '[\n  {"id": "camera.ir", "status": "%s", "detail": "ov7251 3-0060 on /dev/video2 (640x480)"},\n  {"id": "camera.illuminator", "status": "%s", "detail": "no strobe control"},\n  {"id": "camera.rgb", "status": "pass", "detail": "ov8865 3-0010"}\n]\n' "$ir" "$illuminator"
    exit $rc
    ;;
  auth)
    if [[ $TEST_AUTH == match ]]; then echo '{"result":"match","frames":2,"elapsed_ms":1500}'
    else echo '{"result":"no_match","frames":2,"elapsed_ms":4000}'; fi
    ;;
  templates)
    # `templates delete`: the daemon's answer and the exit status the real
    # CLI gives it, 0 only on deleted or not_enrolled; any other answer
    # (busy, a caller refused as remote) goes to stderr with exit 1.
    case "${TEST_DELETE:-deleted}" in
      deleted) echo '{"result":"deleted"}' ;;
      busy) echo '{"result":"error","message":"busy"}' >&2; exit 1 ;;
    esac
    ;;
  *) : ;;
esac
SH

for cmd in omarchy-pkg-add omarchy-pkg-drop systemctl omarchy-bar omarchy-plugin-disable; do
  cat >"$stub_bin/$cmd" <<SH
#!/bin/bash

printf '$cmd' >>"\$TEST_LOG"
printf '\t%s' "\$@" >>"\$TEST_LOG"
printf '\n' >>"\$TEST_LOG"
# The daemon is running unless a case says otherwise.
if [[ \${1:-} == is-active ]]; then [[ \${TEST_ACTIVE:-yes} == yes ]]; exit \$?; fi
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

[[ $TEST_CAMERA == present ]] || exit 1
echo "/dev/v4l-subdev6  ov7251 3-0060 (Intel IPU3)"
SH

# gum answers from TEST_GUM, one choice per call separated by |, and logs
# each call so the test sees what was offered and preselected. "cancel"
# answers as Escape does.
cat >"$stub_bin/gum" <<'SH'
#!/bin/bash

printf 'gum' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
[[ ${TEST_GUM:-cancel} == cancel ]] && exit 130
n=$(cat "$TEST_LOG.gum" 2>/dev/null || echo 0)
echo $((n + 1)) >"$TEST_LOG.gum"
IFS='|' read -ra answers <<<"$TEST_GUM"
printf '%s\n' "${answers[$n]}"
SH

chmod +x "$stub_bin"/*
ln -s "$ROOT/bin/omarchy-cmd-missing" "$stub_bin/omarchy-cmd-missing"

# The scripts read /etc/pam.d directly (unprivileged reads) before asking sudo
# to write; a copy retargeted at the scratch tree keeps the host out of it.
# Both must name the lock-face service exactly as expected, so the copy cannot
# quietly stop standing for the command it copies.
occurrences=$(grep -c '/etc/pam.d/omarchy-lock-face' "$setup") || occurrences=0
(( occurrences == 1 )) || fail "setup names the lock-face PAM service exactly once" "found $occurrences occurrences"
occurrences=$(grep -c '/etc/pam.d/omarchy-lock-face' "$remove") || occurrences=0
(( occurrences == 2 )) || fail "removal names the lock-face PAM service exactly twice (the check and the rm)" "found $occurrences occurrences"
retarget() {
  sed -e "s|/etc/pam.d|$pamd|g" -e "s|/var/backups/faceauth|$backups|g" -e "s|/var/lib/faceauth|$store|g" "$1"
}
setup_copy="$test_tmp/setup.sh"; retarget "$setup" >"$setup_copy"
remove_copy="$test_tmp/remove.sh"; retarget "$remove" >"$remove_copy"
! grep -qE '/etc/pam\.d|/var/backups/faceauth|/var/lib/faceauth' "$setup_copy" "$remove_copy" || fail "the retargeted copies name no real path"
pass "the scripts name the PAM service as expected, and the test drives retargeted copies"

run_script() {
  local script=$1 camera=$2 enroll=$3 auth=$4
  shift 4
  [[ $script == "$setup" ]] && script=$setup_copy
  [[ $script == "$remove" ]] && script=$remove_copy
  : >"$calls"
  # keep_pam=1 leaves the sudo stack as the previous run left it.
  (( ${keep_pam:-0} )) || printf 'auth include system-auth\n' >"$pamd/sudo"
  TEST_LOG="$calls" TEST_PAMD="$pamd" TEST_BACKUPS="$backups" TEST_STORE="$store" TEST_CAMERA="$camera" TEST_ENROLL="$enroll" TEST_AUTH="$auth" \
    TEST_DOCTOR="${doctor:-pass}" PATH="$stub_bin:$PATH" bash "$script" "$@" </dev/null >"$out" 2>&1
}

# Setup on the good path with a terminal on stdin, as the menu's floating
# terminal gives it; $1 is what gum answers.
run_setup_tty() {
  : >"$calls"
  rm -f "$calls.gum"
  printf 'auth include system-auth\n' >"$pamd/sudo"
  TEST_LOG="$calls" TEST_PAMD="$pamd" TEST_BACKUPS="$backups" TEST_STORE="$store" TEST_CAMERA=present TEST_ENROLL=ok TEST_AUTH=match \
    TEST_DOCTOR=pass TEST_GUM="$1" PATH="$stub_bin:$PATH" script -qec "bash '$setup_copy'" /dev/null </dev/null >"$out" 2>&1
}

# No IR camera: nothing is installed and nothing is written.
rm -f "$pamd/omarchy-lock-face"
run_script "$setup" absent ok match && fail "setup without an IR camera fails"
! grep -q omarchy-pkg-add "$calls" || fail "setup installs nothing without an IR camera" "$(cat "$calls")"
[[ ! -e $pamd/omarchy-lock-face ]] || fail "setup writes no PAM service without an IR camera"
pass "setup refuses without an IR camera before installing anything"

# The kernel cannot drive the illuminator (the stock ov7251 driver has no
# strobe control): the daemon would refuse every attempt, so setup stops
# after the install and before enrolment, and says why.
rm -f "$pamd/omarchy-lock-face"
doctor=illuminator-warn run_script "$setup" present ok match && fail "setup without a strobe control fails"
grep -q $'faceauth\tdoctor\t--json' "$calls" || fail "setup asks doctor before enrolling" "$(cat "$calls")"
! grep -q $'systemctl\tenable' "$calls" || fail "setup enables no service when the illuminator cannot be driven" "$(cat "$calls")"
grep -q 'cannot drive the infrared illuminator' "$out" || fail "setup names the illuminator as the reason" "$(cat "$out")"
grep -q 'camera.illuminator: warn' "$out" || fail "setup prints the doctor row it stopped on" "$(cat "$out")"
[[ ! -e $pamd/omarchy-lock-face ]] || fail "setup writes no PAM service when the illuminator cannot be driven"
! grep -q pam_faceauth "$pamd/sudo" || fail "setup leaves the sudo stack alone when the illuminator cannot be driven"
pass "setup stops before enrolment when the kernel cannot drive the illuminator"

# The daemon cannot open the camera at all: same stop, its own message.
rm -f "$pamd/omarchy-lock-face"
doctor=ir-fail run_script "$setup" present ok match && fail "setup with an unopenable camera fails"
! grep -q $'systemctl\tenable' "$calls" || fail "setup enables no service when the daemon cannot open the camera" "$(cat "$calls")"
grep -q 'cannot open the infrared camera' "$out" || fail "setup names the camera as the reason" "$(cat "$out")"
[[ ! -e $pamd/omarchy-lock-face ]] || fail "setup writes no PAM service when the daemon cannot open the camera"
pass "setup stops before enrolment when the daemon cannot open the camera"

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

# The good path: install both packages, check the camera, enable, enrol,
# verify, then the PAM service, closed by pam_deny. The models come with
# their package, so nothing is fetched.
rm -f "$pamd/omarchy-lock-face"
run_script "$setup" present ok match || fail "setup succeeds with a camera, an enrolment and a match" "$(cat "$calls")"
grep -q $'omarchy-bar\tput\tomarchy.faceauth.presence\t--before\tomarchy.power' "$calls" || fail "setup puts the walk-away widget on the bar after the match" "$(cat "$calls")"
[[ -f $pamd/omarchy-lock-face ]] || fail "setup writes the lock-face PAM service"
grep -q 'pam_faceauth.so' "$pamd/omarchy-lock-face" || fail "the lock-face service names the face module"
grep -q 'pam_deny.so' "$pamd/omarchy-lock-face" || fail "the lock-face service is closed by pam_deny"
enrol_line=$(grep -n $'faceauth\tenroll' "$calls" | head -1 | cut -d: -f1)
tee_line=$(grep -n $'sudo\ttee' "$calls" | head -1 | cut -d: -f1)
(( enrol_line < tee_line )) || fail "the PAM service is written only after enrolment" "$(cat "$calls")"
grep -q $'omarchy-pkg-add\tomarchy-faceauth\tomarchy-faceauth-models' "$calls" || fail "setup installs the package and the models package in one call" "$(cat "$calls")"
! grep -q $'models\tfetch' "$calls" || fail "setup fetches no models; the models package ships them" "$(cat "$calls")"
doctor_line=$(grep -n $'faceauth\tdoctor' "$calls" | head -1 | cut -d: -f1)
enable_line=$(grep -n $'systemctl\tenable' "$calls" | head -1 | cut -d: -f1)
add_line=$(grep -n 'omarchy-pkg-add' "$calls" | head -1 | cut -d: -f1)
(( add_line < doctor_line && doctor_line < enable_line )) || fail "doctor runs after the install and before the service is enabled" "$(cat "$calls")"
grep -q 'pam_faceauth.so socket=/run/faceauth/sock consent' "$pamd/sudo" || fail "setup puts a consent line on the sudo stack" "$(cat "$pamd/sudo")"
grep -q '^auth      sufficient pam_faceauth.so' "$pamd/sudo" || fail "the sudo consent line is sufficient: a shake falls to the terminal prompt" "$(cat "$pamd/sudo")"
[[ $(head -1 "$pamd/sudo") == *pam_faceauth.so* ]] || fail "the consent line is the first line of the sudo stack"
(( $(grep -c . "$pamd/sudo") == 2 )) || fail "setup adds one line to the sudo stack and nothing else" "$(cat "$pamd/sudo")"
! grep -q 'pre-face' "$calls" || fail "setup keeps no backup of the stacks it changes" "$(cat "$calls")"
[[ -z $(ls -A "$backups" | grep -v polkit-1.created-by-faceauth) ]] || fail "the marker is the only file setup keeps outside /etc/pam.d" "$(ls -A "$backups")"
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

# Removal takes the PAM service out before the package. The sudo stack is
# left as the good path wrote it, so the strip has a line to take out.
keep_pam=1 run_script "$remove" present ok match || fail "removal succeeds" "$(cat "$calls")"
grep -q $'omarchy-plugin-disable\tomarchy.faceauth.presence' "$calls" || fail "removal takes the walk-away widget off the bar" "$(cat "$calls")"
[[ ! -e $pamd/omarchy-lock-face ]] || fail "removal deletes the lock-face PAM service"
rm_line=$(grep -n $'sudo\trm' "$calls" | head -1 | cut -d: -f1)
drop_line=$(grep -n 'omarchy-pkg-drop' "$calls" | head -1 | cut -d: -f1)
(( rm_line < drop_line )) || fail "the PAM service goes before the package" "$(cat "$calls")"
grep -q $'omarchy-pkg-drop\tomarchy-faceauth\tomarchy-faceauth-models' "$calls" || fail "removal drops the models package with the main one" "$(cat "$calls")"
grep -q $'faceauth\ttemplates\tdelete' "$calls" || fail "removal deletes the templates by default" "$(cat "$calls")"
! grep -q pam_faceauth "$pamd/sudo" || fail "removal takes the consent line off the sudo stack" "$(cat "$pamd/sudo")"
[[ $(cat "$pamd/sudo") == "auth include system-auth" ]] || fail "removal leaves the sudo stack as it was before setup" "$(cat "$pamd/sudo")"
grep -qF $'sudo\tsed\t-i\t/pam_faceauth\\.so/d' "$calls" || fail "removal strips the line in place, as fingerprint and FIDO2 do" "$(cat "$calls")"
! grep -q $'sudo\tcp\|pre-face' "$calls" || fail "removal restores nothing from a backup" "$(cat "$calls")"
[[ ! -e $pamd/polkit-1 ]] || fail "removal deletes the polkit-1 file that setup created"
[[ ! -e $backups/polkit-1.created-by-faceauth ]] || fail "removal deletes the marker with the file it stood for"
[[ ! -d $backups ]] || fail "removal takes the marker directory away with the marker" "$(ls -A "$backups")"
pass "removal takes the PAM service out first, deletes the templates, then drops the package"

: >"$calls"
run_script "$remove" present ok match --keep-templates || fail "removal with --keep-templates succeeds"
! grep -q $'templates\tdelete' "$calls" || fail "--keep-templates keeps the templates" "$(cat "$calls")"
pass "removal keeps the templates when asked"

run_script "$remove" present ok match --bogus && fail "removal rejects an unknown flag before deleting anything"
pass "removal rejects an unknown flag"

# A FIDO2 line added after face was set up must survive removal: only our
# line goes.
rm -rf "$backups"; mkdir -p "$backups"; rm -f "$pamd/polkit-1"
run_script "$setup" present ok match || fail "setup succeeds before the later change" "$(cat "$calls")"
/usr/bin/sed -i '2i auth sufficient pam_u2f.so cue' "$pamd/sudo"
keep_pam=1 run_script "$remove" present ok match || fail "removal succeeds after a later change" "$(cat "$calls")"
grep -q pam_u2f.so "$pamd/sudo" || fail "removal keeps a pam_u2f line added after setup" "$(cat "$pamd/sudo")"
! grep -q pam_faceauth "$pamd/sudo" || fail "removal still takes our line off a changed stack" "$(cat "$pamd/sudo")"
(( $(grep -c . "$pamd/sudo") == 2 )) || fail "removal leaves the changed stack otherwise as it was" "$(cat "$pamd/sudo")"
pass "removal strips only our line when the stack changed after setup"

# Fingerprint or FIDO2 set up first: the face line goes after their line, so
# a touch or a tap still answers first and the face window, which has no
# deadline, never sits above a reader the user meant to use. The clamshell
# gate fingerprint puts before its own line stays exactly there.
rm -rf "$backups"; mkdir -p "$backups"; rm -f "$pamd/polkit-1"
printf 'auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed\nauth      sufficient pam_fprintd.so\nauth include system-auth\n' >"$pamd/sudo"
keep_pam=1 run_script "$setup" present ok match || fail "setup succeeds on a stack with a fingerprint line" "$(cat "$calls")"
[[ $(sed -n 1p "$pamd/sudo") == *omarchy-hw-laptop-closed* && $(sed -n 2p "$pamd/sudo") == *pam_fprintd.so* ]] || fail "the fingerprint gate and line keep their places" "$(cat "$pamd/sudo")"
[[ $(sed -n 3p "$pamd/sudo") == "$(grep -m1 '^face_line=' "$setup" | sed "s/^face_line='//; s/'\$//")" ]] || fail "the face line goes right after the fingerprint line" "$(cat "$pamd/sudo")"
[[ $(sed -n 4p "$pamd/sudo") == "auth include system-auth" ]] && (( $(grep -c . "$pamd/sudo") == 4 )) || fail "nothing else moves" "$(cat "$pamd/sudo")"
printf 'auth sufficient pam_u2f.so cue\nauth include system-auth\n' >"$pamd/sudo"
keep_pam=1 run_script "$setup" present ok match || fail "setup succeeds on a stack with a FIDO2 line" "$(cat "$calls")"
[[ $(sed -n 1p "$pamd/sudo") == *pam_u2f.so* && $(sed -n 2p "$pamd/sudo") == *pam_faceauth.so* ]] || fail "the face line goes after a FIDO2 line" "$(cat "$pamd/sudo")"
pass "setup puts the face line after a fingerprint or FIDO2 line, never above it"

# A face line setup did not write, one without consent for instance, would
# approve sudo on a plain look with no window; setup replaces it with its own
# instead of reporting the stack as already configured.
printf 'auth sufficient pam_faceauth.so socket=/run/faceauth/sock\nauth include system-auth\n' >"$pamd/sudo"
keep_pam=1 run_script "$setup" present ok match || fail "setup succeeds on a stack with a hand-added face line" "$(cat "$calls")"
(( $(grep -c pam_faceauth.so "$pamd/sudo") == 1 )) || fail "one face line remains" "$(cat "$pamd/sudo")"
grep -q 'pam_faceauth.so socket=/run/faceauth/sock consent' "$pamd/sudo" || fail "the remaining line is the consent one" "$(cat "$pamd/sudo")"
grep -q 'Replacing a face line in sudo' "$out" || fail "setup says it replaced the line" "$(cat "$out")"
keep_pam=1 run_script "$setup" present ok match || fail "setup succeeds again on its own line" "$(cat "$calls")"
grep -q 'sudo is already configured' "$out" || fail "an exact match reads as already configured" "$(cat "$out")"
(( $(grep -c pam_faceauth.so "$pamd/sudo") == 1 )) || fail "a re-run adds no second line" "$(cat "$pamd/sudo")"
pass "setup replaces a face line it did not write and recognises only its own"

# A polkit-1 that setup created is deleted only while it is still exactly what
# setup wrote. omarchy-setup-security-fingerprint inserts pam_fprintd.so into
# the same file; deleting the file would take the fingerprint with it, so
# removal must strip only our line and keep the rest.
rm -rf "$backups"; mkdir -p "$backups"; rm -f "$pamd/polkit-1"
run_script "$setup" present ok match || fail "setup succeeds before a later fingerprint setup" "$(cat "$calls")"
[[ -f $backups/polkit-1.created-by-faceauth ]] || fail "setup remembers that it created polkit-1"
/usr/bin/cmp -s "$pamd/polkit-1" "$backups/polkit-1.created-by-faceauth" || fail "the marker is a copy of exactly what setup wrote" "$(cat "$backups/polkit-1.created-by-faceauth")"
/usr/bin/sed -i '1i auth      sufficient pam_fprintd.so' "$pamd/polkit-1"
keep_pam=1 run_script "$remove" present ok match || fail "removal succeeds after a fingerprint setup" "$(cat "$calls")"
[[ -f $pamd/polkit-1 ]] || fail "removal keeps a created polkit-1 that gained a fingerprint line"
grep -q pam_fprintd.so "$pamd/polkit-1" || fail "removal keeps the pam_fprintd line" "$(cat "$pamd/polkit-1")"
! grep -q pam_faceauth "$pamd/polkit-1" || fail "removal still takes our line out of the changed polkit-1" "$(cat "$pamd/polkit-1")"
grep -q '^auth       include      system-auth' "$pamd/polkit-1" || fail "the rest of the created stack stays" "$(cat "$pamd/polkit-1")"
[[ ! -e $backups/polkit-1.created-by-faceauth ]] || fail "removal drops its claim on a polkit-1 it no longer owns"
pass "removal keeps a created polkit-1 that gained a fingerprint line and strips only ours"

# A marker from an older setup is an empty file, so it never matches: the
# file is stripped, not deleted.
rm -rf "$backups"; mkdir -p "$backups"; rm -f "$pamd/polkit-1"
run_script "$setup" present ok match || fail "setup succeeds before an old-marker removal" "$(cat "$calls")"
: >"$backups/polkit-1.created-by-faceauth"
keep_pam=1 run_script "$remove" present ok match || fail "removal succeeds with an empty marker" "$(cat "$calls")"
[[ -f $pamd/polkit-1 ]] || fail "an empty marker does not license deleting polkit-1"
! grep -q pam_faceauth "$pamd/polkit-1" || fail "our line still goes with an empty marker" "$(cat "$pamd/polkit-1")"
pass "an empty marker from an older setup strips the face line instead of deleting the file"

# With the daemon stopped, the templates cannot go through it, so removal
# deletes the files itself: the template, sealed or plaintext (a machine
# without a TPM keeps <user>.json), and the blobs set aside as unreadable,
# this user's only. A neighbour whose name extends or hyphenates this one
# keeps everything.
seed_store() {
  rm -rf "$store"; mkdir -p "$store/gestures"
  : >"$store/$USER.cred"; : >"$store/$USER.json"; : >"$store/$USER.cred.unreadable-1700000000"
  : >"$store/other.cred"; : >"$store/$USER-x.json"; : >"$store/${USER}2.cred"; : >"$store/gestures/nod-other-1.txt"
}
seed_store
TEST_ACTIVE=no run_script "$remove" present ok match || fail "removal succeeds with the daemon stopped" "$(cat "$out")"
! grep -q $'faceauth\ttemplates\tdelete' "$calls" || fail "a stopped daemon is not asked to delete" "$(cat "$calls")"
[[ ! -e $store/$USER.cred ]] || fail "removal deletes the template directly when the daemon is stopped"
[[ ! -e $store/$USER.json ]] || fail "removal deletes the plaintext template of a machine without a TPM"
[[ ! -e $store/$USER.cred.unreadable-1700000000 ]] || fail "removal deletes the set-aside blob"
[[ -e $store/other.cred && -e $store/$USER-x.json && -e $store/${USER}2.cred && -e $store/gestures/nod-other-1.txt ]] || fail "removal leaves other users' templates and recordings alone"
grep -q 'Face authentication has been removed' "$out" || fail "the success line is printed when the templates went" "$(cat "$out")"
pass "with the daemon stopped, removal deletes this user's template files itself"

# The daemon is running but its delete does not happen (busy, or a caller
# it refused as remote): the CLI exits non-zero, so removal falls through
# to the direct deletion instead of reporting a deletion that did not run.
seed_store
TEST_DELETE=busy run_script "$remove" present ok match || fail "removal succeeds when the daemon's delete fails and the fallback runs" "$(cat "$out")"
grep -q $'faceauth\ttemplates\tdelete' "$calls" || fail "a running daemon is asked to delete first" "$(cat "$calls")"
grep -q $'sudo\tfind' "$calls" || fail "a failed daemon delete falls through to the direct deletion" "$(cat "$calls")"
[[ ! -e $store/$USER.cred && ! -e $store/$USER.json ]] || fail "the fallback deletes the templates the daemon did not"
grep -q 'Face authentication has been removed' "$out" || fail "the success line is printed once the fallback deleted them" "$(cat "$out")"
pass "a daemon that answers busy is not taken at its word: the direct deletion runs"

# The daemon's delete succeeding is taken at its word: no direct deletion.
seed_store
run_script "$remove" present ok match || fail "removal succeeds through the daemon" "$(cat "$out")"
! grep -q $'sudo\tfind' "$calls" || fail "a daemon delete that succeeded needs no fallback" "$(cat "$calls")"
pass "a daemon delete that succeeded is not repeated by hand"

# A deletion that fails is said out loud and the success line is withheld.
seed_store
TEST_ACTIVE=no TEST_FIND_FAIL=1 run_script "$remove" present ok match && fail "removal fails when the templates could not be deleted"
grep -q 'templates remain' "$out" || fail "removal warns that the templates remain" "$(cat "$out")"
! grep -q 'Face authentication has been removed\.' "$out" || fail "the success line is withheld when the templates remain" "$(cat "$out")"
[[ -e $store/$USER.cred ]] || fail "the failed deletion left the template (the stub deleted nothing)"
pass "removal withholds the success line when the templates could not be deleted"

# The daemon's delete failing falls back to the direct deletion too.
seed_store
: >"$calls"
TEST_ACTIVE=no run_script "$remove" present ok match --keep-templates || fail "removal with --keep-templates succeeds with the daemon stopped"
[[ -e $store/$USER.cred ]] || fail "--keep-templates keeps the template with the daemon stopped"
pass "--keep-templates keeps the template files with the daemon stopped"

# After enrolment and verification setup asks for both obscured face lock
# times, the shipped ones selected, and saves them with `presence
# obscured-lock`, which never switches the walk-away lock. Without a
# terminal, or with a question cancelled, it saves nothing and says the
# times stay as they are.
rm -rf "$backups"; mkdir -p "$backups"; rm -f "$pamd/polkit-1"
run_script "$setup" present ok match || fail "setup without a terminal succeeds" "$(cat "$out")"
! grep -q $'^gum\|obscured-lock' "$calls" || fail "setup without a terminal asks nothing and saves nothing" "$(cat "$calls")"
grep -q 'Obscured face lock time left as it was (as shipped: never in default mode, 2 minutes in secure mode)' "$out" || fail "setup without a terminal says the times stay as shipped" "$(cat "$out")"
rm -rf "$backups"; mkdir -p "$backups"; rm -f "$pamd/polkit-1"
run_setup_tty '10 minutes|5 minutes' || fail "setup with a terminal succeeds" "$(cat "$out")"
grep -qF $'gum\tchoose\t--header\tObscured face lock time, default mode\t--selected\tNever (locks only when the chair empties)\t' "$calls" || fail "the default-mode question preselects the shipped Never" "$(cat "$calls")"
grep -qF $'gum\tchoose\t--header\tObscured face lock time, secure mode\t--selected\t2 minutes\t' "$calls" || fail "the secure-mode question preselects the shipped 2 minutes" "$(cat "$calls")"
grep -q $'^sudo\tfaceauth\tpresence\tobscured-lock\t--default\t10\t--secure\t5$' "$calls" || fail "the answers are saved with presence obscured-lock" "$(cat "$calls")"
! grep -q $'presence\ton\|presence\toff' "$calls" || fail "saving the times never switches the walk-away lock" "$(cat "$calls")"
auth_line=$(grep -n $'^faceauth\tauth' "$calls" | head -1 | cut -d: -f1)
save_line=$(grep -n $'^sudo\tfaceauth\tpresence\tobscured-lock' "$calls" | head -1 | cut -d: -f1)
(( auth_line < save_line )) || fail "the times are asked for only after a verified enrolment" "$(cat "$calls")"
grep -q 'Obscured face lock time saved: 10 minutes in default mode, 5 minutes in secure mode' "$out" || fail "setup says what it saved" "$(cat "$out")"
rm -rf "$backups"; mkdir -p "$backups"; rm -f "$pamd/polkit-1"
run_setup_tty cancel || fail "setup succeeds when the question is cancelled" "$(cat "$out")"
grep -q $'^gum\tchoose' "$calls" || fail "the cancelled run was asked" "$(cat "$calls")"
! grep -q 'obscured-lock' "$calls" || fail "a cancelled question saves nothing" "$(cat "$calls")"
grep -q 'Obscured face lock time left as it was' "$out" || fail "a cancelled question says the times stay" "$(cat "$out")"
pass "setup asks for the obscured face lock times with a terminal, saves them without switching the lock, and keeps them otherwise"

# Tune Gestures and the Walk-Away rows in the menu run the setup command
# with a flag, so the menu file names no sudo: the command's own root guard
# and requires-sudo header cover them, as omarchy-sudo-passwordless does.
# The flags run the one faceauth call and nothing else of setup.
run_script "$setup" present ok match --gestures || fail "setup --gestures succeeds" "$(cat "$out")"
[[ $(cat "$calls") == $'sudo\tfaceauth\tcalibrate\t--user\t'"$USER"$'\t--guided\nfaceauth\tcalibrate\t--user\t'"$USER"$'\t--guided' ]] || fail "--gestures runs the guided calibration for the user and nothing else" "$(cat "$calls")"
run_script "$setup" present ok match --walk-away 30 || fail "setup --walk-away 30 succeeds" "$(cat "$out")"
grep -q $'^sudo\tfaceauth\tpresence\ton\t--user\t'"$USER"$'\t--away-seconds\t30$' "$calls" || fail "--walk-away 30 turns the watch on at 30 seconds" "$(cat "$calls")"
! grep -q 'omarchy-pkg-add\|tee' "$calls" || fail "--walk-away runs nothing else of setup" "$(cat "$calls")"
run_script "$setup" present ok match --walk-away off || fail "setup --walk-away off succeeds" "$(cat "$out")"
grep -q $'^sudo\tfaceauth\tpresence\toff\t--user\t'"$USER"'$' "$calls" || fail "--walk-away off turns the watch off" "$(cat "$calls")"
run_script "$setup" present ok match --walk-away 45 && fail "an away time the menu does not offer is refused"
[[ ! -s $calls ]] || fail "a refused flag runs nothing" "$(cat "$calls")"
run_script "$setup" present ok match --bogus && fail "an unknown flag is refused"
pass "the menu's gesture and walk-away rows run through the setup command"

# The obscured face lock flags save one mode's time each through `presence
# obscured-lock` and take only the menu's values. They never run `presence
# on` or `off`, so the walk-away lock stays as it was.
for v in never 240 120 60 30 10 5 2 1; do
  run_script "$setup" present ok match --obscured-face-lock "$v" || fail "setup --obscured-face-lock $v succeeds" "$(cat "$out")"
  [[ $(cat "$calls") == $'sudo\tfaceauth\tpresence\tobscured-lock\t--default\t'"$v"$'\nfaceauth\tpresence\tobscured-lock\t--default\t'"$v" ]] || fail "--obscured-face-lock $v saves the default-mode time and nothing else" "$(cat "$calls")"
done
for v in 10 5 2 1; do
  run_script "$setup" present ok match --secure-obscured-face-lock "$v" || fail "setup --secure-obscured-face-lock $v succeeds" "$(cat "$out")"
  [[ $(cat "$calls") == $'sudo\tfaceauth\tpresence\tobscured-lock\t--secure\t'"$v"$'\nfaceauth\tpresence\tobscured-lock\t--secure\t'"$v" ]] || fail "--secure-obscured-face-lock $v saves the secure-mode time and nothing else" "$(cat "$calls")"
done
for bad in "--obscured-face-lock 45" "--obscured-face-lock 0" "--obscured-face-lock none" "--obscured-face-lock" "--obscured-face-lock never 5" "--secure-obscured-face-lock 20" "--secure-obscured-face-lock never" "--secure-obscured-face-lock 0" "--secure-obscured-face-lock" "--hidden-hold none"; do
  read -ra bad_args <<<"$bad"
  run_script "$setup" present ok match "${bad_args[@]}" && fail "setup $bad is refused"
  [[ ! -s $calls ]] || fail "setup $bad runs nothing" "$(cat "$calls")"
done
pass "the obscured face lock flags take exactly the menu's choices and save one time each"

menu="$ROOT/default/omarchy/omarchy-menu.jsonc"
face_rows=$(grep -E '^\s*"(setup|remove)\.security\.face' "$menu")
[[ -n $face_rows ]] || fail "the menu carries the face rows"
! grep -q 'sudo' <<<"$face_rows" || fail "no face menu row runs sudo itself" "$face_rows"
! grep -q '"icon":""' <<<"$face_rows" || fail "every face menu row has an icon" "$face_rows"
while read -r label; do
  (( ${#label} <= 16 )) || fail "face menu labels fit the menu with a check mark: $label"
done < <(grep -o '"label":"[^"]*"' <<<"$face_rows" | sed 's/"label":"//; s/"$//')
grep -q '"setup.security.face.gestures".*omarchy-setup-security-face --gestures' <<<"$face_rows" || fail "Tune Gestures runs setup --gestures" "$face_rows"
for v in off 20 30 60; do
  grep -q "\"setup.security.face.lock.$v\".*omarchy-setup-security-face --walk-away $v" <<<"$face_rows" || fail "the Walk-Away $v row runs setup --walk-away $v" "$face_rows"
  grep -q "\"setup.security.face.lock.$v\".*\"checked\"" <<<"$face_rows" || fail "the Walk-Away $v row marks itself when it is the current choice" "$face_rows"
done
# The checked guards read the daemon's config, which presence on|off rewrites
# with enabled and a float away time; each guard runs as a bash condition.
conf="$test_tmp/config.toml"
guard_of() { grep "\"setup.security.face.lock.$1\"" "$menu" | sed 's/.*"checked":"\(.*\)","action".*/\1/' | sed 's/\\"/"/g; s/\\\\/\\/g' | sed "s|/etc/faceauth/config.toml|$conf|g"; }
printf '[presence]\nenabled = true\nuser = "%s"\naway_seconds = 30.0\n' "$USER" >"$conf"
bash -c "$(guard_of 30)" || fail "the 30 row is checked when the watch is on at 30 seconds" "$(guard_of 30)"
bash -c "$(guard_of 20)" && fail "the 20 row is not checked at 30 seconds"
bash -c "$(guard_of off)" && fail "the Off row is not checked while the watch is on"
printf '[presence]\nenabled = false\nuser = "%s"\naway_seconds = 30.0\n' "$USER" >"$conf"
bash -c "$(guard_of off)" || fail "the Off row is checked while the watch is off" "$(guard_of off)"
bash -c "$(guard_of 30)" && fail "no time row is checked while the watch is off"
rm -f "$conf"
bash -c "$(guard_of off)" || fail "with no config at all the Off row is checked" "$(guard_of off)"
pass "the Walk-Away rows show the current choice from the daemon's config"

# The obscured face lock time is one Obscured Face row under Walk-Away Lock,
# titled with the full name, opening one panel per mode. It always shows:
# saving a time never switches the walk-away lock on, so the times can be
# set while it is off. Each panel keeps one sentence of help as its search
# description. Every time row runs setup with its value and marks itself
# from the daemon's config.
obscured=$(grep '"setup.security.face.lock.obscured":' "$menu")
[[ $obscured == *'"label":"Obscured Face","title":"Obscured face lock time"'* ]] || fail "one Obscured Face row opens a panel titled with the full name" "$obscured"
(( $(grep -c '"setup.security.face.lock.[a-z-]*obscured[a-z-]*":' "$menu") == 1 )) || fail "Walk-Away Lock holds one obscured face row" "$(grep 'obscured' "$menu")"
[[ $(grep '"setup.security.face.lock.obscured.default":' "$menu") == *'"label":"Default mode","title":"Obscured, default mode"'* ]] || fail "the default-mode panel is named for its mode"
[[ $(grep '"setup.security.face.lock.obscured.secure":' "$menu") == *'"label":"Secure mode","title":"Obscured, secure mode"'* ]] || fail "the secure-mode panel is named for its mode"
(( $(grep -cE '"setup\.security\.face\.lock\.obscured\.[a-z]+":' "$menu") == 2 )) || fail "Obscured Face holds exactly the two mode panels" "$(grep 'obscured' "$menu")"
for g in obscured obscured.default obscured.secure; do
  group=$(grep "\"setup.security.face.lock.$g\":" "$menu")
  [[ -n $group && $group != *'"when"'* ]] || fail "the $g panel shows whether or not the walk-away lock is on" "$group"
  [[ $group == *'"description":"How long a partly covered or turned-away face keeps the session open '* ]] || fail "the $g panel says what the time is for" "$group"
done
[[ $obscured == *'in default mode and in secure mode.'* ]] || fail "the Obscured Face description names both modes" "$obscured"
[[ $(grep '"setup.security.face.lock.obscured.default.never":' "$menu") == *'"label":"Never","description":"Locks only when the chair empties."'* ]] || fail "the shipped default-mode row says what never means"
for v in never 240 120 60 30 10 5 2 1; do
  grep -q "\"setup.security.face.lock.obscured.default.$v\".*\"checked\".*omarchy-setup-security-face --obscured-face-lock $v'" <<<"$face_rows" || fail "the default-mode $v row runs setup --obscured-face-lock $v and marks itself" "$face_rows"
done
for v in 10 5 2 1; do
  grep -q "\"setup.security.face.lock.obscured.secure.$v\".*\"checked\".*omarchy-setup-security-face --secure-obscured-face-lock $v'" <<<"$face_rows" || fail "the secure-mode $v row runs setup --secure-obscured-face-lock $v and marks itself" "$face_rows"
done
(( $(grep -c '"setup.security.face.lock.obscured.default\.' <<<"$face_rows") == 9 && $(grep -c '"setup.security.face.lock.obscured.secure\.' <<<"$face_rows") == 4 )) || fail "the mode panels offer exactly the menu's choices" "$face_rows"
checked_rows() {
  local id rows=()
  for id in default.never default.240 default.120 default.60 default.30 default.10 default.5 default.2 default.1 secure.10 secure.5 secure.2 secure.1; do
    bash -c "$(guard_of "obscured.$id")" && rows+=("$id")
  done
  echo "${rows[*]}"
}
printf '[presence]\nenabled = false\nuser = "%s"\naway_seconds = 30.0\n' "$USER" >"$conf"
[[ $(checked_rows) == "default.never secure.2" ]] || fail "with no time set the shipped choices are checked" "$(checked_rows)"
printf '[presence]\nenabled = false\nuser = "%s"\naway_seconds = 30.0\nobscured_face_lock = "never"\nsecure_obscured_face_lock = 2\n' "$USER" >"$conf"
[[ $(checked_rows) == "default.never secure.2" ]] || fail "the written shipped values read the same" "$(checked_rows)"
printf '[presence]\nenabled = false\nuser = "%s"\naway_seconds = 30.0\nobscured_face_lock = 240\nsecure_obscured_face_lock = 10\n' "$USER" >"$conf"
[[ $(checked_rows) == "default.240 secure.10" ]] || fail "4 hours and 10 minutes are checked with the lock off, and no row whose number they start with" "$(checked_rows)"
printf '[presence]\nenabled = true\nuser = "%s"\naway_seconds = 30.0\nobscured_face_lock = 1\nsecure_obscured_face_lock = 1\n' "$USER" >"$conf"
[[ $(checked_rows) == "default.1 secure.1" ]] || fail "1 minute is checked in each mode and nothing longer" "$(checked_rows)"
rm -f "$conf"
[[ $(checked_rows) == "default.never secure.2" ]] || fail "with no config at all the shipped choices are checked" "$(checked_rows)"
pass "Obscured Face always shows, opens a panel per mode, runs through setup and shows the current time from the daemon's config"

# The IR camera lister reads sysfs, never a device node: it lists an ov7251
# sensor only beside an ipu3-cio2 capture node, because that graph is the
# one the daemon drives. A UVC module or an IPU6 sensor never appears, so the
# menu entry and setup never admit a camera that would fail after the
# download. The guard is the lister's exit status.
lister="$ROOT/bin/omarchy-hw-ir-camera"
lister_list="$ROOT/bin/omarchy-hw-ir-camera-list"
fake_sysfs="$test_tmp/v4l"
seed_sysfs() {
  rm -rf "$fake_sysfs"
  local entry
  for entry in "$@"; do
    mkdir -p "$fake_sysfs/${entry%%=*}"
    printf '%s\n' "${entry#*=}" >"$fake_sysfs/${entry%%=*}/name"
  done
}
seed_sysfs video0="ipu3-cio2 0" video1="ipu3-cio2 1" v4l-subdev2="ipu3-csi2 0" v4l-subdev6="ov7251 3-0060" v4l-subdev8="ov8865 3-0010"
listed=$(OMARCHY_V4L_SYSFS_PATH="$fake_sysfs" bash "$lister_list") || fail "the lister exits 0 with an ov7251 on an ipu3-cio2 graph"
[[ $listed == "/dev/v4l-subdev6  ov7251 3-0060 (Intel IPU3)" ]] || fail "the lister names the ov7251 sensor" "$listed"
OMARCHY_V4L_SYSFS_PATH="$fake_sysfs" PATH="$ROOT/bin:$PATH" bash "$lister" || fail "the guard is true with an ov7251 on an ipu3-cio2 graph"
pass "the lister finds an ov7251 sensor on an ipu3-cio2 graph from sysfs"

# Same graph, RGB sensor only: nothing.
seed_sysfs video0="ipu3-cio2 0" v4l-subdev2="ipu3-csi2 0" v4l-subdev8="ov8865 3-0010"
listed=$(OMARCHY_V4L_SYSFS_PATH="$fake_sysfs" bash "$lister_list") && fail "the lister exits 1 without an ov7251"
[[ -z $listed ]] || fail "the lister prints nothing without an ov7251" "$listed"
OMARCHY_V4L_SYSFS_PATH="$fake_sysfs" PATH="$ROOT/bin:$PATH" bash "$lister" && fail "the guard is false without an ov7251"
pass "the lister lists nothing on an IPU3 graph without an ov7251"

# An IR sensor on another graph (IPU6, or a UVC module with a greyscale
# node): the daemon cannot drive it, so it is not listed.
seed_sysfs video0="Intel IPU6 ISYS Capture 0" v4l-subdev0="Intel IPU6 CSI2 0" v4l-subdev1="ov7251 1-0060" video2="Integrated IR Camera: Integrated I"
listed=$(OMARCHY_V4L_SYSFS_PATH="$fake_sysfs" bash "$lister_list") && fail "the lister exits 1 without an ipu3-cio2 graph"
[[ -z $listed ]] || fail "the lister prints nothing without an ipu3-cio2 graph" "$listed"
pass "the lister lists nothing for an IR sensor the daemon cannot drive"

seed_sysfs
OMARCHY_V4L_SYSFS_PATH="$fake_sysfs/missing" bash "$lister_list" && fail "the lister exits 1 with no sysfs tree"
pass "the lister exits 1 with no sysfs tree at all"
