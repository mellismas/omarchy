#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

remove="$ROOT/bin/omarchy-remove-security-fido2"

test_tmp=$(mktemp -d)
stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
authdir="$test_tmp/etc-fido2"
elsewhere="$test_tmp/elsewhere"
pamd="$test_tmp/pam.d"
lock_pam="$pamd/omarchy-lock-fido2"
remove_copy="$test_tmp/remove.sh"
mkdir -p "$stub_bin" "$pamd"

cleanup() {
  rm -rf "$test_tmp"
  return 0
}
trap cleanup EXIT

# The same seam the setup and migration suites use: the removal deletes an
# absolute path no unprivileged suite can own, and an environment override in
# the shipped command would hand a privileged rm -rf an operand the caller
# chooses. Retarget a copy instead, and fail if the path is not named exactly
# once so this seam cannot quietly stop standing for the command it copies.
occurrences=$(grep -Fxc 'authdir=/etc/fido2' "$remove") || occurrences=0
(( occurrences == 1 )) ||
  fail "the removal names its FIDO2 directory exactly once" "found $occurrences occurrences"
pass "removal names its FIDO2 directory once, and the test drives a retargeted copy"

occurrences=$(grep -Fxc 'lock_pam=/etc/pam.d/omarchy-lock-fido2' "$remove") || occurrences=0
(( occurrences == 1 )) ||
  fail "the removal names the lock screen's FIDO2 service exactly once" "found $occurrences occurrences"

# The stacks it rewrites are retargeted too, so the removal is checked on
# scratch stacks and never reads or writes the host's, and so is the
# machine-wide PAM edit lock: the run sources a copy of the shared helper,
# from a scratch tree, whose lock is a scratch file.
helper="$ROOT/install/helpers/pam-stack.sh"
occurrences=$(grep -Fxc 'pam_stack_lock=/run/omarchy-pam-stack.lock' "$helper") || occurrences=0
(( occurrences == 1 )) || fail "the helper names its lock exactly once" "found $occurrences occurrences"
omarchy_tree="$test_tmp/omarchy"
mkdir -p "$omarchy_tree/install/helpers"
sed -e "s|^pam_stack_lock=/run/omarchy-pam-stack.lock$|pam_stack_lock=$test_tmp/pam-stack.lock|" "$helper" >"$omarchy_tree/install/helpers/pam-stack.sh"
sed -e "s|^authdir=/etc/fido2$|authdir=$authdir|" \
  -e "s|/etc/pam.d|$pamd|g" "$remove" >"$remove_copy"
! grep -q '/etc/pam\.d' "$remove_copy" || fail "the retargeted copy names no real PAM stack"

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash

set -euo pipefail

reject() {
  printf 'refusing unexpected sudo invocation:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  exit 97
}

