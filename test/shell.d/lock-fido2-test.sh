#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# A security key unlocks the lock screen on a lane of its own, beside the
# password, fingerprint and face ones: the omarchy-lock-fido2 PAM service,
# the face daemon's key-unlock line, which FIDO2 setup writes (with face set
# up) and both removals delete. The lane runs only while that service exists
# and the daemon's key_lane answer, asked without the camera, says the lane
# is there, so with the daemon down there is no lane and no hint. These run the lane's real Service.qml
# function bodies against stand-ins for its PAM context and timer: it runs
# only on a secure lock with both, a touch unlocks, anything else asks again
# after a pause, a question it cannot answer ends the attempt, and the
# unlock aborts it.

run_node_test <<'JS'
const fs = require('fs')
const serviceQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/Service.qml'), 'utf8')
const viewQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/LockView.qml'), 'utf8')
const enShell = JSON.parse(fs.readFileSync(path.join(root, 'default/i18n/en/shell.json'), 'utf8'))
const modelJs = fs.readFileSync(path.join(root, 'shell/plugins/lock/LockFaceModel.js'), 'utf8')
const LockFaceModel = new Function(modelJs + '\nreturn { parseProbe: parseProbe, parseKeyLane: parseKeyLane, probeAction: probeAction }')()

function blockOf(source, opener) {
  const start = source.indexOf(opener)
  assert(start !== -1, opener.replace(/\s+/g, ' ') + ' exists')
  let depth = 0
  let i = source.indexOf('{', start)
  for (; i < source.length; i++) {
    if (source[i] === '{') depth += 1
    if (source[i] === '}') { depth -= 1; if (depth === 0) break }
  }
  return source.slice(start, i + 1)
}

function compileIn(scope, code) {
  return new Function('s', 'with (s) { return (' + code + ') }')(scope)
}

function lane() {
  const calls = { start: 0, abort: 0, retry: 0, unlock: 0, stop: 0 }
  const scope = {
    lockRequested: true, fido2Available: true, fido2Authenticating: false,
    displaysBlank: false,
    sessionLock: { secure: true },
    PamResult: { Success: 0, Failed: 7 },
    fido2Pam: { active: false, start() { calls.start += 1; this.active = true; return true }, abort() { calls.abort += 1; this.active = false } },
    fido2RetryTimer: { running: false, restart() { this.running = true; calls.retry += 1 }, stop() { this.running = false; calls.stop += 1 } },
    finishUnlock() { calls.unlock += 1 },
  }
  for (const name of ['startFido2', 'settleFido2', 'pauseFido2']) {
    scope[name] = compileIn(scope, blockOf(serviceQml, 'function ' + name + '('))
  }
  return { scope, calls }
}

// The lane starts only on a secure lock with the service there, and once.
let { scope, calls } = lane()
scope.startFido2()
scope.startFido2()
assert(calls.start === 1 && scope.fido2Authenticating, 'a secure lock with the service starts one attempt')
for (const off of [{ lockRequested: false }, { fido2Available: false }, { sessionLock: { secure: false } }]) {
  const l = lane()
  Object.assign(l.scope, off)
  l.scope.startFido2()
  assert(l.calls.start === 0, 'no attempt without ' + JSON.stringify(off))
}

// A touch unlocks; anything else asks again after the pause, settled once.
scope.settleFido2(scope.PamResult.Success)
assert(calls.unlock === 1 && !scope.fido2Authenticating, 'a touch unlocks')
;({ scope, calls } = lane())
scope.startFido2()
scope.settleFido2(scope.PamResult.Failed)
scope.settleFido2(scope.PamResult.Failed)
assert(calls.unlock === 0 && calls.retry === 1, 'a miss asks again once, after the pause, and unlocks nothing')
const retryTimer = blockOf(serviceQml, 'Timer {\n    id: fido2RetryTimer')
assert(/interval: 2000/.test(retryTimer) && /onTriggered: root\.startFido2\(\)/.test(retryTimer), 'the lane asks again two seconds after an attempt')
;({ scope, calls } = lane())
scope.fido2Pam.start = () => false
scope.startFido2()
assert(!scope.fido2Authenticating && calls.retry === 1, 'an attempt that cannot start is retried after the pause, never spun')

