#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# omarchy-setup-security-face installs a package, enrolls a face through a
# root-only daemon, and writes a PAM service. This runs it against stubs and
# protects the order that keeps a broken setup harmless: nothing is installed
# without an IR camera, the 260 MB models package only after the daemon's own
# camera check has passed, and the PAM service is written only after
# enrollment has been verified with a live match. omarchy-remove-security-face
# must take the PAM service out before the package goes.

# A headless sandbox may not set USER; the scripts under test read it too.
export USER=${USER:-$(id -un)}

setup="$ROOT/bin/omarchy-setup-security-face"
remove="$ROOT/bin/omarchy-remove-security-face"

test_tmp=$(mktemp -d)
stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
pamd="$test_tmp/pam.d"
backups="$test_tmp/backups"
store="$test_tmp/store"
udev="$test_tmp/udev.rules.d"
out="$test_tmp/out.log"
mkdir -p "$stub_bin" "$pamd" "$backups" "$store" "$udev"
# Every run maps /etc/udev/rules.d into the scratch tree, whichever runner
# starts it.
export TEST_UDEV="$udev"

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

# The test runs copies of the scripts retargeted at the scratch tree (below).
# The stub maps every path under /etc/pam.d, /var/backups/faceauth or
# /var/lib/faceauth into it as well, so a path the retarget missed still never
# reaches the host.
map() { local p=$1; p=${p/#\/etc\/pam.d/$TEST_PAMD}; p=${p/#\/var\/backups\/faceauth/$TEST_BACKUPS}; p=${p/#\/var\/lib\/faceauth/$TEST_STORE}; p=${p/#\/etc\/udev\/rules.d/$TEST_UDEV}; printf '%s' "$p"; }

case "${1:-}" in
  tee)
    /usr/bin/cat >"$(map "$2")"
    ;;
  rm)
    # Setup and removal replace and remove whole files (install, then mv;
    # rm); no stack is edited in place.
    shift; args=(); for a in "$@"; do [[ $a == -* ]] && args+=("$a") || args+=("$(map "$a")"); done
    /usr/bin/rm "${args[@]}"
    ;;
  mktemp)
    # A stack's stage of its own, made beside it.
    [[ $# == 2 && ${2##*/} == .*.omarchy.XXXXXX ]] || { echo "unexpected mktemp: $*" >&2; exit 97; }
    /usr/bin/mktemp "$(map "$2")"
    ;;
  mv)
    [[ $2 == -Tf && $3 == -- ]] || { echo "unexpected mv: $*" >&2; exit 97; }
    /usr/bin/mv -Tf -- "$(map "$4")" "$(map "$5")"
    ;;
  echo)
    # FIDO2 setup's closing test of sudo.
    shift
    printf '%s\n' "$*"
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
    # The marker directory, or a stack's root-owned copy written from stdin
    # beside the stack it replaces. TEST_INSTALL_FAIL makes the copy fail.
    if [[ $2 == -dm700 ]]; then
      /usr/bin/install -dm700 "$(map "$3")"
    elif [[ "$2 $3 $4 $5 $6 $7 $8 $9" == "-m 644 -o root -g root -T /dev/stdin" ]] && (( $# == 10 )); then
      (( ${TEST_INSTALL_FAIL:-0} == 0 )) || exit 1
      [[ -z ${TEST_INSTALL_FAIL_FOR:-} || ${10##*/} != ".${TEST_INSTALL_FAIL_FOR}.omarchy."* ]] || exit 1
      [[ ${10##*/} == .*.omarchy.?????? ]] || { echo "unexpected install target: ${10}" >&2; exit 97; }
      [[ -z ${TEST_INSTALL_SLOW:-} ]] || sleep "$TEST_INSTALL_SLOW"
      /usr/bin/cat >"$(map "${10}")"
    else
      echo "unexpected install: $*" >&2
      exit 97
    fi
    ;;
  rmdir)
    /usr/bin/rmdir "$(map "$2")"
    ;;
  cp)
    /usr/bin/cp -p "$(map "$3")" "$(map "$4")"
    ;;
  touch)
    printf 'touch-umask\t%s\n' "$(umask)" >>"$TEST_LOG"
    /usr/bin/touch "$(map "$2")"
    ;;
  chown)
    # The PAM edit lock: root:wheel, which the stat stub then reports.
    [[ $2 == root:wheel && $3 == */pam-stack.lock ]] || { echo "unexpected chown: $*" >&2; exit 97; }
    : >"$3.chowned"
    ;;
  chmod)
    [[ $2 == 0640 && $3 == */pam-stack.lock ]] || { echo "unexpected chmod: $*" >&2; exit 97; }
    (( ${TEST_CHMOD_FAIL:-0} == 0 )) || exit 1
    /usr/bin/chmod 0640 "$3"
    ;;
  faceauth|systemctl)
    exec "$@"
    ;;
  udevadm)
    # Reloading the rules, replaying the video nodes' change events (setup)
    # or add events (removal), and waiting for them: logged above, nothing
    # else.
    [[ $2 == control && $3 == --reload || $2 == trigger && ( $3 == --action=change || $3 == --action=add ) && $4 == --subsystem-match=video4linux || $2 == settle && $3 == --timeout=10 ]] || { echo "unexpected udevadm: $*" >&2; exit 97; }
    ;;
  *)
    echo "unexpected sudo invocation: $*" >&2
    exit 97
    ;;
esac
SH

# The PAM edit lock is checked to be root:wheel 0640 on every use; a test
# cannot make a file root's, so the owner and group come from the chown the
# sudo stub recorded, and the mode is the file's own.
cat >"$stub_bin/stat" <<'SH'
#!/bin/bash

if [[ ${1:-} == -c && ${2:-} == '%u:%G:%a' && ${3:-} == -- && ${4:-} == */pam-stack.lock ]]; then
  if [[ -e $4.chowned ]]; then
    printf '0:wheel:%s\n' "$(/usr/bin/stat -c %a -- "$4")"
  else
    /usr/bin/stat -c '%u:%G:%a' -- "$4"
  fi
  exit
fi
exec /usr/bin/stat "$@"
SH

cat >"$stub_bin/faceauth" <<'SH'
#!/bin/bash

printf 'faceauth' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"

case "${1:-}" in
  enroll) [[ $TEST_ENROLL == ok ]] ;;
  calibrate) : ;;
  cam)
    # `cam ir-reset`: the node given back once its rule is gone.
    if [[ ${2:-} == ir-reset ]]; then
      echo "/dev/video1 given back: root, group 985, mode 0660, no ACL; an add event has udev write the seat user's access"
      exit 0
    fi
    # `cam ir-rule`: the rule that locks the IR capture node, or, with
    # TEST_IR_RULE=open, the reason it is left open and exit 3.
    [[ ${2:-} == ir-rule ]] || exit 2
    if [[ ${TEST_IR_RULE:-rule} == open ]]; then
      echo "the IR capture node is left open: /dev/video1 offers colour formats too (YUYV), so it may be a webcam's" >&2
      exit 3
    fi
    if [[ ${TEST_IR_RULE:-rule} == usb ]]; then
      # A USB camera's rule: the interface marked, then the camera locked.
      printf '%s\n' 'ACTION!="remove", SUBSYSTEM=="video4linux", KERNEL=="video*", ATTR{index}=="0", SUBSYSTEMS=="usb", KERNELS=="1-5:1.2", ENV{FACEAUTH_IR_NODE}="1"' \
        'ACTION!="remove", SUBSYSTEM=="video4linux", KERNEL=="video*", ENV{FACEAUTH_IR_NODE}=="1", SUBSYSTEMS=="usb", KERNELS=="1-5", ATTRS{idVendor}=="04f2", ATTRS{idProduct}=="b6dd", TAG-="uaccess", GROUP="root", MODE="0600"'
      exit 0
    fi
    printf '%s\n' 'ACTION!="remove", SUBSYSTEM=="video4linux", KERNEL=="video*", ATTR{name}=="ipu3-cio2 1", SUBSYSTEMS=="pci", KERNELS=="0000:00:14.3", TAG-="uaccess", GROUP="root", MODE="0600"'
    ;;
  doctor)
    # The rows setup reads, in the daemon's --json shape. TEST_DOCTOR picks
    # which of the two camera rows fails; the real doctor exits 1 on a fail
    # row and still prints every row, so the stub does the same.
    # TEST_DOCTOR=ir-capture-fail: the IR capture node still locked once
    # its rule is gone (removal reads this row).
    ir=pass; illuminator=pass; capture=info; capture_detail="left open"; rc=0
    [[ ${TEST_DOCTOR:-pass} == ir-fail ]] && { ir=fail; rc=1; }
    [[ ${TEST_DOCTOR:-pass} == illuminator-warn ]] && illuminator=warn
    [[ ${TEST_DOCTOR:-pass} == ir-capture-fail ]] && { capture=fail; capture_detail="/dev/video1 is still locked though no rule holds it"; rc=1; }
    printf '[\n  {"id": "camera.ir", "status": "%s", "detail": "ov7251 3-0060 on /dev/video2 (640x480)"},\n  {"id": "camera.illuminator", "status": "%s", "detail": "no strobe control"},\n  {"id": "camera.rgb", "status": "pass", "detail": "ov8865 3-0010"},\n  {"id": "camera.ir_capture", "status": "%s", "detail": "%s"}\n]\n' "$ir" "$illuminator" "$capture" "$capture_detail"
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

# The packages are missing, so setup installs them, unless a case says they
# are there. "daemon" has only the daemon package installed, as a setup that
# stopped at the camera check leaves the machine.
cat >"$stub_bin/omarchy-pkg-missing" <<'SH'
#!/bin/bash

for pkg in "$@"; do
  case ${TEST_PKG:-missing} in
    missing) exit 0 ;;
    daemon) [[ $pkg == omarchy-faceauth ]] || exit 0 ;;
  esac
done
exit 1
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

cat >"$stub_bin/fido2-token" <<'SH'
#!/bin/bash

echo '/dev/hidraw0: vendor=0x1050, product=0x0407 (Yubico YubiKey)'
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
  sed -e "s|/etc/pam.d|$pamd|g" -e "s|/var/backups/faceauth|$backups|g" -e "s|/var/lib/faceauth|$store|g" -e "s|/etc/udev/rules.d|$udev|g" "$1"
}
# The machine-wide PAM edit lock the shared helper takes is retargeted the
# same way: the scripts source a copy of the helper, from a scratch tree,
# whose lock is a scratch file.
helper="$ROOT/install/helpers/pam-stack.sh"
occurrences=$(grep -Fxc 'pam_stack_lock=/run/omarchy-pam-stack.lock' "$helper") || occurrences=0
(( occurrences == 1 )) || fail "the helper names its lock exactly once" "found $occurrences occurrences"
omarchy_tree="$test_tmp/omarchy"
mkdir -p "$omarchy_tree/install/helpers"
sed -e "s|^pam_stack_lock=/run/omarchy-pam-stack.lock$|pam_stack_lock=$test_tmp/pam-stack.lock|" "$helper" >"$omarchy_tree/install/helpers/pam-stack.sh"
setup_copy="$test_tmp/setup.sh"; retarget "$setup" >"$setup_copy"
remove_copy="$test_tmp/remove.sh"; retarget "$remove" >"$remove_copy"
! grep -qE '/etc/pam\.d|/var/backups/faceauth|/var/lib/faceauth|/etc/udev' "$setup_copy" "$remove_copy" || fail "the retargeted copies name no real path"
# FIDO2 setup writes the same two stacks. Its copy finds a key already
# registered in a scratch key file, so it goes straight to the PAM lines;
# only its key file paths and /etc/pam.d are retargeted, and the PAM line
# itself still names /etc/fido2/fido2.
fido2="$ROOT/bin/omarchy-setup-security-fido2"
fido2_dir="$test_tmp/fido2"
mkdir -p "$fido2_dir"
echo "$USER:credential-handle,public-key,es256,+presence" >"$fido2_dir/fido2"
fido2_copy="$test_tmp/fido2.sh"
retarget "$fido2" | sed -e "s|^authdir=/etc/fido2$|authdir=$fido2_dir|" -e "s|^authfile=/etc/fido2/fido2$|authfile=$fido2_dir/fido2|" >"$fido2_copy"
! grep -q '/etc/pam\.d' "$fido2_copy" && grep -q "^authfile=$fido2_dir/fido2$" "$fido2_copy" || fail "the FIDO2 copy is retargeted at the scratch tree"
pass "the scripts name the PAM service as expected, and the test drives retargeted copies"

