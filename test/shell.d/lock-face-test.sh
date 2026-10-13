#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Face authentication on the lock screen drives the IR camera and its
# illuminator. These guard the cascade that keeps it cheap: a short probe on a
# cadence set by the power state, dark panel or lit, and a full scan only for a
# face near enough to judge, likely the owner's and turned to the screen, or
# at once for a hands-on wake. A miss goes back to the probe, the face PAM stack never holds the blank
# timer, and "configured" is the presence of the PAM service that setup writes
# last.

run_node_test <<'JS'
const fs = require('fs')
const serviceQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/Service.qml'), 'utf8')
const viewQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/LockView.qml'), 'utf8')
const model = requireFromRoot('shell/plugins/lock/LockFaceModel.js')

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

// The lock's face flows run from the real Service.qml function bodies,
// executed against stand-ins for its timers, processes and PAM contexts.
function blockOf(source, opener) {
  const start = source.indexOf(opener)
  if (start === -1) return ''
  let depth = 0
  let i = source.indexOf('{', start)
  for (; i < source.length; i++) {
    if (source[i] === '{') depth += 1
    if (source[i] === '}') { depth -= 1; if (depth === 0) break }
  }
  return source.slice(start, i + 1)
}

function compileIn(scopes, code) {
  const names = scopes.map((_, i) => 's' + i)
  const opened = names.map(n => 'with (' + n + ') {').join(' ')
  const closed = names.map(() => '}').join(' ')
  return new Function(...names, opened + ' return (' + code + ') ' + closed)(...scopes)
}

