# The PAM stack edits that face and FIDO2 setup and removal share.
# Whichever runs first, sudo and polkit-1 end in one order: fingerprint,
# then face, then the key, then the password. While face is set up the key
# line is the face daemon's own (pam_faceauth's key-fallback line), never
# pam_u2f, so every use of the key goes through the daemon; without face it
# is pam_u2f, as Omarchy has always written it. A line counts only when it
# is not commented out (^[^#]*module.so), for placing and for removing
# alike, and every change replaces the whole file in one step, one change
# at a time on the whole machine (pam_stack_locked).

# The start of our pam_u2f line in each stack, as FIDO2 setup writes it.
pam_stack_u2f_base() {
  if [[ ${1##*/} == "sudo" ]]; then
    echo 'auth    sufficient pam_u2f.so'
  else
    echo 'auth      sufficient pam_u2f.so'
  fi
}

# Our FIDO2 line in each stack, as FIDO2 setup writes it without face.
pam_stack_u2f_line() {
  echo "$(pam_stack_u2f_base "$1") cue authfile=/etc/fido2/fido2"
}

# The awk functions every mode uses. `on` is the active-line test; `wds`
# splits a line's active part into words. A face line is pam_faceauth's
# consent or look line, a key line its key-fallback line. `u2f_opts` reads
# a pam_u2f line in our form (sufficient, Omarchy's key file once, and
# nothing but `cue` and the PIN and user verification words besides, each
# at most once) as the words a key-fallback line mirrors, and any other
# pam_u2f line as "-"; `fb_opts` reads a key-fallback line the same way.
# The words keep each of absent, `=0` and `=1`, which pam_u2f treats
# differently. `problems` names every key line face setup cannot take over
# exactly, and a second key line. `plain` reads sudo's face line in the
# jump form an earlier setup wrote as `sufficient`.
pam_stack_awk_lib='
function on(l, mod) { return l ~ ("^[^#]*" mod "\\.so") }
function act(l) { sub(/#.*/, "", l); return l }
function wds(l, w,   a, n, k, m) { n = split(act(l), a, /[ \t]+/); m = 0; for (k = 1; k <= n; k++) if (a[k] != "") w[++m] = a[k]; return m }
function has(l, word,   w, n, k) { n = wds(l, w); for (k = 1; k <= n; k++) if (w[k] == word) return 1; return 0 }
function is_fb(l) { return on(l, "pam_faceauth") && has(l, "key-fallback") }
function is_face(l) { return on(l, "pam_faceauth") && !has(l, "key-fallback") && !has(l, "key-unlock") }
function opts(cue, pin, uv,   s) { s = (cue ? "cue" : ""); if (pin != "") s = s (s == "" ? "" : " ") "pinverification=" pin; if (uv != "") s = s (s == "" ? "" : " ") "userverification=" uv; return s }
function words_opts(w, n, from, allow,   k, key, seen, cue, pin, uv) {
  cue = 0; pin = ""; uv = ""
  for (k = from; k <= n; k++) {
    key = w[k]; sub(/=.*/, "", key)
    if (key in seen) return "-"
    seen[key] = 1
    if (w[k] == "cue") cue = 1
    else if (w[k] == "pinverification=1" || w[k] == "pinverification=0") pin = substr(w[k], 17)
    else if (w[k] == "userverification=1" || w[k] == "userverification=0") uv = substr(w[k], 18)
    else if (!(w[k] in allow)) return "-"
  }
  return opts(cue, pin, uv)
}
function u2f_opts(l,   w, n, allow, o) {
  if (!on(l, "pam_u2f")) return "-"
  n = wds(l, w)
  if (n < 3 || w[1] != "auth" || w[2] != "sufficient" || w[3] != "pam_u2f.so") return "-"
  if (!has(l, "authfile=/etc/fido2/fido2")) return "-"
  allow["authfile=/etc/fido2/fido2"] = 1
  return words_opts(w, n, 4, allow)
}
function fb_opts(l,   w, n, allow) {
  if (!is_fb(l)) return "-"
  n = wds(l, w)
  if (n < 3 || w[1] != "auth" || w[2] != "sufficient" || w[3] != "pam_faceauth.so") return "-"
  allow["key-fallback"] = 1; allow["socket=/run/faceauth/sock"] = 1
  return words_opts(w, n, 4, allow)
}
function key_opts(l) { return is_fb(l) ? fb_opts(l) : u2f_opts(l) }
function tail_words(o,   t, n, k, s) { n = split(o, t, " "); s = ""; for (k = 1; k <= n; k++) if (t[k] != "cue") s = s " " t[k]; return s }
function fb_line(o) { return "auth      sufficient pam_faceauth.so socket=/run/faceauth/sock key-fallback" (o == "" ? "" : " " o) }
function u2f_line(o,   s) {
  s = u2fbase
  if (o ~ /(^| )cue( |$)/) s = s " cue"
  return s " authfile=/etc/fido2/fido2" tail_words(o)
}
function plain(l) { sub(/\[success=done authinfo_unavail=1 default=ignore\]/, "sufficient", l); return l }
function problems(n, line, out,   i, keys, m) {
  keys = 0; m = 0
  for (i = 1; i <= n; i++) {
    if (!on(line[i], "pam_u2f") && !is_fb(line[i])) continue
    keys++
    if (key_opts(line[i]) == "-") out[++m] = act(line[i]) " (a word, control or key file it cannot carry)"
    else if (keys > 1) out[++m] = act(line[i]) " (a second key line)"
  }
  return m
}
'

# Print FILE as it should be, or fail (status 3, the reason on stderr)
# where the key line cannot be carried over exactly: face setup takes over
# the key lines, and never substitutes a default for a word it cannot read.
#
# face mode (LINE is the face line): every face line goes, and LINE goes
# after the last fingerprint line (or first). The stack's one key line, our
# key-fallback line or our pam_u2f line, comes out and goes back right
# below LINE as a key-fallback line with exactly its words. Any other
# pam_u2f line, a key line with a word it cannot carry, or a second key
# line fails it: face never stays below a pam_u2f line.
#
# fido2 mode: with a face line, the same rules, and with no key line yet a
# plain `cue` key-fallback line goes right below the last face line.
# Without one, our pam_u2f line goes first (a key-fallback line left over
# is turned back into it, with its words), unless the stack has a pam_u2f
# line setup did not write, which is left alone with the rest of the file,
# as Omarchy has always done.
#
# unfido2 mode: every pam_u2f line and every key-fallback line goes.
#
# unface mode: every face line goes, and the one key-fallback line turns
# back into our pam_u2f line, where it was, with exactly its words; a
# key-fallback line it cannot read, or a second one, fails it.
#
# Sudo's face line in the old jump form is written back as `sufficient`.
pam_stack_render() {
  local file=$1 mode=$2 line=$3 u2fbase
  u2fbase=$(pam_stack_u2f_base "$file")
  awk -v mode="$mode" -v face="$line" -v u2fbase="$u2fbase" "$pam_stack_awk_lib"'
    { line[NR] = $0 }
    END {
      faces = 0; custom = 0; fbs = 0; badfb = 0
      for (i = 1; i <= NR; i++) {
        if (is_face(line[i])) faces++
        if (on(line[i], "pam_u2f") && u2f_opts(line[i]) == "-") custom = 1
        if (is_fb(line[i])) { fbs++; if (fb_opts(line[i]) == "-") badfb = 1 }
      }
      if (mode == "fido2" && faces == 0 && custom) {
        for (i = 1; i <= NR; i++) print line[i]
        exit
      }
      if (mode == "face" || (mode == "fido2" && faces > 0)) {
        if (problems(NR, line, why)) { print "cannot take over: " why[1] > "/dev/stderr"; exit 3 }
      } else if (mode == "fido2" || mode == "unface") {
        if (badfb || fbs > 1) { print "cannot carry the key-fallback line over" > "/dev/stderr"; exit 3 }
      }
      n = 0; key = ""; haskey = 0
      for (i = 1; i <= NR; i++) {
        l = line[i]
        if (mode == "unfido2") {
          if (on(l, "pam_u2f") || is_fb(l)) continue
        } else if (mode == "unface") {
          if (is_face(l)) continue
          if (is_fb(l)) { kept[++n] = u2f_line(fb_opts(l)); continue }
        } else {
          if (is_fb(l) || (on(l, "pam_u2f") && u2f_opts(l) != "-")) { haskey = 1; key = key_opts(l); continue }
          if (mode == "face" && is_face(l)) continue
        }
        if (is_face(l)) l = plain(l)
        kept[++n] = l
      }
      m = 0
      if (mode == "face") {
        at = 0
        for (i = 1; i <= n; i++) if (on(kept[i], "pam_fprintd")) at = i
        for (i = 1; i <= at; i++) out[++m] = kept[i]
        out[++m] = face
        if (haskey) out[++m] = fb_line(key)
        for (i = at + 1; i <= n; i++) out[++m] = kept[i]
      } else if (mode == "fido2" && faces > 0) {
        at = 0
        for (i = 1; i <= n; i++) if (is_face(kept[i])) at = i
        for (i = 1; i <= at; i++) out[++m] = kept[i]
        out[++m] = fb_line(haskey ? key : "cue")
        for (i = at + 1; i <= n; i++) out[++m] = kept[i]
      } else if (mode == "fido2") {
        out[++m] = u2f_line(haskey ? key : "cue")
        for (i = 1; i <= n; i++) out[++m] = kept[i]
      } else {
        for (i = 1; i <= n; i++) out[++m] = kept[i]
      }
      for (i = 1; i <= m; i++) print out[i]
    }
  ' "$file"
}

# Every key line in FILE face setup cannot take over exactly (a word,
# control or key file it cannot carry, or a second key line), one per line
# of output with the reason. Returns 1 when there is none.
pam_stack_key_problem() {
  awk "$pam_stack_awk_lib"'
    { line[NR] = $0 }
    END { m = problems(NR, line, why); for (i = 1; i <= m; i++) print why[i]; exit (m ? 0 : 1) }
  ' "$1"
}

# Whether NEW is OLD with only the intended move made: every line that is
# neither pam_faceauth's nor pam_u2f's kept, in its order; every such line
# in NEW one that OLD had (a face line read in its plain form), LINE, or a
# key line in our form; the key line carried over with exactly the words
# it had; and per mode, one face line (LINE) with at most one key-fallback
# line right below it (face), our key-fallback line right below the last
# face line or a pam_u2f line where there is no face line (fido2), no key
# line at all (unfido2), or no face or key-fallback line (unface).
pam_stack_landed() {
  local mode=$1 line=$2 old=$3 new=$4 file=$5 u2fbase
  u2fbase=$(pam_stack_u2f_base "$file")
  awk -v mode="$mode" -v face="$line" -v u2fbase="$u2fbase" "$pam_stack_awk_lib"'
    function rest(a, n, r,   i, k) { k = 0; for (i = 1; i <= n; i++) if (!on(a[i], "pam_faceauth") && !on(a[i], "pam_u2f")) r[++k] = a[i]; return k }
    FNR == NR { o[FNR] = $0; no = FNR; next }
    { w[FNR] = $0; nw = FNR }
    END {
      a = rest(o, no, r1); b = rest(w, nw, r2)
      if (a != b) exit 1
      for (i = 1; i <= a; i++) if (r1[i] != r2[i]) exit 1
      okeys = 0; oopts = ""
      for (i = 1; i <= no; i++) {
        seen[o[i]] = 1; seen[plain(o[i])] = 1
        if (is_fb(o[i]) || (on(o[i], "pam_u2f") && u2f_opts(o[i]) != "-")) { okeys++; oopts = key_opts(o[i]) }
      }
      faces = 0; fbs = 0; u2fs = 0; last = 0; fbat = 0; nkeys = 0; nopts = ""
      for (i = 1; i <= nw; i++) {
        l = w[i]
        if (is_face(l)) { faces++; last = i; if (mode == "face" && l != face) exit 1 }
        if (is_fb(l)) { fbs++; fbat = i; if (fb_opts(l) == "-") exit 1 }
        if (on(l, "pam_u2f")) u2fs++
        if (is_fb(l) || (on(l, "pam_u2f") && u2f_opts(l) != "-")) { nkeys++; nopts = key_opts(l) }
        if ((on(l, "pam_faceauth") || on(l, "pam_u2f")) && !(l in seen) && !(mode == "face" && l == face) && !(is_fb(l) && fb_opts(l) != "-") && u2f_opts(l) == "-") exit 1
      }
      if (mode != "unfido2" && okeys == 1 && (nkeys != 1 || nopts != oopts)) exit 1
      if (mode == "face" && (faces != 1 || fbs > 1 || (fbs == 1 && fbat != last + 1))) exit 1
      if (mode == "fido2" && faces > 0 && (fbs != 1 || fbat != last + 1)) exit 1
      if (mode == "fido2" && faces == 0 && u2fs == 0) exit 1
      if (mode == "unfido2" && (fbs > 0 || u2fs > 0)) exit 1
      if (mode == "unface" && (faces > 0 || fbs > 0)) exit 1
      exit 0
    }
  ' <(printf '%s\n' "$old") <(printf '%s\n' "$new")
}

# Replace FILE with CONTENT in one step: `sudo install` writes it from stdin
# into a root-created stage of its own beside FILE, the stage is compared
# with CONTENT, and it is renamed over FILE, so the stack is the old one or
# the new one and never half of either, no file the user owns is ever
# installed, and no other run's stage is ever taken for this one's.
pam_stack_write() {
  local file=$1 content=$2 stage prefix="${1%/*}/.${1##*/}.omarchy."
  stage=$(sudo mktemp "${prefix}XXXXXX") || return 1
  if [[ $stage == "$prefix"?????? && ${stage#"$prefix"} =~ ^[[:alnum:]]{6}$ ]] &&
    printf '%s\n' "$content" | sudo install -m 644 -o root -g root -T /dev/stdin "$stage" &&
    printf '%s\n' "$content" | sudo cmp -s - "$stage" &&
    sudo mv -Tf -- "$stage" "$file"; then
    return 0
  fi
  [[ $stage == "$prefix"?????? ]] && sudo rm -f -- "$stage"
  return 1
}

# The one lock every PAM edit of these scripts takes, whoever runs them: a
# file in /run, where only root creates files, made by root on first use,
# root:wheel and 0640 whatever the umask, and checked to be so on every use
# (put right when it is not). Wheel opens it read-only, which is all flock
# needs, so two runs, from one account or two, never read, render and
# publish over each other, and no account outside wheel can hold it.
pam_stack_lock=/run/omarchy-pam-stack.lock

pam_stack_lock_ok() {
  [[ -f $pam_stack_lock && ! -L $pam_stack_lock && $(stat -c '%u:%G:%a' -- "$pam_stack_lock" 2>/dev/null) == "0:wheel:640" ]]
}

# Run a command with Omarchy's PAM edits serialized machine-wide: one read,
# render and publish at a time, a file's creation and removal included.
pam_stack_locked() {
  local lock_fd status=0
  if [[ ! -e $pam_stack_lock && ! -L $pam_stack_lock ]]; then
    # Made private first (sudo keeps the stricter of the two umasks), so no
    # other account can open it before it is root:wheel 0640 below.
    (umask 077 && sudo touch "$pam_stack_lock") || return 2
  fi
  if ! pam_stack_lock_ok; then
    [[ -f $pam_stack_lock && ! -L $pam_stack_lock ]] || return 2
    sudo chown root:wheel "$pam_stack_lock" && sudo chmod 0640 "$pam_stack_lock" || return 2
    pam_stack_lock_ok || return 2
  fi
  exec {lock_fd}<"$pam_stack_lock" || return 2
  if ! flock -w 60 "$lock_fd"; then
    exec {lock_fd}<&-
    return 2
  fi
  "$@" || status=$?
  exec {lock_fd}<&-
  return "$status"
}

# Whether FILE needs a change in MODE (0 when it does).
# A stack the render cannot carry over counts as needing a change, so the
# caller's pam_stack_place fails with 2 rather than pass it by.
pam_stack_needed() {
  local file=$1 mode=$2 line=$3 new
  new=$(pam_stack_render "$file" "$mode" "$line" 2>/dev/null) || return 0
  [[ $new != "$(<"$file")" ]]
}

pam_stack_place_locked() {
  local file=$1 mode=$2 line=$3 old new
  old=$(<"$file")
  new=$(pam_stack_render "$file" "$mode" "$line" 2>/dev/null) || return 2
  [[ $new != "$old" ]] || return 1
  pam_stack_landed "$mode" "$line" "$old" "$new" "$file" || return 2
  pam_stack_write "$file" "$new" || return 2
}

# Put LINE (face mode) or our key line (fido2 mode) in place in FILE, or
# take every key line (unfido2 mode) or every face line (unface mode) out.
# Returns 1 when the file needed no change, and 2, with the file left as it
# was, when the change did not come out as intended or could not be
# written.
pam_stack_place() {
  pam_stack_locked pam_stack_place_locked "$@"
}

# Create FILE as CONTENT, under the lock, unless it exists by then; when it
# does, put LINE in place in it as pam_stack_place would (MODE and LINE as
# there). Returns 0 for a file created, and pam_stack_place's codes
# otherwise.
pam_stack_create_locked() {
  local file=$1 content=$2 mode=$3 line=$4
  if [[ -f $file ]]; then
    pam_stack_place_locked "$file" "$mode" "$line"
    return
  fi
  pam_stack_write "$file" "$content" || return 2
}

pam_stack_create() {
  pam_stack_locked pam_stack_create_locked "$@"
}

# Remove FILE, under the lock. Returns 1 when there was nothing to remove.
pam_stack_remove_locked() {
  [[ -e $1 || -L $1 ]] || return 1
  sudo rm -f -- "$1" || return 2
}

pam_stack_remove() {
  pam_stack_locked pam_stack_remove_locked "$@"
}

# The lock screen's key lane, omarchy-lock-fido2 (shell/plugins/lock/
# Service.qml): the face daemon's own key check, through pam_faceauth's
# key-unlock line, closed by pam_deny like the face lane, and never a
# pam_u2f line. The daemon asks the key, on the policy of sudo's key line
# and never for a PIN, only while the session is locked, and from the lock
# screen's first ask until it sees the unlock keeps the face window and the
# stacks' key lines off the key, so a touch while locked can only unlock.
# The lock screen shows the lane only when the daemon says it is there.
pam_stack_key_lane_stack='#%PAM-1.0
auth       sufficient                  pam_faceauth.so socket=/run/faceauth/sock key-unlock
auth       required                    pam_deny.so
account    include                     system-local-login'

# Write the key lane LANE when face is set up (its lock lane FACE is there)
# and the key goes through the daemon: SUDO, sudo's stack, has our
# key-fallback line, and neither it nor POLKIT has any pam_u2f line, which
# would read the key outside the daemon. Remove it otherwise. Returns 0 for
# a change, 1 for none, 2 for a failure.
pam_stack_key_lane_locked() {
  local lane=$1 face=$2 sudo_stack=$3 polkit_stack=$4
  if [[ -f $face && -f $sudo_stack ]] &&
    grep -qE '^[^#]*pam_faceauth\.so.*[[:space:]]key-fallback([[:space:]]|$)' "$sudo_stack" &&
    ! grep -qE '^[^#]*pam_u2f\.so' "$sudo_stack" &&
    ! { [[ -f $polkit_stack ]] && grep -qE '^[^#]*pam_u2f\.so' "$polkit_stack"; }; then
    [[ -f $lane && ! -L $lane && $(<"$lane") == "$pam_stack_key_lane_stack" ]] && return 1
    pam_stack_write "$lane" "$pam_stack_key_lane_stack" || return 2
    return 0
  fi
  pam_stack_remove_locked "$lane"
}

pam_stack_key_lane() {
  pam_stack_locked pam_stack_key_lane_locked "$@"
}

# What FILE's key line asks of the key beyond Omarchy's own line, as the
# words to add to it (`pinverification=` and `userverification=`, each as
# the line has it, =0 or =1, or not at all). The key line is our
# key-fallback line while face is set up, else the pam_u2f line, and there
# must be exactly one of them and no pam_u2f line beside a key-fallback
# line. Fails, with the reason on stdout, for no key line, more than one,
# or one the scripts cannot carry: the same policy the daemon reads
# (faceauth doctor's key rows).
pam_stack_u2f_extras() {
  awk "$pam_stack_awk_lib"'
    is_fb($0) { fbs++; fl = $0 }
    on($0, "pam_u2f") { u2fs++; ul = $0 }
    END {
      if (fbs && u2fs) { print "a pam_u2f line beside the key-fallback line"; exit 1 }
      if (fbs + u2fs != 1) { print (fbs + u2fs ? "more than one key line" : "no FIDO2 line"); exit 1 }
      o = fbs ? fb_opts(fl) : u2f_opts(ul)
      if (o == "-") { l = fbs ? fl : ul; print "a key line it cannot carry (" act(l) ")"; exit 1 }
      sub(/^cue ?/, "", o)
      print o
    }
  ' "$1"
}