run_script() {
  local script=$1 camera=$2 enroll=$3 auth=$4
  shift 4
  [[ $script == "$setup" ]] && script=$setup_copy
  [[ $script == "$remove" ]] && script=$remove_copy
  : >"$calls"
  # keep_pam=1 leaves the sudo stack as the previous run left it.
  (( ${keep_pam:-0} )) || printf 'auth include system-auth\n' >"$pamd/sudo"
  TEST_LOG="$calls" TEST_PAMD="$pamd" TEST_BACKUPS="$backups" TEST_STORE="$store" TEST_UDEV="$udev" TEST_IR_RULE="${ir_rule:-rule}" TEST_CAMERA="$camera" TEST_ENROLL="$enroll" TEST_AUTH="$auth" \
    TEST_DOCTOR="${doctor:-pass}" TEST_INSTALL_FAIL="${TEST_INSTALL_FAIL:-0}" TEST_INSTALL_FAIL_FOR="${TEST_INSTALL_FAIL_FOR:-}" OMARCHY_PATH="$omarchy_tree" XDG_RUNTIME_DIR="$test_tmp" PATH="$stub_bin:$PATH" bash "$script" "$@" </dev/null >"$out" 2>&1
}

# FIDO2 setup against the stacks as they stand.
run_fido2() {
  : >"$calls"
  TEST_LOG="$calls" TEST_PAMD="$pamd" TEST_BACKUPS="$backups" TEST_STORE="$store" \
    OMARCHY_PATH="$omarchy_tree" XDG_RUNTIME_DIR="$test_tmp" PATH="$stub_bin:$PATH" bash "$fido2_copy" </dev/null >"$out" 2>&1
}

# Setup on the good path with a terminal on stdin, as the menu's floating
# terminal gives it; $1 is what gum answers.
run_setup_tty() {
  : >"$calls"
  rm -f "$calls.gum"
  printf 'auth include system-auth\n' >"$pamd/sudo"
  TEST_LOG="$calls" TEST_PAMD="$pamd" TEST_BACKUPS="$backups" TEST_STORE="$store" TEST_CAMERA=present TEST_ENROLL=ok TEST_AUTH=match \
    TEST_DOCTOR=pass TEST_GUM="$1" OMARCHY_PATH="$omarchy_tree" XDG_RUNTIME_DIR="$test_tmp" PATH="$stub_bin:$PATH" script -qec "bash '$setup_copy'" /dev/null </dev/null >"$out" 2>&1
}

# No IR camera: nothing is installed and nothing is written.
rm -f "$pamd/omarchy-lock-face"
run_script "$setup" absent ok match && fail "setup without an IR camera fails"
! grep -q omarchy-pkg-add "$calls" || fail "setup installs nothing without an IR camera" "$(cat "$calls")"
[[ ! -e $pamd/omarchy-lock-face ]] || fail "setup writes no PAM service without an IR camera"
pass "setup refuses without an IR camera before installing anything"

# The kernel cannot drive the illuminator (the stock ov7251 driver has no
# strobe control): the daemon would refuse every attempt, so setup stops
# after the daemon package and before the models and enrollment, and says why.
rm -f "$pamd/omarchy-lock-face"
doctor=illuminator-warn run_script "$setup" present ok match && fail "setup without a strobe control fails"
grep -qx $'omarchy-pkg-add\tomarchy-faceauth' "$calls" || fail "setup installs the daemon package alone for the check" "$(cat "$calls")"
grep -q $'faceauth\tdoctor\t--json' "$calls" || fail "setup asks doctor before enrolling" "$(cat "$calls")"
! grep -q 'omarchy-faceauth-models' "$calls" || fail "setup installs no models when the illuminator cannot be driven" "$(cat "$calls")"
! grep -q $'models\tfetch' "$calls" || fail "setup fetches no models when the illuminator cannot be driven" "$(cat "$calls")"
! grep -q $'systemctl\tenable' "$calls" || fail "setup enables no service when the illuminator cannot be driven" "$(cat "$calls")"
grep -q 'cannot drive the infrared illuminator' "$out" || fail "setup names the illuminator as the reason" "$(cat "$out")"
grep -q 'camera.illuminator: warn' "$out" || fail "setup prints the doctor row it stopped on" "$(cat "$out")"
grep -q 'The face models were not downloaded' "$out" || fail "setup says the models were not downloaded" "$(cat "$out")"
[[ ! -e $pamd/omarchy-lock-face ]] || fail "setup writes no PAM service when the illuminator cannot be driven"
[[ $(cat "$pamd/sudo") == "auth include system-auth" ]] || fail "setup leaves the sudo stack alone when the illuminator cannot be driven" "$(cat "$pamd/sudo")"
pass "setup stops before the models download and enrollment when the kernel cannot drive the illuminator"

# The daemon cannot open the camera at all: same stop, its own message.
rm -f "$pamd/omarchy-lock-face"
doctor=ir-fail run_script "$setup" present ok match && fail "setup with an unopenable camera fails"
! grep -q 'omarchy-faceauth-models' "$calls" || fail "setup installs no models when the daemon cannot open the camera" "$(cat "$calls")"
! grep -q $'systemctl\tenable' "$calls" || fail "setup enables no service when the daemon cannot open the camera" "$(cat "$calls")"
grep -q 'cannot open the infrared camera' "$out" || fail "setup names the camera as the reason" "$(cat "$out")"
grep -q 'The face models were not downloaded' "$out" || fail "setup says the models were not downloaded" "$(cat "$out")"
[[ ! -e $pamd/omarchy-lock-face ]] || fail "setup writes no PAM service when the daemon cannot open the camera"
pass "setup stops before the models download and enrollment when the daemon cannot open the camera"

# A machine where an earlier setup stopped at the check keeps the daemon
# package; once the check passes, setup adds only the models.
rm -f "$pamd/omarchy-lock-face"
TEST_PKG=daemon run_script "$setup" present ok match || fail "setup succeeds with only the daemon package installed" "$(cat "$out")"
! grep -qx $'omarchy-pkg-add\tomarchy-faceauth' "$calls" || fail "setup does not install the daemon package again" "$(cat "$calls")"
grep -qx $'omarchy-pkg-add\tomarchy-faceauth-models' "$calls" || fail "setup installs the models once the check passes" "$(cat "$calls")"
rm -rf "$backups"; mkdir -p "$backups"; rm -f "$pamd/polkit-1"
pass "setup after a stopped run installs only the models"

# Enrollment fails: no PAM service.
rm -f "$pamd/omarchy-lock-face"
run_script "$setup" present fail match && fail "setup with a failed enrollment fails"
[[ ! -e $pamd/omarchy-lock-face ]] || fail "setup writes no PAM service when enrollment fails"
pass "setup writes no PAM service when enrollment fails"

# Enrollment succeeds but the verification scan does not match: no PAM service.
rm -f "$pamd/omarchy-lock-face"
run_script "$setup" present ok nomatch && fail "setup with a failed verification fails"
[[ ! -e $pamd/omarchy-lock-face ]] || fail "setup writes no PAM service when verification fails"
! grep -q pam_faceauth "$pamd/sudo" || fail "setup leaves the sudo stack alone when verification fails"
grep -q $'faceauth\tauth\t--user' "$calls" || fail "setup verifies the enrollment with a scan" "$(cat "$calls")"
pass "setup writes no PAM service when the verification scan does not match"

# The good path: install the daemon package, check the camera, install the
# models package, enable, enroll, verify, then the PAM services. The models
# come with their package, so nothing is fetched.
rm -f "$pamd/omarchy-lock-face"
run_script "$setup" present ok match || fail "setup succeeds with a camera, an enrollment and a match" "$(cat "$calls")"
grep -q $'omarchy-bar\tput\tomarchy.faceauth.presence\t--before\tomarchy.power' "$calls" || fail "setup puts the walk-away widget on the bar after the match" "$(cat "$calls")"
enrol_line=$(grep -n $'faceauth\tenroll' "$calls" | head -1 | cut -d: -f1)
write_line=$(grep -n $'sudo\tinstall\t-m\t644' "$calls" | head -1 | cut -d: -f1)
[[ -n $write_line ]] && (( enrol_line < write_line )) || fail "the PAM service is written only after enrollment" "$(cat "$calls")"
! grep -q $'sudo\ttee' "$calls" || fail "every PAM file is published whole from a root stage, none through tee" "$(cat "$calls")"
! grep -q $'models\tfetch' "$calls" || fail "setup fetches no models; the models package ships them" "$(cat "$calls")"
add_line=$(grep -nx $'omarchy-pkg-add\tomarchy-faceauth' "$calls" | head -1 | cut -d: -f1)
doctor_line=$(grep -n $'faceauth\tdoctor' "$calls" | head -1 | cut -d: -f1)
models_line=$(grep -nx $'omarchy-pkg-add\tomarchy-faceauth-models' "$calls" | head -1 | cut -d: -f1)
enable_line=$(grep -n $'systemctl\tenable' "$calls" | head -1 | cut -d: -f1)
[[ -n $add_line && -n $models_line ]] || fail "setup installs the daemon package and the models package in separate calls" "$(cat "$calls")"
(( add_line < doctor_line && doctor_line < models_line && models_line < enable_line )) || fail "doctor runs after the daemon install, the models install after doctor, and both before the service is enabled" "$(cat "$calls")"
# Each PAM file is pinned line for line, so a stack that also lets anyone in
# (a pam_permit line, a changed control) fails here rather than passing a grep.
lock_face_expected='#%PAM-1.0
auth       sufficient                  pam_faceauth.so socket=/run/faceauth/sock timeout=8
auth       required                    pam_deny.so
account    include                     system-local-login'
[[ $(cat "$pamd/omarchy-lock-face") == "$lock_face_expected" ]] || fail "the lock-face service is the face line closed by pam_deny, and nothing else" "$(cat "$pamd/omarchy-lock-face")"
# The sudo consent line is first and sufficient, so a shake falls to the
# terminal prompt; setup adds that one line and nothing else.
sudo_expected='auth      sufficient pam_faceauth.so socket=/run/faceauth/sock consent
auth include system-auth'
[[ $(cat "$pamd/sudo") == "$sudo_expected" ]] || fail "setup puts one consent line at the top of the sudo stack and nothing else" "$(cat "$pamd/sudo")"
! grep -q 'pre-face' "$calls" || fail "setup keeps no backup of the stacks it changes" "$(cat "$calls")"
[[ -z $(ls -A "$backups" | grep -v polkit-1.created-by-faceauth) ]] || fail "the marker is the only file setup keeps outside /etc/pam.d" "$(ls -A "$backups")"
[[ -f $pamd/polkit-1 && -f $backups/polkit-1.created-by-faceauth ]] || fail "setup creates polkit-1 when absent and remembers that it did"
# The created polkit-1 ends the stack on the user's no, so the agent can
# cancel, and otherwise carries the vendor stack.
polkit_expected='#%PAM-1.0
auth      [success=done auth_err=die default=ignore] pam_faceauth.so socket=/run/faceauth/sock consent
auth       include      system-auth
account    include      system-auth
password   include      system-auth
session    include      system-auth'
[[ $(cat "$pamd/polkit-1") == "$polkit_expected" ]] || fail "the created polkit-1 is the consent line over the vendor stack, and nothing else" "$(cat "$pamd/polkit-1")"
# The walk-through records the gestures after the looks, in the same run
# as the enrollment; setup no longer makes a separate calibration call.
grep -q $'faceauth\tenroll.*--guided' "$calls" || fail "setup enrolls through the walk-through, which records the person's gestures" "$(cat "$calls")"
grep -q $'faceauth\tcalibrate' "$calls" && fail "setup makes no separate calibration call" "$(cat "$calls")"
[[ ! -e $pamd/omarchy-lock-fido2 ]] || fail "without FIDO2 set up, face setup writes no key lane" "$(cat "$pamd/omarchy-lock-fido2")"
pass "setup installs, enrolls, verifies, and only then writes the lock-face PAM service"

