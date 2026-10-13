function promptLooksFingerprint(text) {
  var s = String(text || "").toLowerCase()
  return s.indexOf("finger") !== -1 || s.indexOf("fprint") !== -1 || s.indexOf("swipe") !== -1
}

function fingerprintConfiguredFromPamConfig(raw) {
  // Fingerprint is available whenever pam_fprintd appears anywhere in the auth
  // stack — it need not be the first module. A clamshell gate (pam_exec) may
  // legitimately precede it to skip fingerprint while the lid is closed.
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^\s+|\s+$/g, "")
    if (!line || line.charAt(0) === "#") continue
    if (!line.match(/^auth\s+/)) continue
    if (line.indexOf("pam_fprintd.so") !== -1) return true
  }
  return false
}

function faceConsentConfiguredFromPamConfig(raw) {
  // With pam_faceauth in consent mode, the face daemon opens its own consent
  // window (omarchy.faceauth) as soon as polkit starts the PAM conversation.
  // The agent dialog would sit on top of it with exclusive keyboard focus, so
  // it stays hidden until PAM actually asks for a password.
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^\s+|\s+$/g, "")
    if (!line || line.charAt(0) === "#") continue
    if (!line.match(/^auth\s+/)) continue
    if (line.indexOf("pam_faceauth.so") !== -1 && line.match(/(^|\s)consent(\s|$)/)) return true
  }
  return false
}

function authorizationLabel(message, tr) {
  var t = typeof tr === "function" ? tr : function(key, english) { return english }
  var text = String(message || "")
  var match = text.match(/^Authentication is (?:needed|required) to run [`']([^`']+)[`'] as /i)
  return match ? t("polkit.authorizeRunning", "Authorize running '%1'").replace("%1", match[1]) : text
}

// The question pam_faceauth puts to this agent through polkit's own helper
// for the cookie of the request the helper serves; the face daemon matches
// the request to its context by that cookie alone. Exactly this text.
var FACEAUTH_COOKIE_PROMPT = "faceauth: polkit request cookie"

function isFaceauthCookiePrompt(prompt) {
  return typeof prompt === "string" && prompt === FACEAUTH_COOKIE_PROMPT
}

// The answer to that question: the cookie behind this tag, which the
// module requires, so nothing typed into a prompt shown by mistake is ever
// taken for a cookie. The tag alone when there is no cookie.
var FACEAUTH_COOKIE_TAG = "faceauth-cookie "

function faceauthCookieAnswer(cookie) {
  return FACEAUTH_COOKIE_TAG + String(cookie || "")
}

if (typeof module !== "undefined") {
  module.exports = {
    promptLooksFingerprint: promptLooksFingerprint,
    fingerprintConfiguredFromPamConfig: fingerprintConfiguredFromPamConfig,
    faceConsentConfiguredFromPamConfig: faceConsentConfiguredFromPamConfig,
    authorizationLabel: authorizationLabel,
    isFaceauthCookiePrompt: isFaceauthCookiePrompt,
    faceauthCookieAnswer: faceauthCookieAnswer,
    FACEAUTH_COOKIE_PROMPT: FACEAUTH_COOKIE_PROMPT
  }
}
