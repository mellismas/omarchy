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
assert(!JSON.stringify(layout).includes('omarchy.faceauth.presence'), 'the default layout does not carry it: setup puts it on the bar, removal takes it off')

const commands = [...qml.matchAll(/command\s*=\s*\["([^"]*)"/g)].map(m => m[1])
assert(commands.length === 3 && commands.every(c => c === '/usr/bin/faceauth'), 'the only process spawned is /usr/bin/faceauth', String(commands))
assert(/\["\/usr\/bin\/faceauth", "presence", "mode"\]/.test(qml), 'the mode is read with faceauth presence mode')
assert(/\["\/usr\/bin\/faceauth", "presence", "mode", root\.secure \? "default" : "secure"\]/.test(qml), 'a click switches to the other mode and nothing else')
assert(/visible: watching/.test(qml), 'the widget is hidden unless the daemon says the watch is on')
assert(/root\.watching = p\.watching === true/.test(qml), 'watching is read from the daemon\'s answer')
assert(/root\.mode = p\.mode === "secure" \? "secure" : "default"/.test(qml), 'any mode but secure reads as default')
assert(/if \(exitCode !== 0\) root\.watching = false/.test(qml), 'a refused or failed call hides the widget')
assert(!/pkexec|floating-terminal|"sudo"/.test(qml), 'no privilege and no terminal are involved')

// The poll is slow: every one is a daemon connection, and thirty seconds of
// them during a long enrolment once used up the daemon's connection slots.
// The chord's script refreshes the widget over IPC after a switch, so the
// timer only has to catch a daemon restart or a change of enrolment.
const timer = qml.match(/Timer \{([\s\S]*?)\n  \}/)
assert(timer, 'the widget has one poll timer')
const interval = Number((timer[1].match(/interval: (\d+)/) || [])[1])
assert(interval >= 300000, 'the poll runs at most every five minutes', String(interval))
assert(/triggeredOnStart: true/.test(timer[1]), 'the first read is at start, not after the first interval')
assert(/ShellIpc \{\s*target: "omarchy\.faceauth\.presence"[\s\S]*?function refresh\(\): void/.test(qml), 'a refresh can be pushed over IPC between polls')
const ipc = qml.match(/ShellIpc \{([\s\S]*?)\n  \}/)
assert(ipc && /root\.broadcast\("refresh"\)/.test(ipc[1]) && !/root\.refresh\(\)/.test(ipc[1]), 'the IPC refresh is relayed to the widget on every monitor, not only the instance that owns the target')

// A faceauth that cannot start never exits, so busy is also cleared by a
// watchdog armed with every spawn and stopped by the exit.
const watchdog = qml.match(/Timer \{\s*id: watchdog([\s\S]*?)\n  \}/)
assert(watchdog, 'a watchdog timer guards the busy flag')
assert(/root\.busy = false/.test(watchdog[1]) && /root\.watching = false/.test(watchdog[1]), 'the watchdog clears busy and hides the widget until a refresh answers')
const watchdogInterval = Number((watchdog[1].match(/interval: (\d+)/) || [])[1])
assert(watchdogInterval >= 5000 && watchdogInterval <= 30000, 'the watchdog waits longer than the CLI does for the daemon', String(watchdogInterval))
const spawns = qml.split(/root\.busy = true/).length - 1
assert(spawns === 3 && (qml.match(/watchdog\.restart\(\)/g) || []).length === spawns, 'every spawn arms the watchdog', String(spawns))
const exited = qml.match(/onExited: function\(exitCode\) \{([\s\S]*?)\n    \}/)
assert(exited && /watchdog\.stop\(\)/.test(exited[1]) && /root\.busy = false/.test(exited[1]), 'an exit stops the watchdog and clears busy')

// Right click: a menu of the two modes, each set through faceauth like a
// click, and nothing else.
assert(/if \(b === Qt\.RightButton\) root\.menuOpen = !root\.menuOpen/.test(qml), 'right click opens the mode menu')
assert(/PopupCard \{/.test(qml), 'the menu is a popup card anchored to the widget')
const values = [...qml.matchAll(/value: "([a-z]+)"/g)].map(m => m[1])
assertEqual(values.join(' '), 'default secure', 'the menu offers default and secure and nothing else')
const choose = qml.match(/function choose\(next\) \{([\s\S]*?)\n  \}/)
assert(choose, 'the menu rows call choose')
assert(/modeProc\.command = \["\/usr\/bin\/faceauth", "presence", "mode", next\]/.test(choose[1]), 'choosing a mode sets it through faceauth')
assert(/next === root\.mode\) return/.test(choose[1]), 'choosing the current mode changes nothing')
assert(!/bar\.run\(/.test(qml), 'the widget runs nothing through the bar')
JS