if [[ ${TEST_AUTHDIR:-} != /* || ${TEST_LOG:-} != /* || ${TEST_LOCK_PAM:-} != /* || ${TEST_PAMD:-} != /* ]]; then
  reject "$@"
fi

printf 'sudo' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"

# A stage of the removal's own beside a scratch stack.
pam_stage() {
  [[ $1 =~ ^"$TEST_PAMD"/\.(sudo|polkit-1)\.omarchy\.[[:alnum:]]{6}$ && -f $1 && ! -L $1 ]]
}

case "${1:-}" in
  mktemp)
    if (( $# == 2 )) && [[ $2 =~ ^"$TEST_PAMD"/\.(sudo|polkit-1)\.omarchy\.XXXXXX$ ]]; then
      exec /usr/bin/mktemp -- "$2"
    fi
    reject "$@"
    ;;
  install)
    if [[ "${2:-} ${3:-} ${4:-} ${5:-} ${6:-} ${7:-} ${8:-} ${9:-}" == "-m 644 -o root -g root -T /dev/stdin" ]] && (( $# == 10 )) && pam_stage "${10}"; then
      exec /usr/bin/cat >"${10}"
    fi
    reject "$@"
    ;;
  cmp)
    if (( $# == 4 )) && [[ $2 == "-s" && $3 == "-" ]] && pam_stage "$4"; then
      exec /usr/bin/cmp -s - "$4"
    fi
    reject "$@"
    ;;
  mv)
    if (( $# == 5 )) && [[ $2 == "-Tf" && $3 == "--" ]] && pam_stage "$4" && [[ $5 == "$TEST_PAMD/sudo" || $5 == "$TEST_PAMD/polkit-1" ]]; then
      exec /usr/bin/mv -Tf -- "$4" "$5"
    fi
    reject "$@"
    ;;
  touch)
    # The machine-wide PAM edit lock, made by root on first use.
    if (( $# == 2 )) && [[ $2 == "${TEST_PAMD%/pam.d}/pam-stack.lock" ]]; then
      exec /usr/bin/touch "$2"
    fi
    reject "$@"
    ;;
  chown)
    if (( $# == 3 )) && [[ $2 == "root:wheel" && $3 == "${TEST_PAMD%/pam.d}/pam-stack.lock" ]]; then
      : >"$3.chowned"
      exit 0
    fi
    reject "$@"
    ;;
  chmod)
    if (( $# == 3 )) && [[ $2 == "0640" && $3 == "${TEST_PAMD%/pam.d}/pam-stack.lock" ]]; then
      exec /usr/bin/chmod 0640 "$3"
    fi
    reject "$@"
    ;;
  rm)
    if (( $# == 4 )) && [[ $2 == "-f" && $3 == "--" ]] && { pam_stage "$4" || [[ $4 == "$TEST_LOCK_PAM" ]]; }; then
      exec /usr/bin/rm -f -- "$4"
    fi
    if (( $# != 3 )) || [[ $2 != "-rf" || $3 != "$TEST_AUTHDIR" ]]; then
      reject "$@"
    fi

    exec /usr/bin/rm -rf "$TEST_AUTHDIR"
    ;;
  *)
    reject "$@"
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
chmod +x "$stub_bin/stat"

cat >"$stub_bin/omarchy-pkg-drop" <<'SH'
#!/bin/bash
SH

chmod +x "$stub_bin/sudo" "$stub_bin/omarchy-pkg-drop"

invoke_remove() {
  : >"$calls"
  [[ -f $pamd/sudo ]] || printf 'auth include system-auth\n' >"$pamd/sudo"
  TEST_AUTHDIR="$authdir" TEST_LOCK_PAM="$lock_pam" TEST_PAMD="$pamd" TEST_LOG="$calls" \
    OMARCHY_PATH="$omarchy_tree" XDG_RUNTIME_DIR="$test_tmp" PATH="$stub_bin:$ROOT/bin:$PATH" \
    bash "$remove_copy" </dev/null >/dev/null
}

# The ordinary case: a real directory holding a registration.
rm -rf "$authdir"
mkdir -p "$authdir"
printf 'tester:credential-handle,public-key,es256,+presence\n' >"$authdir/fido2"
invoke_remove
grep -Fxq $'sudo\trm\t-rf\t'"$authdir" "$calls" ||
  fail "removal deletes the FIDO2 directory" "$(cat "$calls")"
[[ ! -e $authdir ]] || fail "the FIDO2 directory is gone"
pass "removal deletes a real FIDO2 directory"

# -d is false for a dangling link, so the guard it replaced left one sitting
# there for the next setup to install an authfile through.
rm -rf "$authdir"
ln -s "$test_tmp/missing" "$authdir"
invoke_remove
grep -Fxq $'sudo\trm\t-rf\t'"$authdir" "$calls" ||
  fail "removal deletes a dangling symlink at the FIDO2 directory" "$(cat "$calls")"
[[ ! -e $authdir && ! -L $authdir ]] ||
  fail "the dangling symlink is gone"
pass "removal deletes a dangling symlink where -d would have skipped it"

# rm -rf on a symlink unlinks the link. Whatever it pointed at is not ours.
rm -rf "$authdir"
rm -rf "$elsewhere"
mkdir -p "$elsewhere"
printf 'keep me\n' >"$elsewhere/canary"
ln -s "$elsewhere" "$authdir"
invoke_remove
[[ ! -e $authdir && ! -L $authdir ]] ||
  fail "the symlink at the FIDO2 directory is gone"
[[ -d $elsewhere && -f $elsewhere/canary ]] ||
  fail "removal takes the symlink, never the directory it points at"
pass "removal takes a symlink itself and leaves its target intact"

# Nothing there at all: no escalation, so removing FIDO2 twice costs no prompt.
rm -rf "$authdir"
invoke_remove
! grep -Fq $'sudo\trm\t' "$calls" ||
  fail "removal escalates no rm when there is no FIDO2 directory" "$(cat "$calls")"
pass "removal escalates nothing when there is no FIDO2 directory"

# The lock screen's key lane shows only while its PAM service exists, so
# removal takes the service with the rest, under the PAM edit lock; with
# none there it escalates no rm for it.
rm -rf "$authdir"
printf '#%%PAM-1.0\nauth       sufficient                  pam_faceauth.so socket=/run/faceauth/sock key-unlock\nauth       required                    pam_deny.so\n' >"$lock_pam"
invoke_remove
grep -Fxq $'sudo\trm\t-f\t--\t'"$lock_pam" "$calls" ||
  fail "removal deletes the lock screen's key lane" "$(cat "$calls")"
[[ ! -e $lock_pam ]] || fail "the lock screen's key lane is gone"
invoke_remove
! grep -Fq $'sudo\trm\t-f' "$calls" ||
  fail "removal escalates no rm for a lock service that is not there" "$(cat "$calls")"
pass "removal takes the lock screen's key lane away, under the PAM edit lock"

# Every FIDO2 line goes, in one step per stack, and sudo's face line goes
# back to plain `sufficient`: a jump over a FIDO2 line that is gone would
# land past the password. Comments stay; polkit's face line keeps its
# controls.
face_jump='auth      [success=done authinfo_unavail=1 default=ignore] pam_faceauth.so socket=/run/faceauth/sock consent'
face_sudo='auth      sufficient pam_faceauth.so socket=/run/faceauth/sock consent'
face_polkit='auth      [success=done auth_err=die default=ignore] pam_faceauth.so socket=/run/faceauth/sock consent'
rm -rf "$authdir"
printf '%s\nauth    sufficient pam_u2f.so cue authfile=/etc/fido2/fido2\n# pam_u2f.so was here\nauth include system-auth\n' "$face_jump" >"$pamd/sudo"
printf '#%%PAM-1.0\n%s\nauth      sufficient pam_u2f.so cue authfile=/etc/fido2/fido2\nauth       include      system-auth\n' "$face_polkit" >"$pamd/polkit-1"
invoke_remove
[[ $(cat "$pamd/sudo") == "$face_sudo"$'\n# pam_u2f.so was here\nauth include system-auth' ]] ||
  fail "removal takes the FIDO2 line and sudo's face line goes back to sufficient" "$(cat "$pamd/sudo")"
[[ $(cat "$pamd/polkit-1") == $'#%PAM-1.0\n'"$face_polkit"$'\nauth       include      system-auth' ]] ||
  fail "removal takes polkit's FIDO2 line and leaves its face line as it was" "$(cat "$pamd/polkit-1")"
[[ -z $(ls -A "$pamd" | grep '\.omarchy\.') ]] || fail "no stage is left behind" "$(ls -A "$pamd")"
pass "removal takes every FIDO2 line and puts sudo's face line back to sufficient"


# With face set up the key line is the face daemon's key-fallback line, and
# removal takes it as it takes a pam_u2f line, in sudo and polkit-1 alike,
# leaving the face lines and the password.
fb='auth      sufficient pam_faceauth.so socket=/run/faceauth/sock key-fallback cue userverification=1'
rm -rf "$authdir"
printf '%s\n%s\nauth include system-auth\n' "$face_sudo" "$fb" >"$pamd/sudo"
printf '#%%PAM-1.0\n%s\n%s\nauth       include      system-auth\n' "$face_polkit" "$fb" >"$pamd/polkit-1"
invoke_remove
[[ $(cat "$pamd/sudo") == "$face_sudo"$'\nauth include system-auth' ]] ||
  fail "removal takes sudo's key-fallback line" "$(cat "$pamd/sudo")"
[[ $(cat "$pamd/polkit-1") == $'#%PAM-1.0\n'"$face_polkit"$'\nauth       include      system-auth' ]] ||
  fail "and polkit's" "$(cat "$pamd/polkit-1")"
pass "removal takes the face daemon's key-fallback lines too"
