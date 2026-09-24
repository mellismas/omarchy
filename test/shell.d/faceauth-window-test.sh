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
const enShell = JSON.parse(fs.readFileSync(path.join(root, 'default/i18n/en/shell.json'), 'utf8'))
const layerRules = fs.readFileSync(path.join(root, 'default/hypr/apps/omarchy-shell.lua'), 'utf8')

assert(!/--token/.test(consent), 'the consent window never puts the token on argv')
assert(/answerProc\.lines = \[root\.token\]/.test(consent), 'the token is the first stdin line of the answer')
assert(/"\/usr\/bin\/faceauth", "consent-answer"/.test(consent), 'the answer goes to consent-answer')

const commands = [...consent.matchAll(/command\s*[=:]\s*\[\s*"([^"]*)"/g)].map(m => m[1])
assert(commands.length >= 2, 'the consent window spawns processes', String(commands))
assert(commands.every(c => c === '/usr/bin/faceauth' || c === '/usr/bin/kill'), 'every spawned binary is /usr/bin/faceauth or /usr/bin/kill', String(commands))

// A passwordless-sudo rider the daemon reports on the request shows on
// the card: the armed minutes come from the payload, never from the card's
// own state, so nothing armed over the socket can hide from the user.
assert(!/root\.passwordlessArmed = /.test(consent), 'the card never sets the armed minutes itself')
assert(/readonly property string passwordlessArmed: root\.riderMinutes > 0 \? String\(root\.riderMinutes\) : ""/.test(consent), 'the armed minutes are read from the payload-driven riderMinutes')
assert(/root\.riderMinutes = Number\(payload\.passwordless_minutes \|\| 0\)/.test(consent), 'open() reads the rider from payload.passwordless_minutes')
assert(/var riderChanged = Number\(payload\.passwordless_minutes \|\| 0\) !== root\.riderMinutes/.test(consent), 'a payload that changes the rider is noticed')
assert(/if \(token\.length > 0 && \(fresh \|\| riderChanged\)\) root\.answer\(\["--ack"\], ""\)/.test(consent), 'a changed rider is acknowledged afresh, so the daemon starts the dwell over')
const rows = consent.split(/\n\s*Row \{/).slice(1)
const answerRow = rows.find(r => /id: answerRow/.test(r)) || ''
assert(/anchors\.right: parent\.right/.test(answerRow) && /anchors\.verticalCenter: parent\.verticalCenter/.test(answerRow), 'the answer buttons sit on the right of the same line, centred')
assert(!/passwordlessArmed/.test(consent.match(/if \(fresh\) \{([\s\S]*?)\n    \}/)[1]), 'a new request carries nothing armed of its own; the payload decides')
assert(/\+ \(root\.passwordlessArmed\.length > 0 \? "  " \+ Commons\.I18n\.t\("faceConsent\.passwordlessRider"\)\.arg\(root\.passwordlessArmed\) : ""\)/.test(consent.split('\n').find(l => /readonly property string commandLine:/.test(l)) || '') && enShell['faceConsent.passwordlessRider'] === 'and passwordless sudo for %1 min', 'once armed, the command line the user reads includes the passwordless spell')
assert(/\(root\.caller \|\| \{\}\)\.clipped === true \? "  " \+ Commons\.I18n\.t\("faceConsent\.commandClipped"\) : ""/.test(consent) && enShell['faceConsent.commandClipped'] === '[command too long to show in full]', 'a command the daemon cut is marked as such on the line the user reads')

// Approve is the mouse form of Enter: it submits the typed password only.
const approve = consent.split(/\bButton \{/).slice(1).find(b => /text: Commons\.I18n\.t\("faceConsent\.approve"\)/.test(b))
assert(approve, 'the card has an Approve button')
assert(/enabled: passwordField\.text\.length > 0/.test(approve), 'Approve is enabled only with a typed password')
assert(/onClicked: root\.submitPassword\(\)/.test(approve), 'Approve submits the password and nothing else')
assert(consent.indexOf('blockRequester') === -1 && consent.indexOf('Block 10') === -1, 'the block control is gone (it keyed on an exe that is empty for polkit and sudo itself for sudo)')
const killBlock = consent.split(/\bButton \{/).slice(1).find(b => /faceConsent\.denyAndKill/.test(b))
assert(killBlock && /visible: root\.verified/.test(killBlock), 'deny-and-kill shows only when the daemon named the requester')

// Line 1: the label is keyed on caller.verified alone and precedes the command,
// so no requester-supplied text can pick or push aside its own label.
assert(/readonly property bool verified: \(root\.caller \|\| \{\}\)\.verified === true/.test(consent), 'verified is read from caller.verified and nothing else')
assert(/\(root\.verified \? Commons\.I18n\.t\("faceConsent\.runAsRoot"\) : Commons\.I18n\.t\("faceConsent\.unverified"\)\) \+ " " \+ String\(\(root\.caller \|\| \{\}\)\.command \|\| ""\)/.test(consent) && enShell['faceConsent.runAsRoot'] === 'Run as root:' && enShell['faceConsent.unverified'] === 'Unverified:', 'line 1 is "Run as root: " or "Unverified: " keyed on caller.verified, then caller.command')
// Line 2: who asked, from caller.who, labelled.
assert(/Commons\.I18n\.t\("faceConsent\.requester"\) \+ " " \+ String\(\(root\.caller \|\| \{\}\)\.who \|\| ""\)/.test(consent) && enShell['faceConsent.requester'] === 'Requester:', 'line 2 is "Requester: " then caller.who')

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

// One rule covers the consent and the enrolment namespaces, the way
// upstream folds its own panels into one regex.
const rule = layerRules.split('\n').find(line => line.includes('^omarchy-faceauth(-enrol)?$')) || ''
assert(rule.includes('hl.layer_rule('), 'omarchy-shell.lua carries a layer rule for the consent and enrolment windows', rule)
assert(new RegExp('^omarchy-faceauth(-enrol)?$').test('omarchy-faceauth') && new RegExp('^omarchy-faceauth(-enrol)?$').test('omarchy-faceauth-enrol'), 'the one regex matches both namespaces')
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
assert(/root\.answer\(\["--ack"\], ""\)/.test(open[1]) && open[1].indexOf('root.answer(["--ack"]') > open[1].indexOf('if (fresh)'), 'a new request is acknowledged to the daemon with its token, after it is drawn')
assert(/var fresh = !root\.opened \|\| token !== root\.token/.test(open[1]), 'fresh means a token the window has not seen')
assert(/commandArea\.contentY = 0/.test(fresh[1]), 'a new request starts at the top of the command area')

// The window's safety net hides a card the daemon has gone quiet on; it
// never answers for the user. Only close() (Dismiss, Escape) sends the no.
const autoCloseBlock = consent.split(/\bTimer \{/).slice(1).find(b => /id: autoClose/.test(b)) || ''
assert(/onTriggered: root\.expire\(\)/.test(autoCloseBlock), 'the safety net calls expire(), not close()')
const expire = consent.match(/function expire\(\) \{([\s\S]*?)\n  \}/)
assert(expire, 'the window has an expire function')
assert(!/--dismiss/.test(expire[1]) && !/root\.answer/.test(expire[1]), 'expiry sends nothing to the daemon')
assert(/root\.opened = false/.test(expire[1]), 'expiry hides the card')
const close = consent.match(/function close\(\) \{([\s\S]*?)\n  \}/)
assert(close && /if \(root\.pending\) root\.answer\(\["--dismiss"\], ""\)/.test(close[1]), 'Dismiss and Escape still say no while pending')

// Ready to nod: after an unanswered nod window the daemon disarms the nods
// and says so in the payload; the button re-arms them and approves nothing.
assert(/root\.waiting = payload\.waiting === true/.test(open[1]), 'open() reads waiting from the payload, true only when the daemon says so')
const ready = consent.match(/function readyToNod\(\) \{([\s\S]*?)\n  \}/)
assert(ready, 'the card has a ready-to-nod function')
assert(/if \(!root\.pending \|\| !root\.waiting\) return/.test(ready[1]), 'it does nothing unless a request is pending and the daemon is waiting')
assert(/root\.answer\(\["--rearm"\], ""\)/.test(ready[1]), 'it sends --rearm with the token and nothing else')
assert(!/root\.close\(\)/.test(ready[1]) && !/--dismiss/.test(ready[1]), 'it neither dismisses nor closes')
const readyButton = consent.split(/\bButton \{/).slice(1).find(b => /text: Commons\.I18n\.t\("faceConsent\.readyToNod"\)/.test(b))
assert(readyButton, 'the card has a Ready to nod button')
assert(/visible: root\.pending && root\.waiting/.test(readyButton), 'the button shows only while the daemon waits for a re-arm')
assert(/onClicked: root\.readyToNod\(\)/.test(readyButton), 'the button calls readyToNod')

// The card is drawn on the output that holds the camera.
const panelBlock = consent.split(/\bPanelWindow \{/)[1] || ''
assert(/screen: root\.cameraScreen/.test(panelBlock), 'the card is bound to the camera screen')
assert(/\/\^eDP\/\.test\(String\(screens\[i\]\.name\)\)/.test(consent), 'the camera screen is the built-in panel when there is one')
JS
