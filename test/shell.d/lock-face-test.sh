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
JS