# Mike's ruling (fix round 11): setup locks the IR capture node faceauth
# reads its frames from, with the rule faceauth itself prints, published
# whole from a root stage, then reloads udev and replays the video nodes.
ir_rule_expected='ACTION!="remove", SUBSYSTEM=="video4linux", KERNEL=="video*", ATTR{name}=="ipu3-cio2 1", SUBSYSTEMS=="pci", KERNELS=="0000:00:14.3", TAG-="uaccess", GROUP="root", MODE="0600"'
[[ -f $udev/72-faceauth-ir-node.rules ]] || fail "setup writes the IR capture node's rule" "$(cat "$calls")"
(( $(grep -cxF "$ir_rule_expected" "$udev/72-faceauth-ir-node.rules") == 1 )) || fail "the rule file holds faceauth's rule once" "$(cat "$udev/72-faceauth-ir-node.rules")"
(( $(grep -cv '^#' "$udev/72-faceauth-ir-node.rules") == 1 )) || fail "and nothing else but comments" "$(cat "$udev/72-faceauth-ir-node.rules")"
rule_line=$(grep -n $'faceauth\tcam\tir-rule' "$calls" | head -1 | cut -d: -f1)
publish_line=$(grep -nF $'sudo\tmv\t-Tf\t--\t'"$udev"'/.72-faceauth-ir-node.rules.omarchy.' "$calls" | head -1 | cut -d: -f1)
reload_line=$(grep -n $'sudo\tudevadm\tcontrol\t--reload' "$calls" | head -1 | cut -d: -f1)
trigger_line=$(grep -n $'sudo\tudevadm\ttrigger\t--action=change\t--subsystem-match=video4linux' "$calls" | head -1 | cut -d: -f1)
[[ -n $rule_line && -n $publish_line && -n $reload_line && -n $trigger_line ]] && (( rule_line < publish_line && publish_line < reload_line && reload_line < trigger_line )) || fail "the rule is asked of faceauth, published, then udev reloads and replays" "$(cat "$calls")"
pass "setup locks the IR capture node with faceauth's own rule"

# Left open: faceauth says why, setup says so and goes on.
rm -f "$pamd/omarchy-lock-face" "$udev/72-faceauth-ir-node.rules"
ir_rule=open run_script "$setup" present ok match || fail "setup succeeds when the IR capture node is left open" "$(cat "$out")"
[[ ! -e $udev/72-faceauth-ir-node.rules ]] || fail "no rule is written for a node faceauth leaves open"
! grep -q $'sudo\tudevadm' "$calls" || fail "udev is not touched when nothing is written" "$(cat "$calls")"
grep -q 'offers colour formats too' "$out" && grep -q 'stays open to your account' "$out" || fail "setup passes faceauth's reason on" "$(cat "$out")"
rm -rf "$backups"; mkdir -p "$backups"; rm -f "$pamd/polkit-1"
run_script "$setup" present ok match || fail "setup succeeds again for the removal below" "$(cat "$out")"
pass "setup leaves the IR capture node open, and says why, when faceauth does"

# A USB camera's rule is two lines; setup writes both, in order.
rm -f "$pamd/omarchy-lock-face" "$udev/72-faceauth-ir-node.rules"
rm -rf "$backups"; mkdir -p "$backups"; rm -f "$pamd/polkit-1"
ir_rule=usb run_script "$setup" present ok match || fail "setup succeeds with a USB camera's rule" "$(cat "$out")"
(( $(grep -cv '^#' "$udev/72-faceauth-ir-node.rules") == 2 )) || fail "both lines of the rule are written" "$(cat "$udev/72-faceauth-ir-node.rules")"
grep -v '^#' "$udev/72-faceauth-ir-node.rules" | head -1 | grep -q 'ENV{FACEAUTH_IR_NODE}="1"' || fail "the marking line comes first" "$(cat "$udev/72-faceauth-ir-node.rules")"
rm -rf "$backups"; mkdir -p "$backups"; rm -f "$pamd/polkit-1"
run_script "$setup" present ok match || fail "setup succeeds again for the removal below" "$(cat "$out")"
pass "setup writes a USB camera's two-line rule whole"

# Setup writes FaceAuth's own lines, byte for byte: the sudo and polkit-1
# lines and the omarchy-lock-face block of packaging/pam-example.txt in the
# omarchy-faceauth source. That file ships in neither this repo nor the
# package, so its lines are pinned here from it; a change on either side has
# to be made on both.
pam_example_sudo='auth      sufficient pam_faceauth.so socket=/run/faceauth/sock consent'
pam_example_polkit='auth      [success=done auth_err=die default=ignore] pam_faceauth.so socket=/run/faceauth/sock consent'
pam_example_lock_face='auth       sufficient                  pam_faceauth.so socket=/run/faceauth/sock timeout=8
auth       required                    pam_deny.so
account    include                     system-local-login'
(( $(grep -cxF "$pam_example_sudo" "$pamd/sudo") == 1 )) || fail "setup's sudo line is the example's" "$(cat "$pamd/sudo")"
(( $(grep -cxF "$pam_example_polkit" "$pamd/polkit-1") == 1 )) || fail "setup's polkit-1 line is the example's" "$(cat "$pamd/polkit-1")"
[[ $(sed 1d "$pamd/omarchy-lock-face") == "$pam_example_lock_face" ]] || fail "setup's lock-face service is the example's block" "$(cat "$pamd/omarchy-lock-face")"
pass "setup writes the sudo, polkit-1 and lock-face lines of FaceAuth's pam-example"

# Never under sudo: the enrollment would be root's. EUID is read-only in
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
grep -qF $'sudo\tmv\t-Tf\t--\t' "$calls" && ! grep -qF $'sudo\tsed' "$calls" || fail "removal replaces the stack whole under the PAM edit lock, never in place" "$(cat "$calls")"
! grep -q $'sudo\tcp\|pre-face' "$calls" || fail "removal restores nothing from a backup" "$(cat "$calls")"
[[ ! -e $pamd/polkit-1 ]] || fail "removal deletes the polkit-1 file that setup created"
[[ ! -e $backups/polkit-1.created-by-faceauth ]] || fail "removal deletes the marker with the file it stood for"
[[ ! -d $backups ]] || fail "removal takes the marker directory away with the marker" "$(ls -A "$backups")"
[[ ! -e $udev/72-faceauth-ir-node.rules ]] || fail "removal deletes the IR capture node's rule" "$(cat "$udev/72-faceauth-ir-node.rules")"
# Fix round 13 (Codex 6, Opus nit): the node is given back, then replayed
# with add events, since 50-udev-default.rules sets a video node's group on
# add alone, and doctor reads it after.
line_of() { grep -n "$1" "$calls" | head -1 | cut -d: -f1 || true; }
reload_line=$(line_of $'sudo\tudevadm\tcontrol\t--reload')
reset_line=$(line_of $'sudo\tfaceauth\tcam\tir-reset')
add_line=$(line_of $'sudo\tudevadm\ttrigger\t--action=add\t--subsystem-match=video4linux')
settle_line=$(line_of $'sudo\tudevadm\tsettle\t--timeout=10')
doctor_line=$(grep -n $'faceauth\tdoctor\t--json' "$calls" | tail -1 | cut -d: -f1 || true)
[[ -n $reload_line && -n $reset_line && -n $add_line && -n $settle_line && -n $doctor_line ]] &&
  (( reload_line < reset_line && reset_line < add_line && add_line < settle_line && settle_line < doctor_line )) ||
  fail "removal reloads udev, gives the node back, replays the video nodes' add events and has doctor read the node, in that order" "$(cat "$calls")"
! grep -q $'udevadm\ttrigger\t--action=change' "$calls" || fail "removal replays add events, not change" "$(cat "$calls")"
! grep -q "still locked" "$out" || fail "nothing said of a lock when doctor finds none" "$(cat "$out")"
pass "removal takes the PAM service out first, deletes the templates and the IR node's lock, then drops the package"

# Doctor still finding the lock: said in red, and the removal goes on.
printf '%s\n' "$ir_rule_expected" >"$udev/72-faceauth-ir-node.rules"
doctor=ir-capture-fail keep_pam=1 run_script "$remove" present ok match || fail "removal goes on when the node is still locked" "$(cat "$out")"
grep -q "still locked though no rule holds it" "$out" || fail "removal says when the IR capture node is still locked" "$(cat "$out")"
pass "removal says when doctor still finds the IR capture node locked"

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

# Fingerprint set up first: the face line goes after its line, so a touch on
# the reader still answers first and the face window, which has no deadline
# and cannot ask the reader yet, never sits above it. The clamshell gate
# fingerprint puts before its own line stays exactly there.
rm -rf "$backups"; mkdir -p "$backups"; rm -f "$pamd/polkit-1"
printf 'auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed\nauth      sufficient pam_fprintd.so\nauth include system-auth\n' >"$pamd/sudo"
keep_pam=1 run_script "$setup" present ok match || fail "setup succeeds on a stack with a fingerprint line" "$(cat "$calls")"
[[ $(sed -n 1p "$pamd/sudo") == *omarchy-hw-laptop-closed* && $(sed -n 2p "$pamd/sudo") == *pam_fprintd.so* ]] || fail "the fingerprint gate and line keep their places" "$(cat "$pamd/sudo")"
[[ $(sed -n 3p "$pamd/sudo") == "${sudo_expected%%$'\n'*}" ]] || fail "the face line goes right after the fingerprint line" "$(cat "$pamd/sudo")"
[[ $(sed -n 4p "$pamd/sudo") == "auth include system-auth" ]] && (( $(grep -c . "$pamd/sudo") == 4 )) || fail "nothing else moves" "$(cat "$pamd/sudo")"
# A fingerprint line as the stack's last line: the face line still lands,
# after it, where an insert addressed past the end would have dropped it.
printf 'auth include system-auth\nauth      sufficient pam_fprintd.so\n' >"$pamd/sudo"
keep_pam=1 run_script "$setup" present ok match || fail "setup succeeds on a stack ending in a fingerprint line" "$(cat "$out")"
[[ $(sed -n 3p "$pamd/sudo") == "${sudo_expected%%$'\n'*}" ]] && (( $(grep -c . "$pamd/sudo") == 3 )) || fail "the face line lands after a fingerprint line that ends the stack" "$(cat "$pamd/sudo")"
pass "setup puts the face line after a fingerprint line, never above it, even one that ends the stack"

