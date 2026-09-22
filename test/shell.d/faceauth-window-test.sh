#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The face consent window is opened by a root daemon for every sudo and polkit
# request. These asserts hold the line on what it may show and how it answers:
# the answer token travels on stdin, never argv; spawned binaries are absolute;
# text the requester supplied about itself is never on the prominent line and
# is labelled unverified; and the layer never reaches a screen share.

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

assert(/text: String\(\(root\.caller \|\| \{\}\)\.command \|\| ""\)/.test(consent), 'the prominent line shows the command the daemon derived')
assert(/text: "Requester says: " \+ root\.claim \+ " \(not verified\)"/.test(consent), 'the requester claim is labelled as unverified')
const claimBlock = consent.match(/text: "Requester says: "[\s\S]*?font\.pixelSize: ([\w.]+)/)
assertEqual(claimBlock && claimBlock[1], 'Style.font.caption', 'the requester claim is caption-sized')
// Each Text block, cut at its own font size, so a claim can only be seen
// beside the size it is drawn at.
const blocks = consent.split(/\bText \{/).slice(1).map(chunk => chunk.split('font.pixelSize:')[0] + 'font.pixelSize:' + (chunk.split('font.pixelSize:')[1] || '').split('\n')[0])
const prominent = blocks.filter(block => /font\.pixelSize: Style\.font\.(title|body)/.test(block))
assert(prominent.length >= 3, 'the prominent Text blocks were found', String(prominent.length))
assert(prominent.every(block => !/claim/.test(block)), 'the requester claim never reaches a title or body-sized line')
assert(blocks.some(block => /claim/.test(block) && /Style\.font\.caption/.test(block)), 'the requester claim is drawn at caption size')

assert(!/queued/.test(consent), 'the window knows no queued state; a waiting request is a notification, not a second window')

const rule = layerRules.split('\n').find(line => line.includes('^omarchy-faceauth$')) || ''
assert(rule.includes('hl.layer_rule('), 'omarchy-shell.lua carries a layer rule for the consent window', rule)
assert(/no_anim = true/.test(rule) && /animation = "none"/.test(rule), 'the consent layer has no animation', rule)
assert(/no_screen_share = true/.test(rule), 'the consent layer is kept out of screen shares', rule)
JS
