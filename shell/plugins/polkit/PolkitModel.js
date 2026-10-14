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

// How the question pam_faceauth puts to this agent through polkit's own
// helper, for the cookie of the request the helper serves, starts; the face
// daemon matches the request to its context by that cookie alone. Exactly
// this text, then a fresh challenge for that one question.
var FACEAUTH_COOKIE_PROMPT = "faceauth: polkit cookie challenge "

function isFaceauthCookiePrompt(prompt) {
  return typeof prompt === "string" && prompt.indexOf(FACEAUTH_COOKIE_PROMPT) === 0
}

// The question's challenge: 32 lowercase hex characters after its start,
// or "" for a question without one.
function faceauthCookieChallenge(prompt) {
  if (!isFaceauthCookiePrompt(prompt)) return ""
  var challenge = prompt.slice(FACEAUTH_COOKIE_PROMPT.length)
  return /^[0-9a-f]{32}$/.test(challenge) ? challenge : ""
}

// The answer to that question: this tag, the question's challenge and the
// cookie, which the module requires, so nothing typed into a prompt shown by
// mistake is ever taken for a cookie. Nothing after the challenge when there
// is no cookie, and nothing at all, which the module takes as no answer, for
// a question without a challenge.
var FACEAUTH_COOKIE_TAG = "faceauth-cookie "

function faceauthCookieAnswer(prompt, cookie) {
  var challenge = faceauthCookieChallenge(prompt)
  if (!challenge) return ""
  return FACEAUTH_COOKIE_TAG + challenge + " " + String(cookie || "")
}

if (typeof module !== "undefined") {
  module.exports = {
    promptLooksFingerprint: promptLooksFingerprint,
    fingerprintConfiguredFromPamConfig: fingerprintConfiguredFromPamConfig,
    faceConsentConfiguredFromPamConfig: faceConsentConfiguredFromPamConfig,
    authorizationLabel: authorizationLabel,
    isFaceauthCookiePrompt: isFaceauthCookiePrompt,
    faceauthCookieChallenge: faceauthCookieChallenge,
    faceauthCookieAnswer: faceauthCookieAnswer,
    FACEAUTH_COOKIE_PROMPT: FACEAUTH_COOKIE_PROMPT
  }
}