# FIDO2 set up first: face setup takes the key over. Our pam_u2f line comes
# out, and the face daemon's key-fallback line goes right below the face
# line in its place, with the options it had, so every use of the key goes
# through the daemon; no pam_u2f line stays. A FIDO2 line setup did not
# write stays where it is, and face goes after it.
u2f_sudo='auth    sufficient pam_u2f.so cue authfile=/etc/fido2/fido2'
u2f_polkit='auth      sufficient pam_u2f.so cue authfile=/etc/fido2/fido2'
face_sudo=${sudo_expected%%$'\n'*}
fb='auth      sufficient pam_faceauth.so socket=/run/faceauth/sock key-fallback cue'
# The jump form an earlier setup wrote; read as ours and written back plain.
face_jump='auth      [success=done authinfo_unavail=1 default=ignore] pam_faceauth.so socket=/run/faceauth/sock consent'
new_order="$face_sudo
$fb
auth include system-auth"
no_u2f() {
  ! grep -qE '^[^#]*pam_u2f\.so' "$@" || fail "no pam_u2f line once face is set up" "$(grep -H pam_u2f "$@")"
}
printf '%s\nauth include system-auth\n' "$u2f_sudo" >"$pamd/sudo"
keep_pam=1 run_script "$setup" present ok match || fail "setup succeeds on a stack with our FIDO2 line" "$(cat "$calls")"
[[ $(cat "$pamd/sudo") == "$new_order" ]] || fail "our FIDO2 line becomes the daemon's key-fallback line right below the face line" "$(cat "$pamd/sudo")"
no_u2f "$pamd/sudo"
printf '%s\nauth include system-auth\n' "$u2f_sudo userverification=1" >"$pamd/sudo"
keep_pam=1 run_script "$setup" present ok match || fail "setup succeeds on our FIDO2 line with user verification" "$(cat "$calls")"
[[ $(sed -n 2p "$pamd/sudo") == "$fb userverification=1" ]] || fail "the key-fallback line mirrors the options our line had" "$(cat "$pamd/sudo")"
no_u2f "$pamd/sudo"
printf 'auth sufficient pam_u2f.so cue pinverification=1\nauth include system-auth\n' >"$pamd/sudo"
rc=0; keep_pam=1 run_script "$setup" present ok match || rc=$?
(( rc == 2 )) && [[ $(sed -n 1p "$pamd/sudo") == 'auth sufficient pam_u2f.so cue pinverification=1' ]] && ! grep -q pam_faceauth "$pamd/sudo" || fail "a FIDO2 line setup did not write (no key file) stops face setup, and the stack is left as it was" "rc=$rc $(cat "$pamd/sudo")"
printf 'auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed\nauth      sufficient pam_fprintd.so\n%s\nauth include system-auth\n' "$u2f_sudo" >"$pamd/sudo"
keep_pam=1 run_script "$setup" present ok match || fail "setup succeeds on a stack with fingerprint and FIDO2 lines" "$(cat "$calls")"
[[ $(sed -n 2p "$pamd/sudo") == *pam_fprintd.so* && $(sed -n 3p "$pamd/sudo") == "$face_sudo" && $(sed -n 4p "$pamd/sudo") == "$fb" ]] || fail "the face line goes after the fingerprint line, the key line right below it" "$(cat "$pamd/sudo")"
no_u2f "$pamd/sudo"
[[ -z $(ls -A "$pamd" | grep '\.omarchy\.') ]] || fail "no stage is left beside the stack"
pass "face setup turns our FIDO2 line into the daemon's key-fallback line below a fingerprint line, and stops on a FIDO2 line it did not write"

# Comments do not count: a `# pam_faceauth.so` or `# pam_u2f.so` comment is
# neither placed nor removed, and the lines land as they would without it.
printf '# pam_faceauth.so runs first here\n%s\n# auth sufficient pam_u2f.so pinverification=1\nauth include system-auth\n' "$u2f_sudo" >"$pamd/sudo"
keep_pam=1 run_script "$setup" present ok match || fail "setup succeeds on a stack with commented module names" "$(cat "$out")"
commented_expected="$face_sudo
$fb
# pam_faceauth.so runs first here
# auth sufficient pam_u2f.so pinverification=1
auth include system-auth"
[[ $(cat "$pamd/sudo") == "$commented_expected" ]] || fail "comments that name the modules are kept, and the key line lands below the face line" "$(cat "$pamd/sudo")"
printf '# pam_faceauth.so\n%s\nauth include system-auth\n' "$face_sudo" >"$pamd/sudo"
run_fido2 || fail "FIDO2 setup succeeds on a stack with a commented face line" "$(cat "$out")"
[[ $(sed -n 1p "$pamd/sudo") == '# pam_faceauth.so' && $(sed -n 2p "$pamd/sudo") == "$face_sudo" && $(sed -n 3p "$pamd/sudo") == "$fb" ]] || fail "FIDO2 setup places the key line below the active face line, not the comment" "$(cat "$pamd/sudo")"
grep -q 'Configuring sudo to take the key through face authentication' "$out" || fail "FIDO2 setup says the key goes through face" "$(cat "$out")"
no_u2f "$pamd/sudo"
pass "commented module names are neither placed nor removed"

# A stack from before the window could ask the key has our FIDO2 line above
# our own face line, and one from the last round the jump form. A rerun of
# either setup puts face first with the key line below it; a FIDO2 line
# setup did not write stays.
old_order="$u2f_sudo
$face_jump
#%PAM-1.0
auth include system-auth"
printf '%s\n' "$old_order" >"$pamd/sudo"
keep_pam=1 run_script "$setup" present ok match || fail "setup succeeds on the old order" "$(cat "$calls")"
[[ $(cat "$pamd/sudo") == "$face_sudo"$'\n'"$fb"$'\n#%PAM-1.0\nauth include system-auth' ]] || fail "a face setup rerun puts the face line first, plain, with the key line below it" "$(cat "$pamd/sudo")"
grep -q 'Moving the face line in sudo into place' "$out" || fail "setup says it moved the line" "$(cat "$out")"
printf '%s\n' "$old_order" >"$pamd/sudo"
run_fido2 || fail "FIDO2 setup succeeds on the old order" "$(cat "$out")"
[[ $(cat "$pamd/sudo") == "$face_sudo"$'\n'"$fb"$'\n#%PAM-1.0\nauth include system-auth' ]] || fail "a FIDO2 setup rerun turns the FIDO2 line into the key line below the face line" "$(cat "$pamd/sudo")"
printf 'auth sufficient pam_u2f.so pinverification=1\n%s\nauth include system-auth\n' "$face_sudo" >"$pamd/sudo"
rc=0; run_fido2 || rc=$?
(( rc == 2 )) && [[ $(cat "$pamd/sudo") == 'auth sufficient pam_u2f.so pinverification=1'$'\n'"$face_sudo"$'\nauth include system-auth' ]] || fail "with face set up, FIDO2 setup stops on a FIDO2 line it did not write and changes nothing" "rc=$rc $(cat "$pamd/sudo")"
grep -q 'sudo has a FIDO2 line face authentication cannot take over' "$out" || fail "FIDO2 setup says why" "$(cat "$out")"
pass "a rerun of either setup puts the face line first and the key line below it on the old orders"

# Every order of fingerprint, face and FIDO2 setup ends in the same stacks:
# fingerprint, face, the face daemon's key line, then the password, with no
# pam_u2f line in either. The sudo face line is `sufficient`, so a refusal
# goes on to the key line and then the password; polkit's keeps
# auth_err=die, so a refusal there ends the request. Reruns change nothing.
fp_stack='auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_fprintd.so'
# Whichever setup runs last, the lock screen ends with the face daemon's key
# lane: FIDO2 setup writes it when face is set up, and face setup when
# FIDO2 is.
key_lane_expected='#%PAM-1.0
auth       sufficient                  pam_faceauth.so socket=/run/faceauth/sock key-unlock
auth       required                    pam_deny.so
account    include                     system-local-login'
order_case() {
  local name=$1 step
  shift
  rm -rf "$backups"; mkdir -p "$backups"
  rm -f "$pamd/omarchy-lock-face" "$pamd/omarchy-lock-fido2"
  printf '%s\nauth include system-auth\n' "$fp_stack" >"$pamd/sudo"
  printf '#%%PAM-1.0\n%s\nauth       include      system-auth\naccount    include      system-auth\n' "$fp_stack" >"$pamd/polkit-1"
  for step in "$@"; do
    case $step in
      face) keep_pam=1 run_script "$setup" present ok match || fail "$name: face setup succeeds" "$(cat "$out")" ;;
      fido2) run_fido2 || fail "$name: FIDO2 setup succeeds" "$(cat "$out")" ;;
    esac
  done
  [[ $(cat "$pamd/sudo") == "$fp_stack"$'\n'"$face_sudo"$'\n'"$fb"$'\nauth include system-auth' ]] || fail "$name: sudo ends fingerprint, face, the key line, password" "$(cat "$pamd/sudo")"
  [[ $(grep -E '^[^#]*pam_(fprintd|faceauth|u2f)\.so' "$pamd/polkit-1") == "${fp_stack#*$'\n'}"$'\n'"$pam_example_polkit"$'\n'"$fb" ]] || fail "$name: polkit-1 ends fingerprint, face, the key line" "$(cat "$pamd/polkit-1")"
  no_u2f "$pamd/sudo" "$pamd/polkit-1"
  (( $(grep -cxF "$pam_example_polkit" "$pamd/polkit-1") == 1 )) || fail "$name: the polkit face line keeps auth_err=die" "$(cat "$pamd/polkit-1")"
  [[ $(cat "$pamd/omarchy-lock-fido2" 2>&1) == "$key_lane_expected" ]] || fail "$name: the lock screen takes the key through the daemon's key-unlock lane" "$(cat "$pamd/omarchy-lock-fido2" 2>&1)"
  ! grep -q pam_u2f "$pamd"/omarchy-lock-* || fail "$name: no lock screen service asks the key through pam_u2f" "$(grep pam_u2f "$pamd"/omarchy-lock-*)"
}
order_case "fingerprint, face, FIDO2" face fido2
before_sudo=$(cat "$pamd/sudo"); before_polkit=$(cat "$pamd/polkit-1")
keep_pam=1 run_script "$setup" present ok match || fail "a face rerun succeeds" "$(cat "$out")"
grep -q 'sudo is already configured' "$out" || fail "a face rerun finds sudo in place" "$(cat "$out")"
run_fido2 || fail "a FIDO2 rerun succeeds" "$(cat "$out")"
[[ $(cat "$pamd/sudo") == "$before_sudo" && $(cat "$pamd/polkit-1") == "$before_polkit" ]] || fail "reruns change neither stack" "$(cat "$pamd/sudo" "$pamd/polkit-1")"
# A pam_u2f line added by hand anywhere in sudo or polkit-1 reads the key
# outside the daemon: the next setup stops with status 2 and says which line
# and how to fix it, changing nothing (the daemon meanwhile offers the key
# nowhere, which doctor reports).
before_polkit=$(cat "$pamd/polkit-1")
printf 'auth      sufficient pam_u2f.so cue authfile=/home/someone/keys\n' >>"$pamd/polkit-1"
rc=0; run_fido2 || rc=$?
(( rc == 2 )) || fail "FIDO2 setup stops beside a hand-added pam_u2f line" "rc=$rc $(cat "$out")"
grep -q 'polkit-1 has a FIDO2 line face authentication cannot take over' "$out" && grep -qF 'authfile=/home/someone/keys' "$out" || fail "setup names the file and the line" "$(cat "$out")"
grep -q 'cue authfile=/home/someone/keys' "$pamd/polkit-1" || fail "the hand-added line itself is left alone"
printf '%s\n' "$before_polkit" >"$pamd/polkit-1"
order_case "fingerprint, FIDO2, face" fido2 face
# Face removal turns the key line back into our pam_u2f line, so the key
# keeps working for sudo without face, takes the face lines and the lock
# screen's key lane, under the lock, and leaves fingerprint where it was.
keep_pam=1 run_script "$remove" present ok match || fail "removal succeeds with the key lane set up" "$(cat "$out")"
[[ ! -e $pamd/omarchy-lock-fido2 ]] || fail "face removal deletes the key lane" "$(cat "$pamd/omarchy-lock-fido2")"
grep -Fxq $'sudo\trm\t-f\t--\t'"$pamd/omarchy-lock-fido2" "$calls" || fail "the key lane is removed under the PAM edit lock" "$(cat "$calls")"
[[ $(cat "$pamd/sudo") == "$fp_stack"$'\n'"$u2f_sudo"$'\nauth include system-auth' ]] || fail "face removal restores our pam_u2f line where the key line was" "$(cat "$pamd/sudo")"
[[ $(grep -E '^[^#]*pam_(fprintd|faceauth|u2f)\.so' "$pamd/polkit-1") == "${fp_stack#*$'\n'}"$'\n'"$u2f_polkit" ]] || fail "and in polkit-1" "$(cat "$pamd/polkit-1")"
grep -q 'the security key goes back to its own FIDO2 line' "$out" || fail "removal says the key keeps working" "$(cat "$out")"
# The options the key line mirrored come back with it.
printf '%s\n%s\nauth include system-auth\n' "$face_sudo" "$fb pinverification=1 userverification=1" >"$pamd/sudo"
keep_pam=1 run_script "$remove" present ok match || fail "removal succeeds on a key line with options" "$(cat "$out")"
[[ $(cat "$pamd/sudo") == "$u2f_sudo pinverification=1 userverification=1"$'\nauth include system-auth' ]] || fail "the PIN and user verification come back on the pam_u2f line" "$(cat "$pamd/sudo")"
rm -f "$pamd/polkit-1"
pass "every order of fingerprint, face and FIDO2 setup ends fingerprint, face, the daemon's key line and the password, no pam_u2f, polkit's auth_err=die and the key lane; a hand-added pam_u2f line stops setup; face removal restores pam_u2f"

