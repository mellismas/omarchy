#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The walk-away lock mode widget holds no state of its own: it reads the
# mode from the daemon through faceauth, switches it the same way, spawns
# nothing else, and stays hidden unless the daemon says the watch is on.

run_node_test <<'JS'
const fs = require('fs')
const qml = fs.readFileSync(path.join(root, 'shell/plugins/faceauth-presence/BarWidget.qml'), 'utf8')
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'shell/plugins/faceauth-presence/manifest.json'), 'utf8'))
const layout = JSON.parse(fs.readFileSync(path.join(root, 'config/omarchy/shell.json'), 'utf8'))

assertEqual(manifest.id, 'omarchy.faceauth.presence', 'the plugin id is the widget id')
assert(manifest.kinds.indexOf('bar-widget') !== -1 && manifest.entryPoints.barWidget === 'BarWidget.qml', 'it is a bar widget with BarWidget.qml as its entry point')
assert(layout.bar.layout.right.some(w => w.id === 'omarchy.faceauth.presence'), 'the default layout carries it on the right')

const commands = [...qml.matchAll(/command\s*=\s*\["([^"]*)"/g)].map(m => m[1])
assert(commands.length === 2 && commands.every(c => c === '/usr/bin/faceauth'), 'the only process spawned is /usr/bin/faceauth', String(commands))
assert(/\["\/usr\/bin\/faceauth", "presence", "mode"\]/.test(qml), 'the mode is read with faceauth presence mode')
assert(/\["\/usr\/bin\/faceauth", "presence", "mode", root\.secure \? "default" : "secure"\]/.test(qml), 'a click switches to the other mode and nothing else')
assert(/visible: watching/.test(qml), 'the widget is hidden unless the daemon says the watch is on')
assert(/root\.watching = p\.watching === true/.test(qml), 'watching is read from the daemon\'s answer')
assert(/root\.mode = p\.mode === "secure" \? "secure" : "default"/.test(qml), 'any mode but secure reads as default')
assert(/if \(exitCode !== 0\) root\.watching = false/.test(qml), 'a refused or failed call hides the widget')
assert(!/sudo|pkexec|terminal/.test(qml), 'no privilege and no terminal are involved')
JS