// Round 19 (live test 2): the key is asked only while the lock's displays
// are lit. A dark lock starts no attempt; blanking ends the one running and
// its retry, and what the end settles asks nothing again; a wake asks at
// once.
;({ scope, calls } = lane())
scope.displaysBlank = true
scope.startFido2()
assert(calls.start === 0 && !scope.fido2Authenticating, 'no attempt while the displays are dark')
;({ scope, calls } = lane())
scope.startFido2()
scope.fido2Pam.abort = function() { calls.abort += 1; this.active = false; scope.settleFido2(scope.PamResult.Failed) }
scope.displaysBlank = true
scope.pauseFido2()
assert(calls.abort === 1 && !scope.fido2Pam.active && !scope.fido2Authenticating, 'blanking ends the attempt and frees the key')
assert(!scope.fido2RetryTimer.running && calls.retry === 0, 'and nothing asks again while dark')
const blankHandler = blockOf(serviceQml, 'onDisplaysBlankChanged: {')
assert(/if \(displaysBlank\) root\.pauseFido2\(\)/.test(blankHandler) && /else root\.startFido2\(\)/.test(blankHandler), 'the displays going dark pause the key, and lighting up asks at once')
scope.displaysBlank = false
scope.startFido2()
assert(calls.start === 2 && scope.fido2Authenticating, 'a wake asks the key again')