# The polkit line's controls are pinned: success ends the stack, the user's
# no ends the request with no key and no password, and anything else goes
# on to the key line. Sudo's face line is `sufficient`: a no at a card the
# user saw goes on to the key line and the password (the shake-then-key
# path); the key line itself is refused by the daemon while locked.
[[ $pam_example_polkit == 'auth      [success=done auth_err=die default=ignore] pam_faceauth.so socket=/run/faceauth/sock consent' ]] || fail "polkit's face line ends the request on a refusal" "$pam_example_polkit"
[[ $face_sudo == 'auth      sufficient pam_faceauth.so socket=/run/faceauth/sock consent' ]] || fail "sudo's face line is sufficient, so a refusal goes on to the key line" "$face_sudo"
[[ $fb == 'auth      sufficient pam_faceauth.so socket=/run/faceauth/sock key-fallback cue' ]] || fail "the key line is the daemon's, sufficient, so its failure goes on to the password" "$fb"
printf '%s\n%s\nauth include system-auth\n' "$face_jump" "$fb" >"$pamd/sudo"
keep_pam=1 run_script "$setup" present ok match || fail "setup succeeds on the old jump form" "$(cat "$out")"
[[ $(cat "$pamd/sudo") == "$new_order" ]] || fail "the jump form is written back sufficient" "$(cat "$pamd/sudo")"
pass "the polkit face line keeps auth_err=die, and the sudo one and the key line are sufficient"

# Each change replaces the whole file in one step: when the root-owned copy
# cannot be written, the stack is left exactly as it was, setup says so,
# and no stage is left behind.
printf '%s\nauth include system-auth\n' "$u2f_sudo" >"$pamd/sudo"
TEST_INSTALL_FAIL=1 keep_pam=1 run_script "$setup" present ok match && fail "setup fails when the stack cannot be replaced"
[[ $(cat "$pamd/sudo") == "$u2f_sudo"$'\nauth include system-auth' ]] || fail "a stack that could not be replaced is left as it was" "$(cat "$pamd/sudo")"
grep -q 'sudo could not be changed as intended and was left as it was' "$out" || fail "setup says the stack was left as it was" "$(cat "$out")"
[[ -z $(ls -A "$pamd" | grep '\.omarchy\.') ]] || fail "no stage is left behind" "$(ls -A "$pamd")"
pass "a stack that cannot be replaced is left exactly as it was"

# The lock screen's key lane that cannot be written fails setup, said out
# loud, rather than leave an older lane standing while setup reports done
# (Codex 6).
printf '%s\nauth include system-auth\n' "$u2f_sudo" >"$pamd/sudo"
rm -f "$pamd/polkit-1" "$pamd/omarchy-lock-fido2"
printf '#%%PAM-1.0\nauth       required                    pam_u2f.so cue authfile=/etc/fido2/fido2\n' >"$pamd/omarchy-lock-fido2"
TEST_INSTALL_FAIL_FOR=omarchy-lock-fido2 keep_pam=1 run_script "$setup" present ok match && fail "setup fails when the key lane cannot be written"
grep -q "security key lane could not be changed as intended" "$out" || fail "setup says the lane failed" "$(cat "$out")"
[[ $(cat "$pamd/sudo") == "$new_order" ]] || fail "the stacks themselves were written" "$(cat "$pamd/sudo")"
rm -f "$pamd/omarchy-lock-fido2" "$pamd/polkit-1"
pass "a key lane that cannot be written fails setup"
# Round 5 (Codex 1, Opus F2; Mike: faceauth takes over the key lines): face
# setup never leaves a pam_u2f line above face. A key line it cannot take
# over exactly (a word outside cue, pinverification= and userverification=,
# another key file or control, a second pam_u2f line, or a pam_u2f line
# beside a key-fallback line) stops setup with status 2 before anything is
# installed or changed, naming the file and the line and the way out.
for bad in \
  'auth sufficient pam_u2f.so cue authfile=/etc/fido2/fido2 nodetect' \
  'auth sufficient pam_u2f.so cue authfile=/home/someone/keys' \
  'auth required pam_u2f.so cue authfile=/etc/fido2/fido2' \
  "$u2f_sudo"$'\n'"$u2f_sudo" \
  "$u2f_sudo"$'\n'"$fb" \
  "$fb"$'\n'"$fb"; do
  printf '%s\nauth include system-auth\n' "$bad" >"$pamd/sudo"
  before_sudo=$(cat "$pamd/sudo")
  printf '#%%PAM-1.0\nauth       include      system-auth\n' >"$pamd/polkit-1"
  before_polkit=$(cat "$pamd/polkit-1")
  rm -f "$pamd/omarchy-lock-face" "$pamd/omarchy-lock-fido2"
  rc=0
  keep_pam=1 run_script "$setup" present ok match || rc=$?
  (( rc == 2 )) || fail "setup stops with status 2 on a key line it cannot take over ($bad)" "rc=$rc $(cat "$out")"
  [[ $(cat "$pamd/sudo") == "$before_sudo" && $(cat "$pamd/polkit-1") == "$before_polkit" ]] || fail "nothing is changed ($bad)" "$(cat "$pamd/sudo")"
  [[ ! -e $pamd/omarchy-lock-face ]] || fail "no lock service is written ($bad)"
  ! grep -q 'omarchy-pkg-add' "$calls" || fail "nothing is installed ($bad)" "$(cat "$calls")"
  ! grep -qE $'sudo\t(install|mv|mktemp)' "$calls" || fail "no stack is staged ($bad)" "$(cat "$calls")"
  grep -q 'sudo has a FIDO2 line face authentication cannot take over' "$out" || fail "setup names the file ($bad)" "$(cat "$out")"
  grep -qF "${bad##*$'\n'}" "$out" || fail "setup names the line ($bad)" "$(cat "$out")"
  grep -q 'Remove > Security > Fido2' "$out" || fail "setup says how to fix it ($bad)" "$(cat "$out")"
done
# The same in polkit-1, with sudo in order.
printf '%s\nauth include system-auth\n' "$u2f_sudo" >"$pamd/sudo"
printf '#%%PAM-1.0\nauth      sufficient pam_u2f.so cue authfile=/etc/fido2/fido2 interactive\nauth       include      system-auth\n' >"$pamd/polkit-1"
before_sudo=$(cat "$pamd/sudo"); before_polkit=$(cat "$pamd/polkit-1")
rc=0
keep_pam=1 run_script "$setup" present ok match || rc=$?
(( rc == 2 )) && [[ $(cat "$pamd/sudo") == "$before_sudo" && $(cat "$pamd/polkit-1") == "$before_polkit" ]] || fail "a line polkit-1 cannot take over stops setup before sudo is touched" "rc=$rc $(cat "$pamd/sudo")"
grep -q 'polkit-1 has a FIDO2 line face authentication cannot take over' "$out" || fail "setup names polkit-1" "$(cat "$out")"
rm -f "$pamd/polkit-1"
pass "face setup stops with status 2 before changing anything on a key line it cannot take over, and says which and how to fix it"

# Round 5 (Codex 2, Opus F1): a key-fallback line with a word the scripts do
# not mirror, or one said twice, is never rewritten with defaults: every
# mode leaves the stack as it is and returns 2. And a rewrite must carry the
# key line's policy exactly (pam_stack_landed).
(
  export TEST_LOG="$calls" TEST_PAMD="$pamd" TEST_BACKUPS="$backups" TEST_STORE="$store"
  export OMARCHY_PATH="$omarchy_tree" XDG_RUNTIME_DIR="$test_tmp" PATH="$stub_bin:$PATH"
  source "$omarchy_tree/install/helpers/pam-stack.sh"
  for odd in "$fb pinverification=1 userverification=1 timeout=45" "$fb pinverification=1 pinverification=0" "$fb cue"; do
    for mode in face fido2 unface; do
      printf '%s\n%s\nauth include system-auth\n' "$face_sudo" "$odd" >"$pamd/sudo"
      before=$(cat "$pamd/sudo")
      rc=0; pam_stack_place "$pamd/sudo" "$mode" "$face_sudo" || rc=$?
      (( rc == 2 )) || { echo "$mode on '$odd': rc=$rc"; cat "$pamd/sudo"; exit 1; }
      [[ $(cat "$pamd/sudo") == "$before" ]] || { echo "$mode on '$odd' changed the stack"; cat "$pamd/sudo"; exit 1; }
    done
  done
  old="$face_sudo"$'\n'"$fb pinverification=1 userverification=1"$'\nauth include system-auth'
  new="$face_sudo"$'\n'"$fb"$'\nauth include system-auth'
  ! pam_stack_landed face "$face_sudo" "$old" "$new" "$pamd/sudo" || { echo "landed took a dropped PIN"; exit 1; }
  new="$face_sudo"$'\n'"$fb pinverification=1 userverification=1"$'\nauth include system-auth'
  pam_stack_landed face "$face_sudo" "$old" "$new" "$pamd/sudo" || { echo "landed refused the same policy"; exit 1; }
) >"$out" 2>&1 || fail "a key line with an odd word is left alone with status 2, and a rewrite keeps the policy exactly" "$(cat "$out")"
pass "a key line with a word the scripts do not mirror, or one said twice, is never rewritten with defaults"

