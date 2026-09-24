#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The enrolment walk-through window draws a dot from the daemon's pose
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
assert(!/Image \{|image|frame|jpeg|png|ppm|base64/i.test(code), 'no camera image is drawn or requested')

const commands = [...qml.matchAll(/command\s*[=:]\s*\[\s*"([^"]*)"/g)].map(m => m[1])
assert(commands.length === 1 && commands[0] === '/usr/bin/faceauth', 'the only process spawned is /usr/bin/faceauth', String(commands))
assert(/"enrol-control", word/.test(qml), 'the buttons send enrol-control words')
for (const w of ['continue', 'redo', 'cancel']) assert(new RegExp('root\\.control\\("' + w + '"\\)').test(qml), 'the window can send ' + w)

assert(/root\.dotUx = Number\(t\.dot_x/.test(qml) && /root\.targetUx = Number\(t\.target_x/.test(qml), 'the dot and the target come from the daemon in ring units; the window does no mapping of its own')
assert(/readonly property real dotX: root\.dotUx \* root\.ringRadius/.test(qml), 'the dot is drawn at the daemon\'s position')
assert(/ctx\.setLineDash/.test(qml), 'the target is a dashed circle')
assert(/width: root\.ringRadius \* 0\.70/.test(qml), 'the target circle is drawn at the daemon\'s acceptance radius')
assert(/readonly property real dotRadius: [\s\S]*root\.size/.test(qml), 'the dot\'s size follows the distance')
assert(/screen: root\.cameraScreen/.test(qml), 'the window is drawn on the camera\'s screen')
assert(/WlrLayershell\.namespace: "omarchy-faceauth-enrol"/.test(qml), 'the layer has its own namespace for a layer rule')
JS