// The PAM context: its own service, a question it cannot answer ends the
// attempt, and both ends of an attempt go through the one settle.
const pam = blockOf(serviceQml, 'PamContext {\n    id: fido2Pam')
assert(/config: "omarchy-lock-fido2"/.test(pam), 'the lane uses the omarchy-lock-fido2 service')
assert(/onResponseRequiredChanged: \{[\s\S]*abort\(\)[\s\S]*root\.settleFido2\(PamResult\.Failed\)/.test(pam), 'a prompt (a PIN) is never answered: the attempt ends')
assert(/onCompleted: function\(result\) \{\s*root\.settleFido2\(result\)/.test(pam) && /onError: function\(error\) \{\s*root\.settleFido2\(PamResult\.Failed\)/.test(pam), 'completion and error both settle the attempt')

// The service's presence is half of the lane's "available" check, the
// daemon's probe the other half, and the lane starts on a secure lock and
// stops with the unlock.
const fileView = serviceQml.split(/\bFileView \{/).slice(1).find(b => /omarchy-lock-fido2/.test(b)) || ''
assert(/path: "\/etc\/pam\.d\/omarchy-lock-fido2"/.test(fileView) && /watchChanges: true/.test(fileView), 'a FileView watches the lane\'s PAM service')
assert(/root\.fido2Configured = true/.test(fileView) && /onLoadFailed: root\.fido2Configured = false/.test(fileView), 'the service is there exactly while the file exists')
assert(/readonly property bool fido2Available: fido2Configured && keyUnlockAvailable && !faceauthDown/.test(serviceQml), 'the lane is available only with the service and the daemon\'s word, and never while faceauth is not running')

// The daemon's word comes from its key_lane answer, asked without the
// camera: a well-formed answer sets the lane, and anything else (no reply
// with the daemon down, garbage, an error) changes nothing, so a busy camera
// never takes the lane away. Once offered it stays for the whole lock; only
// the daemon's own "not available" withdraws it.
assert(LockFaceModel.parseKeyLane('{"result":"key_lane","available":true}') === true, 'an answer naming the lane')
assert(LockFaceModel.parseKeyLane('{"result":"key_lane","available":false,"reason":"a pam_u2f line"}') === false, 'the daemon withdraws it')
for (const text of ['', 'not json', '[]', '{"result":"error","message":"busy"}', '{"result":"key_lane","available":"yes"}', '{"result":"probe","face":true,"key_unlock":true}', '{"available":true}']) {
  assert(LockFaceModel.parseKeyLane(text) === null, 'nothing said by ' + JSON.stringify(text))
}
assert(!('keyUnlock' in LockFaceModel.parseProbe('{"result":"probe","face":true,"key_unlock":true}')), 'the probe no longer carries the lane')
function laneScope() {
  const scope = {
    lockRequested: true, faceConfigured: true, fido2Configured: true, keyUnlockAvailable: false, started: 0, asked: 0,
    LockFaceModel,
    keyLaneProc: { running: false },
    keyLaneRetried: false,
    Qt: { callLater() {} },
    startFido2() { scope.started += 1 },
    logEvent() {},
  }
  scope.faceauthDown = false
  scope.handleKeyLaneReply = compileIn(scope, blockOf(serviceQml, 'function handleKeyLaneReply('))
  scope.queryKeyLane = compileIn(scope, blockOf(serviceQml, 'function queryKeyLane('))
  return scope
}
const k = laneScope()
k.handleKeyLaneReply('{"result":"key_lane","available":true}')
assert(k.keyUnlockAvailable === true && k.started === 1, 'the answer turns the lane on and starts it')
for (const busy of ['', '{"result":"error","message":"busy"}', 'garbage']) {
  k.handleKeyLaneReply(busy)
  assert(k.keyUnlockAvailable === true, 'the lane survives ' + JSON.stringify(busy) + ': the daemon down mid-lock or a busy camera takes nothing away')
}
k.handleKeyLaneReply('{"result":"key_lane","available":false}')
assert(k.keyUnlockAvailable === false, 'only the daemon\'s own "not available" withdraws the lane')
// Round 5 (the hold): an answer it cannot read is asked again at once,
// once, rather than at the next two-second tick, so a dropped reply costs
// the latch no gap; a readable answer makes the next unreadable one worth
// asking again too.
function retryScope() {
  const scope = laneScope()
  scope.later = []
  scope.Qt = { callLater(f) { scope.later.push(f) } }
  scope.keyLaneRetried = false
  scope.handleKeyLaneReply = compileIn(scope, blockOf(serviceQml, 'function handleKeyLaneReply('))
  scope.queryKeyLane = compileIn(scope, blockOf(serviceQml, 'function queryKeyLane('))
  return scope
}
const r = retryScope()
r.handleKeyLaneReply('')
assert(r.later.length === 1, 'an unreadable answer is asked again at once')
r.later.shift()()
assert(r.keyLaneProc.running === true, 'the question goes out again')
r.keyLaneProc.running = false
r.handleKeyLaneReply('garbage')
assert(r.later.length === 0, 'once: a second unreadable answer waits for the tick')
r.handleKeyLaneReply('{"result":"key_lane","available":true}')
r.handleKeyLaneReply('')
assert(r.later.length === 1, 'a readable answer makes the next unreadable one worth asking again')
const down = laneScope()
down.handleKeyLaneReply('')
assert(down.keyUnlockAvailable === false && down.started === 0, 'with no readable answer from the start of the lock there is no lane and no hint')
const q = laneScope()
q.queryKeyLane()
assert(q.keyLaneProc.running === true, 'the lock screen asks')
const noFace = laneScope()
Object.assign(noFace, { faceConfigured: false, fido2Configured: false })
noFace.queryKeyLane()
assert(noFace.keyLaneProc.running === false, 'with neither face nor the lane set up it asks nothing')
const proc = blockOf(serviceQml, 'Process {\n    id: keyLaneProc')
assert(/command: \["\/usr\/bin\/faceauth", "key-lane", "--user", root\.userName\]/.test(proc) && /onExited: root\.handleKeyLaneReply\(keyLaneStdout\.text\)/.test(proc), 'the question is faceauth key-lane, no camera')
const timer = blockOf(serviceQml, 'Timer {\n    id: keyLaneTimer')
assert(/interval: 2000/.test(timer) && /running: root\.lockRequested/.test(timer) && /onTriggered: root\.queryKeyLane\(\)/.test(timer), 'it is asked every two seconds while the lock stands')
assert(/queryKeyLane\(\)\s*\n\s*queueSessionLock\(\)/.test(blockOf(serviceQml, 'function beginLock()')), 'and once before the lock is up')
assert(!/keyUnlock/.test(blockOf(serviceQml, 'function handleProbeReply(')), 'the face probe has nothing to do with the lane')
const reset = blockOf(serviceQml, 'function resetAuthenticationState()')
assert(/keyUnlockAvailable = false/.test(reset), 'each lock learns afresh whether the lane is there')
assert(/root\.startFido2\(\)/.test(blockOf(serviceQml, 'onSecureStateChanged: {')), 'a secure lock starts the lane')
assert(/fido2RetryTimer\.stop\(\)/.test(reset) && /if \(fido2Pam\.active\) fido2Pam\.abort\(\)/.test(reset) && /fido2Authenticating = false/.test(reset), 'the unlock stops the lane and frees the key')

// Round 5 (C): faceauth not running. `faceauth key-lane` answers
// not_running when the daemon's socket is missing or refuses; the lock
// screen then hides the face and key options and says why, and the next
// well-formed answer brings them back. Busy and unreadable answers keep
// today's behavior: they change nothing.
assert(LockFaceModel.parseKeyLane('{"result":"not_running"}') === 'down', 'not running is its own answer')
for (const text of ['{"result":"not_running"', '{"result":"Not_Running"}', '"not_running"', '{"result":"error","message":"not_running"}']) {
  assert(LockFaceModel.parseKeyLane(text) === null, 'not "not running": ' + JSON.stringify(text))
}
{
  const d = retryScope()
  d.handleKeyLaneReply('{"result":"key_lane","available":true}')
  assert(d.keyUnlockAvailable === true && d.faceauthDown === false, 'the lane is up')
  d.handleKeyLaneReply('{"result":"not_running"}')
  assert(d.faceauthDown === true, 'not running hides face and key')
  assert(d.keyUnlockAvailable === false, 'and takes the key lane down with it')
  assert(d.later.length === 0, 'not running is an answer, not asked again at once')
  for (const busy of ['', 'garbage', '{"result":"error","message":"busy"}']) {
    d.handleKeyLaneReply(busy)
    assert(d.faceauthDown === true, 'still not running after ' + JSON.stringify(busy) + ': busy and unreadable change nothing')
  }
  const started = d.started
  d.handleKeyLaneReply('{"result":"key_lane","available":true}')
  assert(d.faceauthDown === false && d.keyUnlockAvailable === true && d.started === started + 1, 'the next well-formed answer brings face and key back')
  d.handleKeyLaneReply('{"result":"not_running"}')
  d.handleKeyLaneReply('{"result":"key_lane","available":false}')
  assert(d.faceauthDown === false && d.keyUnlockAvailable === false, 'a well-formed "not available" brings face back without the key')
  const fresh = retryScope()
  for (const busy of ['', 'garbage', '{"result":"error","message":"busy"}']) {
    fresh.handleKeyLaneReply(busy)
    assert(fresh.faceauthDown === false, JSON.stringify(busy) + ' never reads as not running')
  }
}
assert(/faceauthDown = false/.test(reset), 'each lock learns afresh whether faceauth is running')
for (const name of ['function startFace()', 'function probeFace()']) {
  assert(/if \(!lockRequested[^\n]*\|\| faceauthDown[^\n]*\) return/.test(blockOf(serviceQml, name)), name + ' does nothing while faceauth is not running')
}
assert(/running: root\.lockRequested && root\.faceConfigured && !root\.faceauthDown/.test(blockOf(serviceQml, 'Timer {\n    id: faceProbeTimer')), 'the face probe stops while faceauth is not running')
assert((serviceQml.match(/faceConfigured: root\.faceConfigured && !root\.faceauthDown/g) || []).length === 2, 'the lock and its preview hide the face icon while faceauth is not running')
assert((serviceQml.match(/faceauthDown: root\.faceauthDown/g) || []).length === 2, 'the lock and its preview both pass the notice on')
const downNotice = viewQml.split(/\bText \{/).slice(1).find(b => /objectName: "faceauthDownNotice"/.test(b)) || ''
assert(/visible: root\.faceauthDown/.test(downNotice) && /text: Commons\.I18n\.t\("lock\.faceauthDown"\)/.test(downNotice) && enShell['lock.faceauthDown'] === "Face and key are unavailable because faceauth isn't running. Use your password." && /textFormat: Text\.PlainText/.test(downNotice), 'the lock view says face and key are unavailable while faceauth is not running')

// Round 7 (B): the lock screen's reserved channel to faceauthd. It is opened
// when the lock begins and held for the whole lock (`faceauth lock-channel`,
// a process whose stdin the lock screen keeps); the unlock writes
// "unlocked" to it, the graceful close; anything else ends it as a drop,
// which keeps the user's key approvals latched. A channel that ends while
// the lock stands (the daemon restarted) is opened again a second later.
{
  const chan = blockOf(serviceQml, 'Process {\n    id: lockChannelProc')
  assert(/command: \["\/usr\/bin\/faceauth", "lock-channel", "--user", root\.userName\]/.test(chan), 'the channel is faceauth lock-channel for the user')
  assert(/stdinEnabled: true/.test(chan) && /onExited: root\.handleLockChannelExit\(\)/.test(chan), 'its stdin is the lock screen\'s, and its end is handled')
  const retry = blockOf(serviceQml, 'Timer {\n    id: lockChannelRetryTimer')
  assert(/interval: 1000/.test(retry) && /onTriggered: root\.openLockChannel\(\)/.test(retry), 'a channel that ended while locked is opened again a second later')
  assert(/openLockChannel\(\)\s*\n\s*queryKeyLane\(\)/.test(blockOf(serviceQml, 'function beginLock()')), 'the channel opens as the lock begins')
  assert(/closeLockChannel\(\)/.test(blockOf(serviceQml, 'function finishUnlock()')), 'the unlock closes it gracefully')
  assert(/closeLockChannel\(\)/.test(blockOf(serviceQml, 'onLockStateChanged: {')), 'so does a lock that ends by other means')
  assert(!/lockChannelProc\.running\s*=\s*false/.test(serviceQml), 'nothing kills the channel: a kill is a drop')
  function chanScope() {
    const calls = { started: 0, writes: [], retries: 0, stops: 0 }
    const scope = {
      lockRequested: true, faceConfigured: true, fido2Configured: false,
      lockChannelProc: { running: false, write(t) { calls.writes.push(t) } },
      lockChannelRetryTimer: { restart() { calls.retries += 1 }, stop() { calls.stops += 1 } },
      logEvent() {},
    }
    Object.defineProperty(scope.lockChannelProc, 'running', {
      get() { return this._r || false }, set(v) { if (v && !this._r) calls.started += 1; this._r = v },
    })
    for (const name of ['openLockChannel', 'closeLockChannel', 'handleLockChannelExit']) {
      scope[name] = compileIn(scope, blockOf(serviceQml, 'function ' + name + '('))
    }
    return { scope, calls }
  }
  let c = chanScope()
  c.scope.openLockChannel()
  c.scope.openLockChannel()
  assert(c.calls.started === 1, 'one channel per lock')
  c.scope.closeLockChannel()
  assert(c.calls.writes.length === 1 && c.calls.writes[0] === 'unlocked\n', 'the graceful word, once, on its stdin')
  c = chanScope()
  c.scope.lockChannelProc.running = false
  c.scope.handleLockChannelExit()
  assert(c.calls.retries === 1, 'ended while locked: opened again')
  c = chanScope()
  c.scope.lockRequested = false
  c.scope.handleLockChannelExit()
  c.scope.openLockChannel()
  assert(c.calls.retries === 0 && c.calls.started === 0, 'after the unlock: nothing more')
  c = chanScope()
  Object.assign(c.scope, { faceConfigured: false, fido2Configured: false })
  c.scope.openLockChannel()
  assert(c.calls.started === 0, 'with neither face nor the key set up there is no channel')
  c = chanScope()
  c.scope.closeLockChannel()
  assert(c.calls.writes.length === 0, 'no channel, nothing to close')
  // Round 8 (Codex 5): the channel is reconciled, not only opened as the
  // lock begins: whenever the configuration loads or changes while locked,
  // and on every locked retry of the key lane question. A lock that began
  // before the PAM services were read still gets its channel, and never a
  // second one.
  for (const [prop, handler] of [['faceConfigured', 'onFaceConfiguredChanged'], ['fido2Configured', 'onFido2ConfiguredChanged']]) {
    const m = serviceQml.match(new RegExp('^  ' + handler + ': (.+)$', 'm'))
    assert(m && /openLockChannel\(\)/.test(m[1]), handler + ' reconciles the channel')
    c = chanScope()
    c.scope.root = c.scope
    Object.assign(c.scope, { faceConfigured: false, fido2Configured: false })
    c.scope.openLockChannel()
    assert(c.calls.started === 0, 'the lock began before ' + prop + ' was read')
    c.scope[prop] = true
    compileIn(c.scope, m[1])
    assert(c.calls.started === 1, prop + ' read while locked: the channel opens')
    compileIn(c.scope, m[1])
    assert(c.calls.started === 1, 'and a second change opens no second channel')
    c.scope.lockRequested = false
    c.scope.lockChannelProc.running = false
    compileIn(c.scope, m[1])
    assert(c.calls.started === 1, 'unlocked: a change opens nothing')
  }
  const reconcile = blockOf(serviceQml, 'Timer {\n    id: lockChannelReconcileTimer')
  assert(/interval: 2000/.test(reconcile) && /repeat: true/.test(reconcile) && /running: root\.lockRequested/.test(reconcile), 'every two seconds while the lock stands')
  const tick = (reconcile.match(/onTriggered: (.+)/) || [])[1] || ''
  c = chanScope()
  c.scope.root = c.scope
  compileIn(c.scope, tick)
  assert(c.calls.started === 1, 'each locked retry opens a missing channel')
  compileIn(c.scope, tick)
  assert(c.calls.started === 1, 'and never a second')
}

// The lock view says the key works, in words under the field, exactly while
// the lane is available, on the lock and its preview alike.
const hint = viewQml.split(/\bText \{/).slice(1).find(b => /objectName: "fido2Hint"/.test(b)) || ''
assert(/visible: root\.fido2Available/.test(hint) && /text: Commons\.I18n\.t\("lock\.keyTouch"\)/.test(hint) && enShell['lock.keyTouch'] === 'Or touch your security key' && /textFormat: Text\.PlainText/.test(hint), 'the lock view hints at the key while the lane is available')
assert((serviceQml.match(/fido2Available: root\.fido2Available/g) || []).length === 2, 'the lock and its preview both pass the lane on')
// Opus 19 F2: the hint follows the lane, which asks the key only while the
// displays are lit, so a panel lit behind the lock's back never promises a
// touch nothing is asking for; a keypress wakes both.
assert(/visible: root\.fido2Available && !root\.keyLaneDark/.test(hint), 'the key hint shows only while the lane can be asking')
// Opus 19b G2: the hint reads the lane's own dark state, never a screen's
// DPMS poll, so with a video wallpaper the two cannot disagree.
assert((serviceQml.match(/keyLaneDark: root\.displaysBlank/g) || []).length === 2, 'the lock and its preview pass the lane\'s dark state on')

// The lane's stack is the daemon's, never pam_u2f: the one stack setup
// writes for it, and no lock screen stack anywhere in the tree.
const helper = fs.readFileSync(path.join(root, 'install/helpers/pam-stack.sh'), 'utf8')
const stack = (helper.match(/pam_stack_key_lane_stack='([^']*)'/) || [])[1] || ''
assert(/^auth +sufficient +pam_faceauth\.so socket=\/run\/faceauth\/sock key-unlock$/m.test(stack) && /^auth +required +pam_deny\.so$/m.test(stack), 'the key lane is the daemon\'s key-unlock line closed by pam_deny')
assert(!/pam_u2f/.test(stack), 'the key lane names no pam_u2f')
for (const script of ['bin/omarchy-setup-security-fido2', 'bin/omarchy-setup-security-face', 'bin/omarchy-remove-security-fido2', 'bin/omarchy-remove-security-face']) {
  const text = fs.readFileSync(path.join(root, script), 'utf8')
  assert(!/pam_u2f\.so[^\n]*\n[^\n]*system-local-login/.test(text) && !/required +pam_u2f/.test(text), script + ' writes no pam_u2f lock stack')
}
JS

pass "the lock screen's FIDO2 lane runs on a secure lock with its service, unlocks on a touch, and stops with the unlock"