# Round 5 (Codex 4): a word absent, `=0` and `=1` are three different things
# to pam_u2f, and each comes through face setup and face removal as it was.
for words in '' ' pinverification=0' ' userverification=0' ' pinverification=1 userverification=0' ' pinverification=0 userverification=1'; do
  printf '%s\nauth include system-auth\n' "$u2f_sudo$words" >"$pamd/sudo"
  rm -f "$pamd/polkit-1"
  keep_pam=1 run_script "$setup" present ok match || fail "setup succeeds on '$words'" "$(cat "$out")"
  [[ $(sed -n 2p "$pamd/sudo") == "$fb$words" ]] || fail "the key line keeps '$words' exactly" "$(cat "$pamd/sudo")"
  keep_pam=1 run_script "$remove" present ok match || fail "removal succeeds on '$words'" "$(cat "$out")"
  [[ $(cat "$pamd/sudo") == "$u2f_sudo$words"$'\nauth include system-auth' ]] || fail "removal restores '$words' exactly" "$(cat "$pamd/sudo")"
done
rm -f "$pamd/polkit-1"
pass "absent, =0 and =1 stay distinct through face setup and removal"

# Round 5 (Codex 6): the lock file is made private first, under umask 077,
# and only then root:wheel 0640, so no other account can open it while it
# is being made.
rm -f "$test_tmp/pam-stack.lock" "$test_tmp/pam-stack.lock.chowned"
(
  umask 022
  export TEST_LOG="$calls" TEST_PAMD="$pamd" TEST_BACKUPS="$backups" TEST_STORE="$store"
  export OMARCHY_PATH="$omarchy_tree" XDG_RUNTIME_DIR="$test_tmp" PATH="$stub_bin:$PATH"
  source "$omarchy_tree/install/helpers/pam-stack.sh"
  : >"$calls"
  pam_stack_locked true || exit 1
  grep -Fxq $'touch-umask\t0077' "$calls" || exit 2
  [[ $(stat -c '%a' -- "$pam_stack_lock") == "640" ]] || exit 3
) >"$out" 2>&1 || fail "the lock file is made private first, then root:wheel 0640 (step $?)" "$(cat "$out" "$calls")"
pass "the lock file is made private first, then root:wheel 0640"

# Two edits at once are serialized: each reads, renders and publishes the
# stack under one lock, from a stage of its own, so neither writes over the
# other's change. Face and FIDO2 setup race here on one stack, with every
# root copy slowed down.
printf 'auth include system-auth\n' >"$pamd/sudo"
(
  export TEST_LOG="$calls" TEST_PAMD="$pamd" TEST_BACKUPS="$backups" TEST_STORE="$store" TEST_INSTALL_SLOW=0.3
  export OMARCHY_PATH="$omarchy_tree" XDG_RUNTIME_DIR="$test_tmp" PATH="$stub_bin:$PATH"
  source "$omarchy_tree/install/helpers/pam-stack.sh"
  pam_stack_place "$pamd/sudo" face "$face_sudo" &
  first=$!
  pam_stack_place "$pamd/sudo" fido2 "" &
  second=$!
  wait "$first"
  wait "$second"
) >"$out" 2>&1 || true
[[ $(cat "$pamd/sudo") == "$new_order" ]] || fail "two edits at once both land, one after the other" "$(cat "$pamd/sudo")"
[[ -z $(ls -A "$pamd" | grep '\.omarchy\.') ]] || fail "no stage is left behind after the race" "$(ls -A "$pamd")"
pass "two edits at once are serialized, from stages of their own"

# The lock is the machine's, not a user's: a run from another account (its
# own runtime directory) waits for a holder of the one root-made lock file.
(
  export TEST_LOG="$calls" TEST_PAMD="$pamd" TEST_BACKUPS="$backups" TEST_STORE="$store"
  export OMARCHY_PATH="$omarchy_tree" PATH="$stub_bin:$PATH"
  source "$omarchy_tree/install/helpers/pam-stack.sh"
  [[ $pam_stack_lock == "$test_tmp/pam-stack.lock" ]] || exit 1
  flock "$pam_stack_lock" sleep 1.5 &
  holder=$!
  sleep 0.3
  start=$(date +%s%N)
  XDG_RUNTIME_DIR="$test_tmp/another-user" pam_stack_locked true
  waited=$(( ($(date +%s%N) - start) / 1000000 ))
  wait "$holder"
  (( waited >= 900 ))
) >"$out" 2>&1 || fail "a run from another account waits for the machine-wide lock" "$(cat "$out")"
pass "the PAM edit lock is one root-made file for the whole machine"

# The lock file is made root:wheel 0640 whatever the umask, and checked on
# every use: under umask 077 root's touch makes it 0600, which nobody in
# wheel could open, so setup chowns and chmods it; a file that is not so is
# put right before any edit, and one that cannot be is refused.
rm -f "$test_tmp/pam-stack.lock" "$test_tmp/pam-stack.lock.chowned"
(
  umask 077
  export TEST_LOG="$calls" TEST_PAMD="$pamd" TEST_BACKUPS="$backups" TEST_STORE="$store"
  export OMARCHY_PATH="$omarchy_tree" XDG_RUNTIME_DIR="$test_tmp" PATH="$stub_bin:$PATH"
  source "$omarchy_tree/install/helpers/pam-stack.sh"
  : >"$calls"
  pam_stack_locked true || exit 1
  [[ $(stat -c '%a' -- "$pam_stack_lock") == "640" ]] || exit 2
  grep -Fxq $'sudo\ttouch\t'"$pam_stack_lock" "$calls" || exit 3
  grep -Fxq $'sudo\tchown\troot:wheel\t'"$pam_stack_lock" "$calls" || exit 4
  grep -Fxq $'sudo\tchmod\t0640\t'"$pam_stack_lock" "$calls" || exit 5
  : >"$calls"
  pam_stack_locked true || exit 6
  ! grep -q $'sudo\t' "$calls" || exit 7
  /usr/bin/chmod 0644 "$pam_stack_lock"
  pam_stack_locked true || exit 8
  [[ $(stat -c '%a' -- "$pam_stack_lock") == "640" ]] || exit 9
  /usr/bin/chmod 0644 "$pam_stack_lock"
  TEST_CHMOD_FAIL=1 pam_stack_locked true && exit 10
  exit 0
) >"$out" 2>&1 || fail "the lock file is root:wheel 0640 under umask 077 and checked on every use (step $?)" "$(cat "$out" "$calls")"
pass "the lock file is made root:wheel 0640 whatever the umask and checked on every use"

# Removing face lines replaces the stack whole and keeps every other line
# where it was, and the key line turns back into our pam_u2f line; a
# polkit-1 that appears while setup waits for the lock gets our line rather
# than being written over.
(
  export TEST_LOG="$calls" TEST_PAMD="$pamd" TEST_BACKUPS="$backups" TEST_STORE="$store"
  export OMARCHY_PATH="$omarchy_tree" XDG_RUNTIME_DIR="$test_tmp" PATH="$stub_bin:$PATH"
  source "$omarchy_tree/install/helpers/pam-stack.sh"
  printf '%s\n%s\n%s\n# pam_faceauth.so kept\nauth include system-auth\n' "$fp_stack" "$face_jump" "$fb" >"$pamd/sudo"
  pam_stack_place "$pamd/sudo" unface ""
  [[ $(cat "$pamd/sudo") == "$fp_stack"$'\n'"$u2f_sudo"$'\n# pam_faceauth.so kept\nauth include system-auth' ]] || { cat "$pamd/sudo"; exit 1; }
  rc=0; pam_stack_place "$pamd/sudo" unface "" || rc=$?
  (( rc == 1 )) || exit 1
  printf '#%%PAM-1.0\nauth       include      system-auth\n' >"$pamd/polkit-1"
  rc=0; pam_stack_create "$pamd/polkit-1" "not this" face "$pam_example_polkit" || rc=$?
  (( rc == 0 )) && [[ $(cat "$pamd/polkit-1") == "$pam_example_polkit"$'\n#%PAM-1.0\nauth       include      system-auth' ]] || { cat "$pamd/polkit-1"; exit 1; }
  rm -f "$pamd/polkit-1"
  pam_stack_create "$pamd/polkit-1" "made whole" face "$pam_example_polkit"
  [[ $(cat "$pamd/polkit-1") == "made whole" ]] || exit 1
  rm -f "$pamd/polkit-1"
) >"$out" 2>&1 || fail "face lines come out whole, and a stack that appears meanwhile is edited, not replaced" "$(cat "$out")"
[[ -z $(ls -A "$pamd" | grep '\.omarchy\.') ]] || fail "no stage is left behind" "$(ls -A "$pamd")"
pass "face lines come out of a stack whole, and a stack that appears meanwhile is edited rather than written over"

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
pass "setup replaces a face line it did not write and recognizes only its own"

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

# A polkit-1 that setup found gets the example's polkit-1 line, the same one a
# created file carries, and no marker: the file stays someone else's.
rm -rf "$backups"; mkdir -p "$backups"
printf '#%%PAM-1.0\nauth       include      system-auth\naccount    include      system-auth\n' >"$pamd/polkit-1"
run_script "$setup" present ok match || fail "setup succeeds on a polkit-1 it found" "$(cat "$out")"
(( $(grep -cxF "$pam_example_polkit" "$pamd/polkit-1") == 1 )) || fail "setup puts the example's polkit-1 line into a stack it found" "$(cat "$pamd/polkit-1")"
(( $(grep -c . "$pamd/polkit-1") == 4 )) || fail "setup adds that one line and nothing else" "$(cat "$pamd/polkit-1")"
[[ ! -e $backups/polkit-1.created-by-faceauth ]] || fail "setup claims no polkit-1 it found"
rm -f "$pamd/polkit-1"
pass "setup puts the example's polkit-1 line into a polkit-1 it found, and claims no file"

# With the daemon stopped, the templates cannot go through it, so removal
# deletes the files itself: the template, sealed or plaintext (a machine
# without a TPM keeps <user>.json), and the blobs set aside as unreadable,
# this user's only. A neighbor whose name extends or hyphenates this one
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

