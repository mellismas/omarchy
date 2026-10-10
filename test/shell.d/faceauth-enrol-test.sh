#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The enrollment walk-through window draws a dot from the daemon's pose
# stream and never asks for, receives or shows a camera image. Its only
# way back to the daemon is continue, redo and cancel.

run_node_test <<'JS'
const fs = require('fs')
const qml = fs.readFileSync(path.join(root, 'shell/plugins/faceauth-enrol/Enrol.qml'), 'utf8')
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'shell/plugins/faceauth-enrol/manifest.json'), 'utf8'))

assertEqual(manifest.id, 'omarchy.faceauth.enrol', 'the plugin id is what the daemon summons')
assert(manifest.kinds.indexOf('overlay') !== -1 && manifest.entryPoints.overlay === 'Enrol.qml', 'it is an overlay with Enrol.qml as its entry point')

assert(/enrol_watch: true/.test(qml), 'the window watches the stream over its own socket connection')
assert(/path: "\/run\/faceauth\/sock"/.test(qml), 'the socket is the daemon\'s')
// No image of any kind: the window draws a dot and a ring from the pose
// stream, and nothing is ever asked of the daemon but that stream.
const code = qml.replace(/\/\/.*$/gm, '')
assert(!/Image \{|source:|jpeg|png|ppm|base64|enrol_frame/i.test(code), 'no camera image is drawn or requested')

const commands = [...qml.matchAll(/command\s*[=:]\s*\[\s*"([^"]*)"/g)].map(m => m[1])
assert(commands.length === 1 && commands[0] === '/usr/bin/faceauth', 'the only process spawned is /usr/bin/faceauth', String(commands))
assert(/"enrol-control", word/.test(qml), 'the buttons send enrol-control words')
for (const w of ['continue', 'redo', 'cancel']) assert(new RegExp('root\\.control\\("' + w + '"\\)').test(qml), 'the window can send ' + w)

assert(/root\.dotUx = Number\(t\.dot_x/.test(qml) && /root\.targetUx = Number\(t\.target_x/.test(qml), 'the dot and the target come from the daemon in ring units; the window does no mapping of its own')
assert(/readonly property real dotX: root\.dotUx \* root\.ringRadius/.test(qml), 'the dot is drawn at the daemon\'s position')
assert(/ctx\.setLineDash/.test(qml), 'the target is a dashed circle')
assert(/width: root\.ringRadius \* 0\.70/.test(qml), 'the target circle is drawn at the daemon\'s acceptance radius')
assert(/readonly property real dotRadius: [\s\S]*root\.size/.test(qml), 'the dot\'s size follows the distance')
assert(/^FaceAuthOverlay \{\n  id: root$/m.test(qml), 'the window is a FaceAuthOverlay, which picks the camera\'s screen')
assert(/screen: root\.cameraScreen/.test(qml), 'the window is drawn on the camera\'s screen')
assert(/WlrLayershell\.namespace: "omarchy-faceauth-enrol"/.test(qml), 'the layer has its own namespace for a layer rule')

// The rounds: the reading texts are placed around the screen, one at a
// time as the daemon says, and the card shows the round and its clock.
assert(/root\.round === "read" && !root\.countdown && root\.readSlot === index/.test(qml), 'the reading text shows one slot at a time, as the daemon streams it')
const enShell = JSON.parse(fs.readFileSync(path.join(root, 'default/i18n/en/shell.json'), 'utf8'))
const namesRound = (key) => new RegExp('I18n\\.t\\("' + key.replace(/\./g, '\\.') + '"\\)\\.arg\\(Commons\\.I18n\\.formatNumber\\(root\\.roundNo\\)\\)\\.arg\\(Commons\\.I18n\\.formatNumber\\(root\\.roundOf\\)\\)').test(qml)
  && /^Round %1 of %2:/.test(enShell[key])
assert(namesRound('faceEnroll.roundStarting') && namesRound('faceEnroll.roundRecording'), 'the card names the round')
assert(/visible: root\.step === "welcome" \|\| root\.step === "bridge"/.test(qml), 'Continue also starts the rounds from the bridge')

// The window never outlives the session: a done or failed tick closes it
// after its message, and the daemon closing the stream (a session that
// ended without a tick, a daemon that went away) closes it too.
assert(/if \(root\.step === "done" \|\| root\.step === "failed"\) doneTimer\.restart\(\)/.test(qml), 'a done or failed tick closes the window')
assert(/onTriggered: root\.close\(\)/.test(qml), 'the timer closes it')
assert(/else if \(root\.streamed\) \{[\s\S]*?if \(!doneTimer\.running\) root\.close\(\)/.test(qml), 'the stream closing closes the window unless a final tick already started the timer')
assert(/root\.streamed = false\n\s*watch\.connected = false\n\s*watch\.connected = true/.test(qml), 'reopening resets the stream flag before the socket is re-armed')
JS
