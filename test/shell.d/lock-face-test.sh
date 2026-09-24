#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Face authentication on the lock screen drives the IR camera and its
# illuminator while a scan is armed. These guard the rules that keep it from
# running all night: a blank panel stops scanning and only probes, a probe
# wakes a blank panel for an attentive face only, the face PAM stack never
# holds the blank timer, and "configured" is the presence of the PAM service
# that setup writes last.

run_node_test <<'JS'
const fs = require('fs')
const serviceQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/Service.qml'), 'utf8')
const viewQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/LockView.qml'), 'utf8')

assert(
  /PamContext \{\s*id: facePam\s*config: "omarchy-lock-face"/.test(serviceQml),
  'the face stack is its own PAM service, omarchy-lock-face'
)

assert(
  /FileView \{\s*path: "\/etc\/pam\.d\/omarchy-lock-face"[\s\S]*?onLoaded: root\.faceConfigured = true[\s\S]*?onLoadFailed: root\.faceConfigured = false/.test(serviceQml),
  'face authentication counts as configured only while the PAM service setup writes exists'
)

// A blank panel means nobody is in front of the camera: the scan stops.
assert(
  /function runBlank\(\) \{[\s\S]*?faceRetryTimer\.stop\(\)\s*faceAuthenticating = false\s*if \(facePam\.active\) facePam\.abort\(\)/.test(serviceQml),
  'blanking the panel stops the face scan and aborts an attempt in flight'
)

assert(
  /function startFace\(\) \{[\s\S]*?if \(displaysBlank \|\| faceProbeMode\) return/.test(serviceQml),
  'no scan starts while the panel is blank or the loop is in probe mode'
)

// While blank, the daemon is asked for one short look at a time, and only an
// attentive face wakes the panel; a face merely in view leaves it dark.
assert(
  /id: faceProbeTimer[\s\S]*?running: root\.lockRequested && \(root\.displaysBlank \|\| root\.faceProbeMode\) && root\.faceConfigured && !root\.previewVisible/.test(serviceQml),
  'the probe runs only while locked with the panel blank or the loop in probe mode'
)

assert(
  /if \(present && \(attentive \|\| !root\.displaysBlank\)\) \{[\s\S]*?if \(root\.displaysBlank\) root\.runWake\(\)/.test(serviceQml),
  'a blank panel wakes for an attentive face only'
)

// Three misses with the panel lit means nobody is there: stop scanning and
// let the probe watch for a return instead of running the camera.
assert(
  /if \(faceFailures >= 3\) \{\s*faceProbeMode = true/.test(serviceQml),
  'repeated misses with the panel lit hand over to the probe'
)

// The blank timer is held only by a password check, never by the face scan
// (the same rule the fingerprint stack follows).
assert(
  /if \(root\.lockRequested && !root\.authenticatingPassword\) root\.runBlank\(\)/.test(serviceQml),
  'the blank timer is not gated on the face scan'
)

assert(
  /readonly property string faceState: !faceConfigured \? "" : \(faceAuthenticating \? "scanning" : \(displaysBlank \? "probing" : "idle"\)\)/.test(serviceQml),
  'the view is told scanning, probing or idle'
)

assert(
  /id: faceIcon[\s\S]*?visible: root\.faceConfigured/.test(viewQml),
  'the face indicator shows only when face authentication is configured'
)

// The daemon can answer at once (a cooldown hold, a busy camera): a scan
// that finishes in twenty milliseconds must not start the next one at once.
const startFace = serviceQml.match(/function startFace\(\) \{([\s\S]*?)\n  \}/)
assert(startFace, 'startFace exists')
assert(
  /if \(Date\.now\(\) - lastFaceStartAt < 1000\) \{\s*faceRetryTimer\.restart\(\)\s*return\s*\}/.test(startFace[1]),
  'no face scan starts within a second of the last; the retry timer spaces it'
)
assert(startFace[1].indexOf('lastFaceStartAt = Date.now()') > startFace[1].indexOf('< 1000'), 'the start time is stamped after the guard')
// The unlock boundary. A face attempt opens the screen on exactly one
// outcome, PamResult.Success, judged in handleFaceFinished and nowhere else.
// The regexes above would stay green with the condition loosened or with
// onError unlocking, so these read the two bodies and count.
function bodyOf(source, opener, description) {
  const start = source.indexOf(opener)
  assert(start !== -1, description + ' exists')
  let depth = 0
  let i = source.indexOf('{', start)
  for (; i < source.length; i++) {
    if (source[i] === '{') depth += 1
    if (source[i] === '}') { depth -= 1; if (depth === 0) break }
  }
  return source.slice(start, i + 1)
}

const faceFinished = bodyOf(serviceQml, 'function handleFaceFinished(result)', 'handleFaceFinished')
const faceUnlocks = faceFinished.match(/finishUnlock\(\)/g) || []
assertEqual(faceUnlocks.length, 1, 'handleFaceFinished unlocks from one place')
assert(
  /if \(result === PamResult\.Success\) \{\s*finishUnlock\(\)\s*\}/.test(faceFinished),
  'the face lane unlocks only on result === PamResult.Success'
)
assert(
  !/(!==|!=)\s*PamResult/.test(faceFinished.replace(/logFaceEvent\([^\n]*\)/g, '')),
  'the unlock condition is a positive match on Success, not the absence of an error'
)

const facePamBlock = bodyOf(serviceQml, 'PamContext {\n    id: facePam', 'the facePam context')
assert(facePamBlock.indexOf('finishUnlock') === -1, 'the facePam handlers never unlock directly')
const faceCompleted = bodyOf(facePamBlock, 'onCompleted: function(result)', 'facePam.onCompleted')
assert(
  /^onCompleted: function\(result\) \{\s*root\.handleFaceFinished\(result\)\s*\}$/.test(faceCompleted),
  'facePam.onCompleted only hands the result to handleFaceFinished'
)
const faceError = bodyOf(facePamBlock, 'onError: function(error)', 'facePam.onError')
assert(
  faceError.indexOf('handleFaceFinished') === -1 && faceError.indexOf('PamResult.Success') === -1,
  'facePam.onError neither unlocks nor forges a Success result'
)

// `lock status` answers any process of this uid. The face lane logs to the
// console only, so the probe verdict (owner present, owner looking) never
// reaches lastEvent and the IPC reports nothing beyond `authenticating`.
assert(!/logEvent\("face/.test(serviceQml), 'no face event is written to lastEvent')
const logFace = bodyOf(serviceQml, 'function logFaceEvent(event)', 'logFaceEvent')
assert(logFace.indexOf('lastEvent') === -1, 'logFaceEvent leaves lastEvent and lastEventAt alone')
const status = bodyOf(serviceQml, 'function status(): string', 'the status IPC')
assert(!/face-probe|face-state|faceState|faceProbe|faceAuthenticating|faceFailures/.test(status),
  'lock status carries no face-probe or face-state detail')
assert(/authenticating: root\.authenticating/.test(status), 'lock status keeps the coarse authenticating flag')

// `lock lockPresence` keeps the panel lit for ten minutes, and a lit panel
// runs the scan loop. Any process of this uid can call it, so one lock gets
// one lit window: a repeat leaves the blank timer alone.
const lockPresence = bodyOf(serviceQml, 'function lockPresence(): string', 'the lockPresence IPC')
assert(
  /if \(root\.locked\) \{\s*if \(root\.presenceLitUsed\) return "ok"\s*root\.presenceLitUsed = true\s*root\.blankDelayMs = root\.blankDelayPresenceMs/.test(lockPresence),
  'a repeated lockPresence on a lock that already had its lit window does not extend it'
)
assert(
  (lockPresence.match(/root\.presenceLitUsed = true/g) || []).length === 2 &&
    lockPresence.indexOf('root.presenceLitUsed = true') < lockPresence.indexOf('root.blankDelayMs = root.blankDelayPresenceMs'),
  'the lit window is spent before it is granted, on both the locked and the locking path'
)
const beginLock = bodyOf(serviceQml, 'function beginLock()', 'beginLock')
const finishUnlock = bodyOf(serviceQml, 'function finishUnlock()', 'finishUnlock')
assert(
  beginLock.indexOf('presenceLitUsed = false') !== -1 && finishUnlock.indexOf('presenceLitUsed = false') !== -1,
  'the lit window is granted again only with a new lock'
)
JS