# After enrollment and verification setup asks for both obscured face lock
# times, the shipped ones selected, and saves them with `presence
# obscured-lock`, which never switches the walk-away lock. Without a
# terminal, or with a question canceled, it saves nothing and says the
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
(( auth_line < save_line )) || fail "the times are asked for only after a verified enrollment" "$(cat "$calls")"
grep -q 'Obscured face lock time saved: 10 minutes in default mode, 5 minutes in secure mode' "$out" || fail "setup says what it saved" "$(cat "$out")"
rm -rf "$backups"; mkdir -p "$backups"; rm -f "$pamd/polkit-1"
run_setup_tty cancel || fail "setup succeeds when the question is canceled" "$(cat "$out")"
grep -q $'^gum\tchoose' "$calls" || fail "the canceled run was asked" "$(cat "$calls")"
! grep -q 'obscured-lock' "$calls" || fail "a canceled question saves nothing" "$(cat "$calls")"
grep -q 'Obscured face lock time left as it was' "$out" || fail "a canceled question says the times stay" "$(cat "$out")"
pass "setup asks for the obscured face lock times with a terminal, saves them without switching the lock, and keeps them otherwise"

# Setup closes with where the walk-away controls live: the bar icon, the
# chord and the menu rows for the times. It promises nothing unbuilt, even
# on a machine with a fingerprint reader and a FIDO2 key.
hw_bin="$test_tmp/hw-bin"
mkdir -p "$hw_bin"
printf '#!/bin/bash\nexit 0\n' >"$hw_bin/omarchy-hw-fingerprint"
printf '#!/bin/bash\necho "/dev/hidraw3: vendor=0x1050, product=0x0407 (Yubico YubiKey OTP+FIDO+CCID)"\n' >"$hw_bin/fido2-token"
chmod +x "$hw_bin"/*
rm -rf "$backups"; mkdir -p "$backups"; rm -f "$pamd/polkit-1"
PATH="$hw_bin:$PATH" run_script "$setup" present ok match || fail "setup succeeds for the closing note" "$(cat "$out")"
grep -q 'Walk-away lock: enable it, and change its away times and obscured face lock times, under Setup > Security > Face > Walk-Away Lock (Enable, Away Time, Obscured Face)' "$out" || fail "the note says where the walk-away lock is enabled and its times change" "$(cat "$out")"
! grep -q $'presence\ton\|presence\taway-time' "$calls" || fail "setup never enables the walk-away lock or sets an away time by itself" "$(cat "$calls")"
grep -q 'its icon sits in the top bar: a left click switches between default and secure mode, a right click lists the modes, and Super + Ctrl + Shift + L switches them from the keyboard' "$out" || fail "the note explains the bar icon and the chord" "$(cat "$out")"
! sed -n '/^Walk-away lock:/,$p' "$out" | grep -qi 'two-factor\|mfa\|fingerprint\|security key\|fido' || fail "the note never mentions two-factor mode or second-factor hardware, whatever is present" "$(cat "$out")"
rm -rf "$backups"; mkdir -p "$backups"; rm -f "$pamd/polkit-1"
run_script "$setup" present ok nomatch && fail "a failed verification still fails"
! grep -q 'Walk-away lock:' "$out" || fail "a failed setup prints no closing note" "$(cat "$out")"
pass "setup closes with the walk-away controls, and only after a verified enrollment"

# Tune Gestures and the Walk-Away Lock rows in the menu run the setup
# command with a flag, so the menu file names no sudo: the command's own root
# guard and requires-sudo header cover them, as omarchy-sudo-passwordless
# does. Each flag runs its one faceauth call and nothing else of setup.
# Enable and Disable are `--walk-away on|off`, which switch the watch and
# keep the saved away times.
run_script "$setup" present ok match --gestures || fail "setup --gestures succeeds" "$(cat "$out")"
[[ $(cat "$calls") == $'sudo\tfaceauth\tcalibrate\t--user\t'"$USER"$'\t--guided\nfaceauth\tcalibrate\t--user\t'"$USER"$'\t--guided' ]] || fail "--gestures runs the guided calibration for the user and nothing else" "$(cat "$calls")"
for v in on off; do
  run_script "$setup" present ok match --walk-away "$v" || fail "setup --walk-away $v succeeds" "$(cat "$out")"
  [[ $(cat "$calls") == $'sudo\tfaceauth\tpresence\t'"$v"$'\t--user\t'"$USER"$'\nfaceauth\tpresence\t'"$v"$'\t--user\t'"$USER" ]] || fail "--walk-away $v switches the watch $v for the user and nothing else" "$(cat "$calls")"
done
run_script "$setup" present ok match --bogus && fail "an unknown flag is refused"
[[ ! -s $calls ]] || fail "an unknown flag runs nothing" "$(cat "$calls")"
pass "the menu's gesture, Enable and Disable rows run through the setup command"

# Add Look is `--add [label]`: one enrollment under a label cut to letters,
# digits, - and _, with no leading dash so faceauth cannot read it as an
# option, opened at the distance step, and nothing else of setup.
# It never writes a PAM file. Without the package face authentication is not
# set up; a stopped service is said as such.
add_expect() { printf 'systemctl\tis-active\t--quiet\tfaceauth.service\nsudo\tfaceauth\tenroll\t--user\t%s\t--label\t%s\t--guided\t--start\tdistance\nfaceauth\tenroll\t--user\t%s\t--label\t%s\t--guided\t--start\tdistance' "$USER" "$1" "$USER" "$1"; }
rm -rf "$backups"; mkdir -p "$backups"; rm -f "$pamd/polkit-1" "$pamd/omarchy-lock-face"
TEST_PKG=present run_script "$setup" present ok match --add 'my glasses!; rm -rf ~' || fail "setup --add succeeds" "$(cat "$out")"
[[ $(cat "$calls") == "$(add_expect myglassesrm-rf)" ]] || fail "--add enrolls under the sanitized label from the distance step and runs nothing else" "$(cat "$calls")"
[[ $(cat "$pamd/sudo") == "auth include system-auth" && ! -e $pamd/polkit-1 && ! -e $pamd/omarchy-lock-face ]] || fail "--add writes no PAM file" "$(ls -A "$pamd")"
[[ -z $(ls -A "$backups") ]] || fail "--add keeps no marker" "$(ls -A "$backups")"
TEST_PKG=present run_script "$setup" present ok match --add '!!!' || fail "setup --add with a label of symbols succeeds" "$(cat "$out")"
[[ $(cat "$calls") == "$(add_expect extra)" ]] || fail "a label with nothing left after sanitizing becomes extra" "$(cat "$calls")"
TEST_PKG=present run_script "$setup" present ok match --add -h || fail "setup --add -h succeeds" "$(cat "$out")"
[[ $(cat "$calls") == "$(add_expect h)" ]] || fail "a label of -h loses its dash and never reaches faceauth as an option" "$(cat "$calls")"
TEST_PKG=present run_script "$setup" present ok match --add --x || fail "setup --add --x succeeds" "$(cat "$out")"
[[ $(cat "$calls") == "$(add_expect x)" ]] || fail "a label of --x loses both dashes" "$(cat "$calls")"
TEST_PKG=present run_script "$setup" present ok match --add --- || fail "setup --add --- succeeds" "$(cat "$out")"
[[ $(cat "$calls") == "$(add_expect extra)" ]] || fail "a label of dashes only becomes extra" "$(cat "$calls")"
rm -f "$calls.gum"
TEST_PKG=present TEST_GUM='lamp light' run_script "$setup" present ok match --add || fail "setup --add without a label asks for one" "$(cat "$out")"
grep -q $'^gum\tinput' "$calls" && grep -q $'\t--label\tlamplight\t' "$calls" || fail "a label asked for is sanitized too" "$(cat "$calls")"
TEST_PKG=present run_script "$setup" present ok match --add && fail "a canceled label question fails"
! grep -q $'faceauth\tenroll' "$calls" || fail "a canceled label question enrolls nothing" "$(cat "$calls")"
TEST_PKG=present run_script "$setup" present fail match --add glasses && fail "a failed --add enrollment fails"
grep -q 'Enrollment failed' "$out" || fail "a failed --add enrollment says so" "$(cat "$out")"
run_script "$setup" present ok match --add glasses && fail "--add without the package fails"
grep -q 'not set up yet' "$out" && [[ ! -s $calls ]] || fail "--add without the package says face authentication is not set up and runs nothing" "$(cat "$out")"
TEST_PKG=present TEST_ACTIVE=no run_script "$setup" present ok match --add glasses && fail "--add with the service stopped fails"
grep -q 'service is not running' "$out" && ! grep -q 'not set up' "$out" || fail "a stopped service is said as stopped, not as not set up" "$(cat "$out")"
! grep -q $'faceauth\tenroll' "$calls" || fail "--add with the service stopped enrolls nothing" "$(cat "$calls")"
TEST_PKG=present run_script "$setup" present ok match --add glasses beard && fail "--add with two labels is refused"
[[ ! -s $calls ]] || fail "--add with two labels runs nothing" "$(cat "$calls")"
[[ $(cat "$pamd/sudo") == "auth include system-auth" && ! -e $pamd/polkit-1 && ! -e $pamd/omarchy-lock-face ]] || fail "no --add case writes a PAM file" "$(ls -A "$pamd")"
pass "setup --add enrolls another look under a sanitized label and writes no PAM file"

# The away time flags save one mode's away time each through `presence
# away-time` and take only the menu's values: never, 20, 30 or 60 seconds in
# default mode, and 20, 30 or 60 in secure mode, where an empty chair always
# locks. They never run `presence on` or `off`, so the walk-away lock stays
# as it was. The old `--walk-away 20|30|60`, which also turned the watch on,
# is refused.
for v in never 20 30 60; do
  run_script "$setup" present ok match --away-time "$v" || fail "setup --away-time $v succeeds" "$(cat "$out")"
  [[ $(cat "$calls") == $'sudo\tfaceauth\tpresence\taway-time\t--default\t'"$v"$'\nfaceauth\tpresence\taway-time\t--default\t'"$v" ]] || fail "--away-time $v saves the default-mode away time and nothing else" "$(cat "$calls")"
done
for v in 20 30 60; do
  run_script "$setup" present ok match --secure-away-time "$v" || fail "setup --secure-away-time $v succeeds" "$(cat "$out")"
  [[ $(cat "$calls") == $'sudo\tfaceauth\tpresence\taway-time\t--secure\t'"$v"$'\nfaceauth\tpresence\taway-time\t--secure\t'"$v" ]] || fail "--secure-away-time $v saves the secure-mode away time and nothing else" "$(cat "$calls")"
done
for bad in "--walk-away 20" "--walk-away 30" "--walk-away 60" "--walk-away 45" "--walk-away never" "--walk-away enable" "--walk-away" "--walk-away on off" "--away-time 45" "--away-time 200" "--away-time 0" "--away-time none" "--away-time" "--away-time 20 30" "--secure-away-time never" "--secure-away-time 45" "--secure-away-time 0" "--secure-away-time" "--secure-away-time 20 30"; do
  read -ra bad_args <<<"$bad"
  run_script "$setup" present ok match "${bad_args[@]}" && fail "setup $bad is refused"
  [[ ! -s $calls ]] || fail "setup $bad runs nothing" "$(cat "$calls")"
done
pass "the away time flags take exactly the menu's choices and save one time each"

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
while read -r row; do
  [[ $row =~ \"icon\":\"[^\"]+\" ]] || fail "every face menu row has an icon" "$row"
done <<<"$face_rows"
while read -r label; do
  (( ${#label} <= 16 )) || fail "face menu labels fit the menu with a check mark: $label"
done < <(grep -o '"label":"[^"]*"' <<<"$face_rows" | sed 's/"label":"//; s/"$//')
grep -q '"setup.security.face.add".*omarchy-setup-security-face --add' <<<"$face_rows" || fail "Add Look runs setup --add" "$face_rows"
grep -q '"setup.security.face.gestures".*omarchy-setup-security-face --gestures' <<<"$face_rows" || fail "Tune Gestures runs setup --gestures" "$face_rows"
# Walk-Away Lock is a switch and two panels: Enable while the watch is off,
# and Disable, Away Time and Obscured Face while it is on. The rows hide with
# `when` on the daemon's config; none of them is a choice already made, so
# none is dimmed or checked. The old Off and time rows are gone.
! grep -qE '"setup\.security\.face\.lock\.(off|20|30|60)":' "$menu" || fail "the old Off and time rows are gone" "$(grep 'face.lock' "$menu")"
[[ $(grep -oE '"setup\.security\.face\.lock\.[a-z0-9]+":' "$menu" | tr -d '":' | sed 's/.*\.//' | tr '\n' ' ') == "enable disable away obscured " ]] || fail "Walk-Away Lock holds Enable, Disable, Away Time and Obscured Face, in that order" "$(grep 'face.lock' "$menu")"
[[ $(grep '"setup.security.face.lock.enable":' "$menu") == *'"label":"Enable",'*"omarchy-setup-security-face --walk-away on'"* ]] || fail "Enable runs setup --walk-away on"
[[ $(grep '"setup.security.face.lock.disable":' "$menu") == *'"label":"Disable",'*"omarchy-setup-security-face --walk-away off'"* ]] || fail "Disable runs setup --walk-away off"
for id in enable disable away obscured; do
  row=$(grep "\"setup.security.face.lock.$id\":" "$menu")
  [[ $row == *'"when":"'* ]] || fail "the $id row hides by the watch's state" "$row"
  [[ $row != *'"checked"'* && $row != *'"disabled"'* ]] || fail "the $id row is shown or hidden, never checked or dimmed" "$row"
done
# The guards read the daemon's config, which presence on|off rewrites with
# enabled; each runs as a bash condition against a scratch copy.
conf="$test_tmp/config.toml"
when_of() { grep "\"setup.security.face.lock.$1\":" "$menu" | sed 's/.*"when":"\([^"]*\)".*/\1/' | sed "s|/etc/faceauth/config.toml|$conf|g"; }
shown_rows() {
  local id rows=()
  for id in enable disable away obscured; do
    bash -c "$(when_of "$id")" && rows+=("$id")
  done
  echo "${rows[*]}"
}
printf '[presence]\nenabled = true\nuser = "%s"\naway_seconds = 30.0\n' "$USER" >"$conf"
[[ $(shown_rows) == "disable away obscured" ]] || fail "with the watch on, Disable, Away Time and Obscured Face show" "$(shown_rows)"
printf '[presence]\nenabled = false\nuser = "%s"\naway_seconds = 30.0\n' "$USER" >"$conf"
[[ $(shown_rows) == "enable" ]] || fail "with the watch off, only Enable shows" "$(shown_rows)"
printf '[presence]\n# enabled = true\nuser = "%s"\n' "$USER" >"$conf"
[[ $(shown_rows) == "enable" ]] || fail "a commented-out enabled line reads as off" "$(shown_rows)"
rm -f "$conf"
[[ $(shown_rows) == "enable" ]] || fail "with no config at all, only Enable shows" "$(shown_rows)"
pass "Walk-Away Lock shows Enable while the watch is off, and Disable, Away Time and Obscured Face while it is on"

