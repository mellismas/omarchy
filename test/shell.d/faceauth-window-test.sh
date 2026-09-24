#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The face consent window is opened by a root daemon for every sudo and polkit
# request. These asserts hold the line on what it may show and how it answers:
# the answer token travels on stdin, never argv; spawned binaries are absolute;
# the card is two lines, what is asked and who asked, each labelled by whether
# the daemon read it itself, with nothing cut or hidden; and the layer never
# reaches a screen share.

run_node_test <<'JS'
const fs = require('fs')
const consent = fs.readFileSync(path.join(root, 'shell/plugins/faceauth/Consent.qml'), 'utf8')
const layerRules = fs.readFileSync(path.join(root, 'default/hypr/apps/omarchy-shell.lua'), 'utf8')

assert(!/--token/.test(consent), 'the consent window never puts the token on argv')
assert(/answerProc\.lines = \[root\.token\]/.test(consent), 'the token is the first stdin line of the answer')
assert(/"\/usr\/bin\/faceauth", "consent-answer"/.test(consent), 'the answer goes to consent-answer')

const commands = [...consent.matchAll(/command\s*[=:]\s*\[\s*"([^"]*)"/g)].map(m => m[1])
assert(commands.length >= 2, 'the consent window spawns processes', String(commands))
assert(commands.every(c => c === '/usr/bin/faceauth' || c === '/usr/bin/kill'), 'every spawned binary is /usr/bin/faceauth or /usr/bin/kill', String(commands))

// The passwordless button approves nothing on its own: it asks the daemon,
// with the request's token, to turn passwordless sudo on when this request
// is approved. The nod stays the only consent; nothing else is spawned.
const pl = consent.match(/function armPasswordless\(\) \{([\s\S]*?)\n  \}/)
assert(pl, 'the card has a passwordless button')
assert(/root\.answer\(\["--passwordless", root\.passwordlessMinutes\], ""\)/.test(pl[1]), 'it sends the minutes to the daemon as an answer carrying the token')
assert(/if \(root\.passwordlessMinutes\.length === 0 \|\| !root\.pending\) return/.test(pl[1]), 'it does nothing without minutes or without a pending request')
assert(!/root\.close\(\)/.test(pl[1]) && !/--dismiss/.test(pl[1]), 'it neither dismisses nor closes the request on screen')
assert(!commands.some(c => /passwordless|terminal/.test(c)) && !/floating-terminal/.test(consent), 'no command and no terminal are spawned for it')
assert(/readonly property bool sudoRequest: String\(\(root\.caller \|\| \{\}\)\.via \|\| ""\) === "sudo" && !\/.*omarchy-sudo-passwordless/.test(consent), 'it is keyed on the daemon-read via, sudo only, and not on the passwordless command\'s own card')
assert(/visible: root\.sudoRequest && root\.pending/.test(consent), 'it shows only on a pending sudo request')
const rows = consent.split(/\n\s*Row \{/).slice(1)
const plRow = rows.find(r => /id: passwordlessRow/.test(r)) || ''
const answerRow = rows.find(r => /id: answerRow/.test(r)) || ''
assert(/anchors\.left: parent\.left/.test(plRow) && /anchors\.verticalCenter: parent\.verticalCenter/.test(plRow), 'the passwordless controls sit on the left, centred on the line')
assert(/anchors\.right: parent\.right/.test(answerRow) && /anchors\.verticalCenter: parent\.verticalCenter/.test(answerRow), 'the answer buttons sit on the right of the same line, centred')
assert(/root\.passwordlessArmed = ""/.test(consent.match(/if \(fresh\) \{([\s\S]*?)\n    \}/)[1]), 'a new request starts with nothing armed')
assert(/"  and passwordless sudo for " \+ root\.passwordlessArmed \+ " min"/.test(consent.split('\n').find(l => /readonly property string commandLine:/.test(l)) || ''), 'once armed, the command line the user reads includes the passwordless spell')
assert(/Passwordless sudo armed: /.test(consent), 'once armed the button gives way to a note')
assert(/\(root\.caller \|\| \{\}\)\.clipped === true \? "  \[command too long to show in full\]" : ""/.test(consent), 'a command the daemon cut is marked as such on the line the user reads')

// Approve is the mouse form of Enter: it submits the typed password only.
const approve = consent.split(/\bButton \{/).slice(1).find(b => /text: "Approve"/.test(b))
assert(approve, 'the card has an Approve button')
assert(/enabled: passwordField\.text\.length > 0/.test(approve), 'Approve is enabled only with a typed password')
assert(/onClicked: root\.submitPassword\(\)/.test(approve), 'Approve submits the password and nothing else')
assert(consent.indexOf('blockRequester') === -1 && consent.indexOf('Block 10') === -1, 'the block control is gone (it keyed on an exe that is empty for polkit and sudo itself for sudo)')
const killBlock = consent.split(/\bButton \{/).slice(1).find(b => /Deny and kill/.test(b))
assert(killBlock && /visible: root\.verified/.test(killBlock), 'deny-and-kill shows only when the daemon named the requester')

// Line 1: the label is keyed on caller.verified alone and precedes the command,
// so no requester-supplied text can pick or push aside its own label.
assert(/readonly property bool verified: \(root\.caller \|\| \{\}\)\.verified === true/.test(consent), 'verified is read from caller.verified and nothing else')
assert(/\(root\.verified \? "Run as root: " : "Unverified: "\) \+ String\(\(root\.caller \|\| \{\}\)\.command \|\| ""\)/.test(consent), 'line 1 is "Run as root: " or "Unverified: " keyed on caller.verified, then caller.command')
// Line 2: who asked, from caller.who, labelled.
assert(/"Requester: " \+ String\(\(root\.caller \|\| \{\}\)\.who \|\| ""\)/.test(consent), 'line 2 is "Requester: " then caller.who')

// The old shapes are gone: no relayed claim, no separately assembled
// requester line, no answer deadline.
assert(!/claim/.test(consent), 'the window knows no claim field')
assert(!/requesterLine/.test(consent), 'the window no longer assembles its own requester line')
assert(!/Waits /.test(consent), 'the window shows no answer deadline')
assert(!/\btimed\b/.test(consent), 'the window has no timed property')

// Each Text block, cut at its own closing brace, so a line can only be
// checked beside the properties it is drawn with.
const blocks = consent.split(/\bText \{/).slice(1).map(chunk => chunk.split(/\n\s*\}\n/)[0])
const commandBlock = blocks.find(block => /text: root\.commandLine/.test(block))
const requesterBlock = blocks.find(block => /text: root\.requesterText/.test(block))
assert(commandBlock, 'the command line is drawn')
assert(requesterBlock, 'the requester line is drawn')
assert(/font\.pixelSize: Style\.font\.body/.test(commandBlock), 'the command line is body-sized')
assert(/font\.pixelSize: Style\.font\.caption/.test(requesterBlock), 'the requester line is caption-sized')
for (const [name, block] of [['command', commandBlock], ['requester', requesterBlock]]) {
  assert(/textFormat: Text\.PlainText/.test(block), `the ${name} line is plain text`)
  assert(/wrapMode: Text\.WrapAtWordBoundaryOrAnywhere/.test(block), `the ${name} line wraps anywhere, so a long token cannot push text off the card`)
  assert(!/maximumLineCount/.test(block), `the ${name} line has no line limit`)
  assert(!/elide/.test(block), `the ${name} line is never elided`)
}

// The command area is height-bounded and scrolls, so a command that wraps to
// hundreds of lines (or carries line separators) cannot push the requester
// line and the buttons off a card the user cannot move. Nothing is cut: the
// Text inside keeps its full height and the area scrolls over it.
const flickChunk = consent.split(/\bFlickable \{/).slice(1).find(chunk => /id: commandArea/.test(chunk)) || ''
const commandArea = flickChunk.split(/\n        \}\n/)[0]
assert(commandArea, 'the command line sits in a Flickable')
assert(/text: root\.commandLine/.test(commandArea), 'the Flickable holds the command line')
assert(/height: Math\.min\(commandText\.implicitHeight, commandArea\.maxHeight\)/.test(commandArea), 'the area grows with the command up to a bound')
const bound = commandArea.match(/maxHeight: panel\.height > 0 \? Math\.round\(panel\.height \* ([0-9.]+)\)/)
assert(bound && Number(bound[1]) > 0 && Number(bound[1]) <= 0.5, 'the bound is a fraction of the screen height of at most a half', String(bound && bound[1]))
assert(/contentHeight: commandText\.implicitHeight/.test(commandArea), 'the scroll range is the whole command')
assert(/clip: true/.test(commandArea), 'the area clips to its bound')
assert(/flickableDirection: Flickable\.VerticalFlick/.test(commandArea), 'the area scrolls vertically')
assert(/interactive: contentHeight > height/.test(commandArea), 'the area scrolls only when the command overflows it')
assert(/ScrollBar\.vertical:/.test(commandArea), 'the area shows a scroll bar when it overflows')

const pendingLine = consent.split('\n').find(line => /readonly property bool pending:/.test(line)) || ''
for (const state of ['scanning', 'nod', 'confirming', 'password', 'locked']) {
  assert(pendingLine.includes(`root.state === "${state}"`), `${state} is a pending state`, pendingLine)
}

assert(!/queued/.test(consent), 'the window knows no queued state; a waiting request is a notification, not a second window')

const rule = layerRules.split('\n').find(line => line.includes('^omarchy-faceauth$')) || ''
assert(rule.includes('hl.layer_rule('), 'omarchy-shell.lua carries a layer rule for the consent window', rule)
assert(/no_anim = true/.test(rule) && /animation = "none"/.test(rule), 'the consent layer has no animation', rule)
assert(/no_screen_share = true/.test(rule), 'the consent layer is kept out of screen shares', rule)
// The window belongs to the pending request. A summon without that request's
// token changes nothing (any process of the user's can summon), a new token
// starts clean, and the daemon hears from the window itself that the request
// is on screen before it reads a nod.
const open = consent.match(/function open\(payloadJson\) \{([\s\S]*?)\n  \}/)
assert(open, 'the window has an open function')
assert(/if \(root\.pending && token !== root\.token\) \{[\s\S]*?return/.test(open[1]), 'while pending, a payload without the request token is ignored')
assert(open[1].indexOf('root.state = String(payload.state') > open[1].indexOf('return'), 'nothing is applied before the token check')
const fresh = open[1].match(/if \(fresh\) \{([\s\S]*?)\n    \}/)
assert(fresh, 'a new token is handled as a fresh request')
assert(/passwordField\.text = ""/.test(fresh[1]), 'a new request clears the password field')
assert(/root\.answer\(\["--ack"\], ""\)/.test(fresh[1]), 'a new request is acknowledged to the daemon with its token')
assert(/var fresh = !root\.opened \|\| token !== root\.token/.test(open[1]), 'fresh means a token the window has not seen')
assert(/commandArea\.contentY = 0/.test(fresh[1]), 'a new request starts at the top of the command area')

// The card is drawn on the output that holds the camera.
const panelBlock = consent.split(/\bPanelWindow \{/)[1] || ''
assert(/screen: root\.cameraScreen/.test(panelBlock), 'the card is bound to the camera screen')
assert(/\/\^eDP\/\.test\(String\(screens\[i\]\.name\)\)/.test(consent), 'the camera screen is the built-in panel when there is one')
JS
