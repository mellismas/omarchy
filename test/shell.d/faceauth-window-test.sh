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

const pendingLine = consent.split('\n').find(line => /readonly property bool pending:/.test(line)) || ''
for (const state of ['scanning', 'nod', 'confirming', 'password', 'locked']) {
  assert(pendingLine.includes(`root.state === "${state}"`), `${state} is a pending state`, pendingLine)
}

assert(!/queued/.test(consent), 'the window knows no queued state; a waiting request is a notification, not a second window')

const rule = layerRules.split('\n').find(line => line.includes('^omarchy-faceauth$')) || ''
assert(rule.includes('hl.layer_rule('), 'omarchy-shell.lua carries a layer rule for the consent window', rule)
assert(/no_anim = true/.test(rule) && /animation = "none"/.test(rule), 'the consent layer has no animation', rule)
assert(/no_screen_share = true/.test(rule), 'the consent layer is kept out of screen shares', rule)
JS