# Away Time opens one panel per mode, each titled with its mode, with one
# sentence of help as its search description. Default mode offers Never and
# 20, 30 and 60 seconds; secure mode offers 20, 30 and 60 seconds and no
# Never, since an empty chair always locks there. Every time row runs setup
# with its value and marks itself from the daemon's config, with the shipped
# 20 seconds checked while the key is unset.
guard_of() { grep "\"setup.security.face.lock.$1\"" "$menu" | sed 's/.*"checked":"\(.*\)","action".*/\1/' | sed 's/\\"/"/g; s/\\\\/\\/g' | sed "s|/etc/faceauth/config.toml|$conf|g"; }
away=$(grep '"setup.security.face.lock.away":' "$menu")
[[ $away == *'"label":"Away Time","title":"Away time","description":"How long the chair stays empty before the session locks, in default mode and in secure mode."'* ]] || fail "Away Time opens a panel titled Away time that says what the time is for" "$away"
[[ $(grep '"setup.security.face.lock.away.default":' "$menu") == *'"label":"Default mode","title":"Away, default mode","description":"How long the chair stays empty before the session locks in default mode."'* ]] || fail "the default-mode away panel is named for its mode"
[[ $(grep '"setup.security.face.lock.away.secure":' "$menu") == *'"label":"Secure mode","title":"Away, secure mode","description":"How long the chair stays empty before the session locks in secure mode, where an empty chair always locks."'* ]] || fail "the secure-mode away panel is named for its mode and says an empty chair always locks there"
(( $(grep -cE '"setup\.security\.face\.lock\.away\.[a-z]+":' "$menu") == 2 )) || fail "Away Time holds exactly the two mode panels" "$(grep 'lock.away' "$menu")"
[[ $(grep '"setup.security.face.lock.away.default.never":' "$menu") == *'"label":"Never","description":"Default mode never locks the session, even with the chair empty; only secure mode does."'* ]] || fail "the Never row says what never means"
for v in never 20 30 60; do
  grep -q "\"setup.security.face.lock.away.default.$v\".*\"checked\".*omarchy-setup-security-face --away-time $v'" <<<"$face_rows" || fail "the default-mode $v row runs setup --away-time $v and marks itself" "$face_rows"
done
for v in 20 30 60; do
  grep -q "\"setup.security.face.lock.away.secure.$v\".*\"checked\".*omarchy-setup-security-face --secure-away-time $v'" <<<"$face_rows" || fail "the secure-mode $v row runs setup --secure-away-time $v and marks itself" "$face_rows"
done
(( $(grep -c '"setup.security.face.lock.away.default\.' <<<"$face_rows") == 4 && $(grep -c '"setup.security.face.lock.away.secure\.' <<<"$face_rows") == 3 )) || fail "the away panels offer exactly the menu's choices" "$face_rows"
away_rows() {
  local id rows=()
  for id in default.never default.20 default.30 default.60 secure.20 secure.30 secure.60; do
    bash -c "$(guard_of "away.$id")" && rows+=("$id")
  done
  echo "${rows[*]}"
}
printf '[presence]\nenabled = true\nuser = "%s"\n' "$USER" >"$conf"
[[ $(away_rows) == "default.20 secure.20" ]] || fail "with no away time set the shipped 20 seconds are checked in each mode" "$(away_rows)"
printf '[presence]\nenabled = true\nuser = "%s"\naway_seconds = 20.0\nsecure_away_seconds = 20.0\n' "$USER" >"$conf"
[[ $(away_rows) == "default.20 secure.20" ]] || fail "the written shipped values read the same" "$(away_rows)"
printf '[presence]\nenabled = true\nuser = "%s"\naway_seconds = 30.0\nsecure_away_seconds = 60.0\n' "$USER" >"$conf"
[[ $(away_rows) == "default.30 secure.60" ]] || fail "30 and 60 seconds are checked in their modes and nothing else" "$(away_rows)"
printf '[presence]\nenabled = true\nuser = "%s"\naway_seconds = "never"\nsecure_away_seconds = 30.0\n' "$USER" >"$conf"
[[ $(away_rows) == "default.never secure.30" ]] || fail "never is checked instead of the shipped 20 seconds" "$(away_rows)"
printf '[presence]\nenabled = true\nuser = "%s"\naway_seconds = 200.0\nsecure_away_seconds = 200\n' "$USER" >"$conf"
[[ -z $(away_rows) ]] || fail "200 seconds checks no row, not the 20 row it starts with" "$(away_rows)"
printf '[presence]\nenabled = true\nuser = "%s"\naway_seconds = 20.5\nsecure_away_seconds = 60\n' "$USER" >"$conf"
[[ $(away_rows) == "secure.60" ]] || fail "20.5 seconds checks no default row, and a whole 60 checks the secure one" "$(away_rows)"
printf '[presence]\nenabled = true\nuser = "%s"\nsecure_away_seconds = 30.0\n' "$USER" >"$conf"
[[ $(away_rows) == "default.20 secure.30" ]] || fail "the secure away time is not read as the default one" "$(away_rows)"
rm -f "$conf"
[[ $(away_rows) == "default.20 secure.20" ]] || fail "with no config at all the shipped 20 seconds are checked" "$(away_rows)"
pass "Away Time opens a panel per mode, runs through setup and shows the current time from the daemon's config"

# The obscured face lock time is one Obscured Face row under Walk-Away Lock,
# titled with the full name, opening one panel per mode. It shows while the
# walk-away lock is on, as Away Time does. Each panel keeps one sentence of
# help as its search description. Every time row runs setup with its value
# and marks itself from the daemon's config.
obscured=$(grep '"setup.security.face.lock.obscured":' "$menu")
[[ $obscured == *'"label":"Obscured Face","title":"Obscured face lock time"'* ]] || fail "one Obscured Face row opens a panel titled with the full name" "$obscured"
(( $(grep -c '"setup.security.face.lock.[a-z-]*obscured[a-z-]*":' "$menu") == 1 )) || fail "Walk-Away Lock holds one obscured face row" "$(grep 'obscured' "$menu")"
[[ $(grep '"setup.security.face.lock.obscured.default":' "$menu") == *'"label":"Default mode","title":"Obscured, default mode"'* ]] || fail "the default-mode panel is named for its mode"
[[ $(grep '"setup.security.face.lock.obscured.secure":' "$menu") == *'"label":"Secure mode","title":"Obscured, secure mode"'* ]] || fail "the secure-mode panel is named for its mode"
(( $(grep -cE '"setup\.security\.face\.lock\.obscured\.[a-z]+":' "$menu") == 2 )) || fail "Obscured Face holds exactly the two mode panels" "$(grep 'obscured' "$menu")"
for g in obscured obscured.default obscured.secure; do
  group=$(grep "\"setup.security.face.lock.$g\":" "$menu")
  [[ -n $group ]] || fail "the $g panel is in the menu"
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
pass "Obscured Face opens a panel per mode, runs through setup and shows the current time from the daemon's config"

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

# An IR sensor on another graph (IPU6, or a UVC module with a grayscale
# node): the daemon cannot drive it, so it is not listed.
seed_sysfs video0="Intel IPU6 ISYS Capture 0" v4l-subdev0="Intel IPU6 CSI2 0" v4l-subdev1="ov7251 1-0060" video2="Integrated IR Camera: Integrated I"
listed=$(OMARCHY_V4L_SYSFS_PATH="$fake_sysfs" bash "$lister_list") && fail "the lister exits 1 without an ipu3-cio2 graph"
[[ -z $listed ]] || fail "the lister prints nothing without an ipu3-cio2 graph" "$listed"
pass "the lister lists nothing for an IR sensor the daemon cannot drive"

seed_sysfs
OMARCHY_V4L_SYSFS_PATH="$fake_sysfs/missing" bash "$lister_list" && fail "the lister exits 1 with no sysfs tree"
pass "the lister exits 1 with no sysfs tree at all"