function lockHarness() {
  const calls = { faceStart: 0, faceAbort: 0, wake: 0, blank: 0, probe: 0, retry: 0, arm: 0 }
  const clock = { now: 1000000 }
  const scope = {
    lockRequested: false, pendingSessionLock: false, authenticatingPassword: false,
    fingerprintAuthenticating: false, faceAuthenticating: false, passwordPamConfigured: true,
    fingerprintConfigured: false, faceConfigured: true, faceauthDown: false, previewVisible: false,
    enteredPassword: '', pendingPassword: '', failureMessage: '', failedAttempts: 0,
    displaysBlank: false, monitorDpmsKnown: false, lastFaceStartAt: 0,
    blankDelayDefaultMs: 5000, blankDelayPresenceMs: 600000, blankDelayMs: 5000, presenceLitUsed: false,
    faceCadence: model.defaultCadence(),
    events: [],
    sessionLock: { locked: false, secure: false },
    facePam: { active: false, start() { calls.faceStart += 1; return true }, abort() { calls.faceAbort += 1 } },
    passwordPam: { active: false, abort() {} },
    fingerprintPam: { active: false, abort() {} },
    fido2Configured: false, fido2Available: false, keyUnlockAvailable: false, fido2Authenticating: false,
    fido2Pam: { active: false, start() { return true }, abort() {} },
    fido2RetryTimer: { running: false, restart() {}, stop() {} },
    faceRetryTimer: { running: false, restart() { this.running = true; calls.retry += 1 }, stop() { this.running = false } },
    fingerprintRetryTimer: { running: false, restart() {}, stop() {} },
    fingerprintRecheckTimer: { running: false, restart() {}, stop() {} },
    fingerprintReachTimer: { running: false, restart() {}, stop() {} },
    fingerprintResumeTimer: { running: false, restart() {}, stop() {} },
    sessionLockStabilizeTimer: { stop() {} },
    pendingSessionLockTimer: { stop() {} },
    idleBlankTimer: { interval: 5000, armedAt: 0, running: false, restart() { this.running = true; calls.arm += 1 }, stop() { this.running = false } },
    wakeProcess: { get running() { return false }, set running(v) { if (v) calls.wake += 1 } },
    blankProcess: { get running() { return false }, set running(v) { if (v) calls.blank += 1 } },
    faceProbeProc: { get running() { return false }, set running(v) { if (v) calls.probe += 1 } },
    PamResult: { Success: 0, Failed: 7 },
    Date: { now: () => clock.now },
    Qt: { callLater() {} },
    LockFaceModel: model,
    UPower: { onBattery: false },
    batteryService: { activePowerProfile: '' },
    logEvent(e) { scope.events.push(e) },
    logFaceEvent(e) { scope.events.push(e) },
    queueSessionLock() {},
    queryKeyLane() {},
    openLockChannel() {},
    closeLockChannel() {},
    refreshBackground() {},
    refreshFingerprintStatus() {},
    nudgeFingerprint() {},
    resumeFingerprint() {},
    pauseFingerprint() {},
    noteSleepRequested() {}
  }
  scope.root = scope
  for (const name of ['locked', 'powerProfile', 'faceProbeSeconds']) {
    const m = serviceQml.match(new RegExp('readonly property \\w+ ' + name + ': (.*)$', 'm'))
    if (m) Object.defineProperty(scope, name, { get: () => compileIn([scope], m[1]) })
  }
  const functions = ['currentlyLocked', 'resetAuthenticationState', 'beginLock', 'finishUnlock', 'armBlankTimer', 'runWake', 'runBlank',
    'startFingerprint', 'startFido2', 'startFace', 'handleFaceFinished', 'handleProbeReply', 'probeFace', 'lock', 'lockPresence']
  for (const name of functions) {
    const text = blockOf(serviceQml, 'function ' + name + '(')
    if (text) scope[name] = compileIn([scope], text.replace(/^function (\w+)\(([^)]*)\)(: \w+)? \{/, 'function $1($2) {'))
  }
  const probeTimer = blockOf(serviceQml, 'Timer {\n    id: faceProbeTimer')
  const probeRunning = probeTimer.match(/running: (.*)$/m)[1]
  const probeInterval = probeTimer.match(/interval: (.*)$/m)[1]
  const secureHandler = blockOf(serviceQml, 'onSecureStateChanged: {').replace(/^onSecureStateChanged: \{/, 'function() {')
  const blankHandler = blockOf(blockOf(serviceQml, 'id: idleBlankTimer'), 'onTriggered: {').replace(/^onTriggered: \{/, 'function() {')
  return {
    scope, calls, clock,
    probeRunning: () => compileIn([scope], probeRunning),
    probeInterval: () => compileIn([scope], probeInterval),
    goSecure: () => { scope.sessionLock.secure = true; compileIn([scope, scope.sessionLock], secureHandler)() },
    blankTimerFires: () => compileIn([scope, scope.idleBlankTimer], blankHandler)()
  }
}

// A locked, secure session with the panel dark or lit and nothing running.
function lockedHarness(dark) {
  const h = lockHarness()
  if (h.scope.lock() !== 'ok') fail('the harness locks through the lock IPC')
  h.goSecure()
  h.scope.displaysBlank = dark
  h.calls.probe = 0
  return h
}

function reply(fields) {
  return JSON.stringify(Object.assign({ result: 'probe', face: true, attentive: true, face_px: 58.0, scannable: true, likely: true, elapsed_ms: 310 }, fields))
}

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
  /function startFace\(\) \{[\s\S]*?if \(displaysBlank\) return/.test(serviceQml),
  'no scan starts while the panel is blank'
)

// The probe runs while locked, dark panel or lit, and stops while a scan runs;
// QML restarts a Timer when `running` turns true, so the look after a scan is
// a full cadence away.
assert(
  /id: faceProbeTimer[\s\S]*?running: root\.lockRequested && root\.faceConfigured && !root\.faceauthDown && !root\.previewVisible && !root\.faceAuthenticating/.test(serviceQml),
  'the probe runs while locked, dark panel or lit, and pauses while a scan runs or faceauth is not running'
)
assert(!/id: faceProbeTimer[^}]*triggeredOnStart/.test(serviceQml), 'the probe does not look again the moment a scan ends')
assert(/onExited: root\.handleProbeReply\(faceProbeStdout\.text\)/.test(serviceQml), 'every probe reply goes through handleProbeReply')
assert(
  !/faceFailures|faceProbeMode|faceNeedsReturn|faceFailedPx|faceLastProbePx/.test(serviceQml),
  'the three-miss rule and its come-closer wait are gone; the probe verdict replaces them'
)

assert(
  /if \(root\.faceAuthenticating \|\| faceRetryTimer\.running\) \{\s*root\.armBlankTimer\(\)\s*return\s*\}/.test(serviceQml),
  'the panel does not blank under a face attempt or a start waiting out its second'
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

// The probe reply: a face, near enough to judge, likely the owner's and
// turned to the screen. An older daemon without `scannable`, `likely` or
// `attentive` answers as before, and a reply that does not parse, or an
// error, is no face. Turned away matters: the owner working at another
// screen beside this one reads as likely, and a full scan of that pose
// misses, so without it the lane would scan every few seconds.
assertEqual(model.probeAction(model.parseProbe(reply({ face: false, scannable: false, likely: false }))), 'no-face', 'a probe with no face does nothing')
assertEqual(model.probeAction(model.parseProbe(reply({ likely: false }))), 'not-likely', 'a face that is not likely the owner\'s does nothing')
assertEqual(model.probeAction(model.parseProbe(reply({ scannable: false, face_px: 32.0 }))), 'not-scannable', 'a likely face too far to judge does nothing')
assertEqual(model.probeAction(model.parseProbe(reply({ attentive: false }))), 'not-attentive', 'a likely face turned away from the screen does nothing')
assertEqual(model.probeAction(model.parseProbe(reply({ likely: false, attentive: false }))), 'not-likely', 'the verdict reads face, then scannable, then likely, then attentive')
assertEqual(model.probeAction(model.parseProbe(reply({}))), 'scan', 'a near, likely face turned to the screen starts the full scan')
assertEqual(model.probeAction(model.parseProbe('{"result":"probe","face":true,"attentive":true,"face_px":58.0,"scannable":true,"elapsed_ms":300}')), 'scan', 'a reply without `likely` reads as likely, as an older daemon answers')
assertEqual(model.probeAction(model.parseProbe('{"result":"probe","face":true,"face_px":58.0,"scannable":true,"likely":true,"elapsed_ms":300}')), 'scan', 'a reply without `attentive` reads as turned to the screen')
assertEqual(model.probeAction(model.parseProbe(reply({ likely: 'yes' }))), 'not-likely', 'a `likely` that is present but not true reads as unlikely')
assertEqual(model.probeAction(model.parseProbe(reply({ attentive: 'yes' }))), 'not-attentive', 'an `attentive` that is present but not true reads as turned away')
assertEqual(model.probeAction(model.parseProbe('')), 'no-face', 'an empty probe reply is no face')
assertEqual(model.probeAction(model.parseProbe('{"result":"error","message":"camera busy"}')), 'no-face', 'an error reply is no face')

// The cadence: `ac` on mains in every profile; on battery the active
// profile's entry, `balanced` for an unknown or empty one; the shipped table
// until a reply brings one.
const shipped = model.defaultCadence()
assertDeepEqual(shipped, { ac: 2.0, performance: 3.0, balanced: 5.0, 'power-saver': 8.0 }, 'the shipped cadence is 2 s on AC, and 3, 5 and 8 s on battery')
for (const profile of ['performance', 'balanced', 'power-saver', '']) {
  assertEqual(model.cadenceSeconds(shipped, false, profile), 2.0, 'on AC the probe runs every 2 s with the ' + (profile || 'unknown') + ' profile')
}
assertEqual(model.cadenceSeconds(shipped, true, 'performance'), 3.0, 'on battery in performance the probe runs every 3 s')
assertEqual(model.cadenceSeconds(shipped, true, 'balanced'), 5.0, 'on battery in balanced the probe runs every 5 s')
assertEqual(model.cadenceSeconds(shipped, true, 'power-saver'), 8.0, 'on battery in power saver the probe runs every 8 s')
assertEqual(model.cadenceSeconds(shipped, true, ''), 5.0, 'on battery with no profile read the balanced entry applies')
assertEqual(model.cadenceSeconds(shipped, true, 'custom'), 5.0, 'on battery with an unknown profile the balanced entry applies')
assertEqual(model.cadenceSeconds(null, true, 'power-saver'), 8.0, 'without a table the shipped one applies')
assertEqual(model.parseProbe(reply({})).cadence, null, 'a reply without `cadence` brings no table')
assertDeepEqual(
  model.parseProbe(reply({ cadence: { ac: 1.5, performance: 2.5, balanced: 4, 'power-saver': 12 } })).cadence,
  { ac: 1.5, performance: 2.5, balanced: 4, 'power-saver': 12 },
  'a reply\'s cadence table is read as sent'
)
assertDeepEqual(
  model.parseProbe(reply({ cadence: { ac: 0.2, balanced: -1, 'power-saver': 'soon' } })).cadence,
  { ac: 1.0, performance: 3.0, balanced: 5.0, 'power-saver': 8.0 },
  'a table entry that is missing or not a positive number keeps the shipped value, and none probes more than once a second'
)

// The cascade on the real Service.qml functions. The lock starts with a
// look, not a scan.
let h = lockHarness()
h.scope.lock()
h.goSecure()
assert(h.calls.probe === 1 && h.calls.faceStart === 0, 'a lock turning secure takes one look and starts no scan', JSON.stringify(h.calls))

// Dark panel: nothing but a near, likely face wakes it, and the wake scans.
for (const [label, text] of [
  ['no face', reply({ face: false, scannable: false, likely: false, face_px: 0 })],
  ['a face that is not likely', reply({ likely: false })],
  ['a likely face too far to judge', reply({ scannable: false, face_px: 32.0 })],
  ['a likely face turned away', reply({ attentive: false })],
  ['an error reply', '{"result":"error","message":"camera busy"}']
]) {
  h = lockedHarness(true)
  h.scope.handleProbeReply(text)
  assert(h.calls.wake === 0 && h.calls.faceStart === 0 && h.scope.displaysBlank, 'on a dark panel ' + label + ' wakes nothing and scans nothing', JSON.stringify(h.calls))
}
h = lockedHarness(true)
h.scope.handleProbeReply(reply({}))
assert(h.calls.wake === 1 && !h.scope.displaysBlank, 'a near, likely face turned to the screen wakes a dark panel', JSON.stringify(h.calls))
assert(h.calls.faceStart === 1 && h.scope.faceAuthenticating, 'and the wake starts the full scan', JSON.stringify(h.calls))

// Lit panel: the same verdict, without a wake.
h = lockedHarness(false)
h.scope.handleProbeReply(reply({ likely: false }))
assertEqual(h.calls.faceStart, 0, 'on a lit panel a face that is not likely starts no scan')
h.scope.handleProbeReply(reply({ attentive: false }))
assertEqual(h.calls.faceStart, 0, 'on a lit panel a likely face turned away starts no scan')
h.scope.handleProbeReply('{"result":"probe","face":true,"attentive":true,"face_px":58.0,"scannable":true,"elapsed_ms":300}')
assert(h.calls.faceStart === 1 && h.calls.wake === 0, 'on a lit panel a likely face scans, and a reply without `likely` counts as likely', JSON.stringify(h.calls))

// A scan in flight pauses the probe and ignores a late reply. A miss hands
// back to the probe with no rescan and no immediate look.
assertEqual(h.probeRunning(), false, 'the probe pauses while a scan runs')
h.clock.now += 5000
h.scope.handleProbeReply(reply({}))
assertEqual(h.calls.faceStart, 1, 'a probe reply that lands during a scan starts nothing')
h.scope.handleFaceFinished(h.scope.PamResult.Failed)
assert(
  h.calls.faceStart === 1 && !h.scope.faceRetryTimer.running && h.calls.probe === 0 && !h.scope.faceAuthenticating,
  'a full-scan miss starts no rescan, queues none and takes no look at once',
  JSON.stringify(h.calls)
)
assertEqual(h.probeRunning(), true, 'after a miss the probe runs again on its cadence')
h.scope.handleFaceFinished(h.scope.PamResult.Success)
assertEqual(h.scope.lockRequested, false, 'a full-scan success unlocks')

// Hands-on: a key, a click or a move wakes the panel and scans at once,
// whatever the probe last said, a second after the last start at the soonest.
assert(/onWakeRequested: root\.runWake\(\)/.test(serviceQml), 'the lock view\'s wake request runs runWake')
assert(
  /onClicked: \{ root\.wakeRequested\(\)/.test(viewQml) && /onPositionChanged: function\(mouse\) \{ if \(pointerGate\.moved\(wakeArea, mouse\)\) root\.wakeRequested\(\) \}/.test(viewQml) && /Keys\.onPressed: function\(event\) \{\s*root\.wakeRequested\(\)/.test(viewQml),
  'a click, a key press and a mouse move past the pointer gate on the lock view ask for a wake'
)
h = lockedHarness(true)
h.scope.handleProbeReply(reply({ likely: false }))
h.scope.handleProbeReply(reply({ attentive: false }))
h.scope.runWake()
assert(h.calls.wake === 1 && h.calls.faceStart === 1, 'a hands-on wake scans at once, even after an unlikely probe and a turned-away one', JSON.stringify(h.calls))
h.scope.handleFaceFinished(h.scope.PamResult.Failed)
h.clock.now += 400
h.scope.runWake()
assert(h.calls.faceStart === 1 && h.scope.faceRetryTimer.running, 'a hands-on wake within a second of the last start waits out the second', JSON.stringify(h.calls))
h.clock.now += 1000
h.scope.faceRetryTimer.running = false
h.scope.startFace()
assertEqual(h.calls.faceStart, 2, 'and then scans')

// A lock surface that maps under a pointer already resting there gets one
// position sample nobody made. The view runs it through Omarchy's pointer
// gate, so that sample wakes nothing and starts no scan; real movement does.
const gateQml = fs.readFileSync(path.join(root, 'shell/Ui/PointerMoveGate.qml'), 'utf8')
assert(/PointerMoveGate \{\s*id: pointerGate\s*referenceItem: root\s*\}/.test(viewQml), 'the lock view keeps a pointer gate on its own coordinates')
assert(/onInputEnabledChanged: \{[^}]*pointerGate\.reset\(\)/.test(viewQml), 'the gate re-arms when the view takes input for a new lock')
function lockViewPointer(h) {
  const gate = {}
  for (const m of gateQml.matchAll(/^  property \w+ (\w+): (.+)$/gm)) gate[m[1]] = compileIn([{}], m[2])
  gate.root = gate
  for (const name of ['reset', 'allowInitialSample', 'moved']) gate[name] = compileIn([gate], blockOf(gateQml, 'function ' + name + '('))
  const wakeArea = { mapToItem: (target, x, y) => ({ x: x, y: y }) }
  const view = { wakeRequested: () => h.scope.runWake() }
  const handler = viewQml.match(/onPositionChanged: (function\(mouse\) \{.*\})$/m)[1]
  const onPositionChanged = compileIn([{ pointerGate: gate, wakeArea: wakeArea, root: view }], handler)
  return (x, y) => onPositionChanged({ x: x, y: y })
}
h = lockedHarness(false)
let pointerAt = lockViewPointer(h)
pointerAt(700, 420)
assert(h.calls.faceStart === 0 && h.calls.wake === 0, 'a fresh lock under a resting pointer starts no scan', JSON.stringify(h.calls))
pointerAt(701, 420)
assertEqual(h.calls.faceStart, 0, 'nor does a one-pixel jitter')
pointerAt(730, 440)
assert(h.calls.faceStart === 1 && h.calls.wake === 1, 'a real move after it wakes and scans at once', JSON.stringify(h.calls))
h = lockedHarness(true)
pointerAt = lockViewPointer(h)
pointerAt(700, 420)
assert(h.scope.displaysBlank && h.calls.faceStart === 0, 'a dark panel stays dark for the pointer it mapped under', JSON.stringify(h.calls))
pointerAt(740, 400)
assert(!h.scope.displaysBlank && h.calls.faceStart === 1, 'and wakes and scans when the pointer really moves', JSON.stringify(h.calls))

// The cadence the service uses: the shipped table until a reply brings one,
// the power state read from the battery service and UPower.
assert(
  /readonly property var batteryService: shell && shell\.services \? shell\.firstPartyServiceFor\("omarchy\.battery"\) : null/.test(serviceQml) &&
    /readonly property string powerProfile: batteryService \? batteryService\.activePowerProfile : ""/.test(serviceQml) &&
    /readonly property real faceProbeSeconds: LockFaceModel\.cadenceSeconds\(faceCadence, UPower\.onBattery, powerProfile\)/.test(serviceQml),
  'the power state comes from the battery service and UPower, as the lock wallpaper reads it'
)
h = lockedHarness(false)
const intervals = []
for (const [onBattery, profile] of [[false, 'power-saver'], [true, 'performance'], [true, 'balanced'], [true, 'power-saver'], [true, '']]) {
  h.scope.UPower.onBattery = onBattery
  h.scope.batteryService.activePowerProfile = profile
  intervals.push(h.probeInterval())
}
assertDeepEqual(intervals, [2000, 3000, 5000, 8000, 5000], 'before any reply the probe runs every 2 s on AC, and 3, 5, 8 and 5 s on battery by profile')
h.scope.handleProbeReply(reply({ face: false, cadence: { ac: 1.5, performance: 2.5, balanced: 4, 'power-saver': 12 } }))
h.scope.handleProbeReply(reply({ face: false }))
h.scope.UPower.onBattery = true
h.scope.batteryService.activePowerProfile = 'power-saver'
assertEqual(h.probeInterval(), 12000, 'the daemon\'s table is used once a reply brings it, and a reply without one keeps it')
h.scope.UPower.onBattery = false
assertEqual(h.probeInterval(), 1500, 'and on AC its `ac` entry applies')

// The unlock boundary. A face attempt opens the screen on exactly one
// outcome, PamResult.Success, judged in handleFaceFinished and nowhere else.
// The regexes above would stay green with the condition loosened or with
// onError unlocking, so these read the two bodies and count.
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
const probeReply = bodyOf(serviceQml, 'function handleProbeReply(text)', 'handleProbeReply')
assert(probeReply.indexOf('finishUnlock') === -1 && probeReply.indexOf('PamResult') === -1, 'a probe reply never unlocks; it can only start a scan')

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
// console only, so the probe verdict (owner present, owner likely) never
// reaches lastEvent and the IPC reports nothing beyond `authenticating`.
assert(!/logEvent\("face/.test(serviceQml), 'no face event is written to lastEvent')
const logFace = bodyOf(serviceQml, 'function logFaceEvent(event)', 'logFaceEvent')
assert(logFace.indexOf('lastEvent') === -1, 'logFaceEvent leaves lastEvent and lastEventAt alone')
const status = bodyOf(serviceQml, 'function status(): string', 'the status IPC')
assert(!/face-probe|face-state|faceState|faceProbe|faceAuthenticating|faceCadence/.test(status),
  'lock status carries no face-probe or face-state detail')
assert(/authenticating: root\.authenticating/.test(status), 'lock status keeps the coarse authenticating flag')

// `lock lockPresence` keeps the panel lit for ten minutes, and a lit panel
// runs the scan loop. Any process of this uid can call it, so one lock gets
// one lit window: a repeat leaves the blank timer alone.
const lockPresence = bodyOf(serviceQml, 'function lockPresence(): string', 'the lockPresence IPC')
assert(
  /if \(root\.currentlyLocked\(\)\) \{\s*if \(root\.presenceLitUsed\) return "ok"\s*root\.presenceLitUsed = true\s*root\.blankDelayMs = root\.blankDelayPresenceMs/.test(lockPresence),
  'a repeated lockPresence on a lock that already had its lit window does not extend it'
)
// A stale `locked` binding once read true after an unlock (upstream #14978), so a
// walk-away lock would have been skipped. The decision reads the state afresh.
assert(!/root\.locked\b/.test(lockPresence), 'the walk-away lock decides from currentlyLocked(), never the locked binding')
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

// The daemon's lock helper calls lockPresence and then `omarchy-system-lock`,
// whose `lock` IPC used to put the ordinary five seconds back on the lock
// already up, so the next wake cut the ten-minute window short.
h = lockHarness()
assertEqual(h.scope.lockPresence(), 'ok', 'lockPresence locks')
assertEqual(h.scope.idleBlankTimer.interval, 600000, 'a walk-away lock keeps the panel lit for ten minutes')
assertEqual(h.scope.lock(), 'ok', 'the helper\'s ordinary lock after it succeeds')
assertEqual(h.scope.blankDelayMs, 600000, 'and leaves the ten-minute window in place')
h.scope.sessionLock.secure = true
h.scope.runWake()
assertEqual(h.scope.idleBlankTimer.interval, 600000, 'a wake after both re-arms the ten-minute window, not five seconds')
h.scope.faceAuthenticating = true
h.scope.idleBlankTimer.armedAt = h.clock.now - h.scope.idleBlankTimer.interval
h.blankTimerFires()
assertEqual(h.scope.idleBlankTimer.interval, 600000, 'the blank timer\'s hold for a scan in flight re-arms the ten-minute window')
h.scope.faceAuthenticating = false
const armedBefore = h.calls.arm
h.scope.lockPresence()
assert(h.calls.arm === armedBefore && h.scope.blankDelayMs === 600000, 'a repeated lockPresence still leaves the blank timer alone', JSON.stringify(h.calls))
h.scope.finishUnlock()
h.scope.sessionLock.secure = false // the compositor ends the lock
assertEqual(h.scope.lock(), 'ok', 'a fresh ordinary lock succeeds')
assert(h.scope.blankDelayMs === 5000 && h.scope.idleBlankTimer.interval === 5000, 'and blanks after the ordinary five seconds', JSON.stringify({ delay: h.scope.blankDelayMs, interval: h.scope.idleBlankTimer.interval }))
JS
