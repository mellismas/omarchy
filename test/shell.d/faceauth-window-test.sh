#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The face consent window is opened by a root daemon for every sudo and polkit
# request. These asserts hold the line on what it may show and how it answers:
# the answer token travels on stdin, never argv; spawned binaries are absolute;
# the card is two lines, what is asked and who asked, each labeled by whether
# the daemon read it itself, with nothing cut or hidden; and the layer never
# reaches a screen share.

run_node_test <<'JS'
const fs = require('fs')
const consent = fs.readFileSync(path.join(root, 'shell/plugins/faceauth/Consent.qml'), 'utf8')
const enShell = JSON.parse(fs.readFileSync(path.join(root, 'default/i18n/en/shell.json'), 'utf8'))
const layerRules = fs.readFileSync(path.join(root, 'default/hypr/apps/omarchy-shell.lua'), 'utf8')

assert(!/--token/.test(consent), 'the consent window never puts the token on argv')
assert(/lines: \[root\.token\]\.concat\(secret\.length > 0 \? \[secret\] : \[\]\)/.test(consent), 'the token is the first stdin line of the answer')
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
assert(/if \(root\.passwordlessMinutes\.length === 0 \|\| !root\.pending \|\| !root\.facePresent\) return/.test(pl[1]), 'it does nothing without minutes, without a pending request, or without the face in frame')
// The rider row is the daemon's, not the card's: the armed minutes come
// from the payload and the button press sets nothing locally, so the card
// always shows what the nod will grant, whoever armed it over the socket.
assert(!/root\.passwordlessArmed = /.test(consent), 'the card never sets the armed minutes itself')
assert(/readonly property string passwordlessArmed: root\.riderMinutes > 0 \? String\(root\.riderMinutes\) : ""/.test(consent), 'the armed minutes are read from the payload-driven riderMinutes')
assert(/root\.riderMinutes = Number\(payload\.passwordless_minutes \|\| 0\)/.test(consent), 'open() reads the rider from payload.passwordless_minutes')
assert(/root\.facePresent = payload\.face_present === true/.test(consent), 'open() reads the face from payload.face_present, true only when the daemon says so')
assert(/var riderChanged = Number\(payload\.passwordless_minutes \|\| 0\) !== root\.riderMinutes/.test(consent), 'a payload that changes the rider is noticed')
assert(/if \(token\.length > 0 && \(fresh \|\| riderChanged \|\| payload\.ack_wanted === true\)\) root\.answer\(\["--ack"\], ""\)/.test(consent), 'a changed rider is acknowledged afresh, so the daemon starts the dwell over')
// Round 3's 3: the card coming back after the unlock is the same request
// on screen, so it is not fresh; the daemon dropped its old acknowledgment
// and asks for a new one in the payload, and the card gives it once drawn.
assert(/payload\.ack_wanted === true/.test(consent), 'the card acknowledges a payload that asks for it, even for a request it already showed')
// The control is grayed and unclickable unless the enrolled face is on screen.
const plButton = consent.split(/\bButton \{/).slice(1).find(b => /faceConsent\.passwordlessFor/.test(b))
assert(plButton, 'the card has the passwordless button')
assert(/enabled: root\.passwordlessMinutes\.length > 0 && root\.facePresent/.test(plButton), 'the passwordless button is enabled only with minutes and the face in frame')
assert(/opacity: root\.facePresent \? 1\.0 : 0\.4/.test(plButton), 'the passwordless button is grayed without the face')
assert(/faceConsent\.passwordlessLook/.test(plButton) && /look at the camera/.test(enShell['faceConsent.passwordlessLook']), 'the grayed button says why')
const minutesBlock = consent.split(/\bTextField \{/).slice(1).find(b => /id: minutesField/.test(b)) || ''
assert(/enabled: root\.facePresent/.test(minutesBlock), 'the minutes field is disabled without the face')
// Upstream's warning, in its own words (bin/omarchy-sudo-passwordless).
assert(/passwordlessWarning: Commons\.I18n\.t\("faceConsent\.passwordlessWarning"\)\.arg\(/.test(consent) && /^WARNING: This will allow ANY process running as your user to execute ANY command as root WITHOUT a password for %1 minutes\. /.test(enShell['faceConsent.passwordlessWarning']), 'the card carries upstream\'s passwordless warning verbatim')
assert(/Anyone or anything with access to your user account gets full root\.$/.test(enShell['faceConsent.passwordlessWarning']), 'and its second sentence')
const warnBlock = consent.split(/\bText \{/).slice(1).find(b => /id: passwordlessWarningText/.test(b)) || ''
assert(/visible: root\.sudoRequest && root\.pending && \(root\.passwordlessArmed\.length > 0 \|\| minutesField\.activeFocus\)/.test(warnBlock), 'the warning shows while arming and for as long as a rider is armed')
assert(!/root\.close\(\)/.test(pl[1]) && !/--dismiss/.test(pl[1]), 'it neither dismisses nor closes the request on screen')
assert(!commands.some(c => /passwordless|terminal/.test(c)) && !/floating-terminal/.test(consent), 'no command and no terminal are spawned for it')
assert(/readonly property bool sudoRequest: String\(\(root\.caller \|\| \{\}\)\.via \|\| ""\) === "sudo" && !\/.*omarchy-sudo-passwordless/.test(consent), 'it is keyed on the daemon-read via, sudo only, and not on the passwordless command\'s own card')
assert(/visible: root\.sudoRequest && root\.pending/.test(consent), 'it shows only on a pending sudo request')
const rows = consent.split(/\n\s*Row \{/).slice(1)
const plRow = rows.find(r => /id: passwordlessRow/.test(r)) || ''
const answerRow = rows.find(r => /id: answerRow/.test(r)) || ''
assert(/anchors\.left: parent\.left/.test(plRow) && /anchors\.verticalCenter: parent\.verticalCenter/.test(plRow), 'the passwordless controls sit on the left, centered on the line')
assert(/anchors\.right: parent\.right/.test(answerRow) && /anchors\.verticalCenter: parent\.verticalCenter/.test(answerRow), 'the answer buttons sit on the right of the same line, centered')
assert(!/passwordlessArmed/.test(consent.match(/if \(fresh\) \{([\s\S]*?)\n    \}/)[1]), 'a new request carries nothing armed of its own; the payload decides')
assert(/\+ \(root\.passwordlessArmed\.length > 0 \? "  " \+ Commons\.I18n\.t\("faceConsent\.passwordlessRider"\)\.arg\(root\.passwordlessArmed\) : ""\)/.test(consent.split('\n').find(l => /readonly property string commandLine:/.test(l)) || '') && enShell['faceConsent.passwordlessRider'] === 'and passwordless sudo for %1 min', 'once armed, the command line the user reads includes the passwordless spell')
assert(/faceConsent\.passwordlessArmed/.test(consent) && /^Passwordless sudo armed: %1 min/.test(enShell['faceConsent.passwordlessArmed']), 'once armed the button gives way to a note')
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
// Line 2: who asked, from caller.who, labeled.
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

// One rule covers the consent and the enrollment namespaces, the way
// upstream folds its own panels into one regex.
const rule = layerRules.split('\n').find(line => line.includes('^omarchy-faceauth(-enrol)?$')) || ''
assert(rule.includes('hl.layer_rule('), 'omarchy-shell.lua carries a layer rule for the consent and enrollment windows', rule)
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

// Live test 2, 2026-10-13: the daemon takes a card down from its side (a
// head shake, a dismissal, a requester killed or gone) with `shell hide`,
// which calls close(). A closed card is over, whoever closed it: the next
// request's summon must be shown, not ignored as a stranger's while the
// window still holds the old token as pending. This runs the card's own
// open() and close() against a model of the card.
{
  const fnOf = (name) => {
    const m = consent.match(new RegExp('\\n  function ' + name + '\\(([^)]*)\\) \\{([\\s\\S]*?)\\n  \\}'))
    return m ? { params: m[1], body: m[2] } : null
  }
  const pendingExpr = (consent.match(/readonly property bool pending: (.*)/) || [])[1]
  assert(pendingExpr, 'the card says which states are pending')
  const sent = []
  const card = {
    opened: false, state: '', message: '', caller: {}, token: '', closedToken: '',
    riderMinutes: 0, facePresent: false, keyArmed: false, keyPin: false, keyPinSent: false, waiting: false,
    answer(args, secret) { sent.push(args.join(' ') + ' <- ' + card.token) },
  }
  Object.defineProperty(card, 'pending', { get: new Function('root', 'return function() { return ' + pendingExpr + ' }')(card) })
  const autoClose = { interval: 0, restart() {}, stop() {} }
  const field = () => ({ text: '', forceActiveFocus() {} })
  const passwordField = field()
  const keyPinField = field()
  const commandArea = { contentY: 0 }
  const Qt = { callLater: (f) => f() }
  const quiet = { log() {} }
  const bind = (name) => {
    const f = fnOf(name)
    assert(f, `the card has ${name}()`)
    return new Function('root', 'autoClose', 'passwordField', 'keyPinField', 'commandArea', 'Qt', 'console',
      'return function(' + f.params + ') {' + f.body + '}')(card, autoClose, passwordField, keyPinField, commandArea, Qt, quiet)
  }
  card.open = bind('open')
  card.close = bind('close')
  card.expire = bind('expire')
  const show = (token, state) => card.open(JSON.stringify({ token, state, message: '', caller: {} }))

  show('A', 'scanning')
  show('A', 'nod')
  card.close()
  assert(sent.includes('--dismiss <- A'), 'a pending card closed says no, with its own token', JSON.stringify(sent))
  assert(!card.opened, 'a closed card is hidden')
  show('B', 'scanning')
  assert(card.opened && card.token === 'B' && card.state === 'scanning', 'the next request\'s summon after a close is shown, not ignored', JSON.stringify({ opened: card.opened, token: card.token, state: card.state }))
  assert(sent.includes('--ack <- B'), 'and acknowledged to the daemon with its own token', JSON.stringify(sent))

  // A payload for a request whose card was closed, such as a re-send that
  // crossed the close, changes nothing: the daemon never shows a closed
  // request again.
  card.close()
  const before = sent.length
  show('B', 'nod')
  assert(!card.opened && card.token === '' && sent.length === before, 'a late payload for a closed request changes nothing', JSON.stringify({ opened: card.opened, token: card.token, sent: sent.slice(before) }))
  show('C', 'scanning')
  assert(card.opened && card.token === 'C', 'and the request after it is still shown')

  // Expiry is not a close: the daemon's next re-send of a live request
  // brings its card back.
  card.expire()
  show('C', 'nod')
  assert(card.opened && card.token === 'C' && card.state === 'nod', 'a live request\'s re-send after expiry is shown again')
}

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

// The security key: the daemon asks it alongside the nod and says so in the
// payload. The card only shows that a touch works; it sends nothing for the
// key, so no process can answer for it through the card, and a touch ends in
// the daemon's own approved payload, which closes the card as a nod's does.
assert(/root\.keyArmed = payload\.key_armed === true/.test(open[1]), 'open() reads the key from payload.key_armed, true only when the daemon says so')
assert(!/root\.keyArmed = (?!payload\.key_armed === true)/.test(consent), 'nothing but the payload sets keyArmed')
const keyBlock = blocks.find(block => /id: keyHint/.test(block)) || ''
assert(keyBlock, 'the card has a key line')
assert(/visible: root\.pending && root\.keyArmed/.test(keyBlock), 'the key line shows only on a pending request the daemon armed the key for')
assert(/text: root\.keyHintText/.test(keyBlock), 'the key line says what the key needs')
assert(/\? Commons\.I18n\.t\("faceConsent\.keyTouch"\)/.test(consent) && enShell['faceConsent.keyTouch'] === 'Or touch your security key to allow this.', 'without a PIN the key line says a touch allows the request')
// E: a key line that asks for a PIN gets a masked field of its own, shown
// only while the daemon armed the key on a PIN lane. The PIN goes to the
// daemon as the password does: on stdin after the token, never on argv, and
// the field is cleared as it goes and on a new request.
assert(/root\.keyPin = payload\.key_pin === true/.test(open[1]), 'open() reads the PIN lane from payload.key_pin, true only when the daemon says so')
assert(!/root\.keyPin = (?!payload\.key_pin === true)/.test(consent), 'nothing but the payload sets keyPin')
const pinField = consent.split(/\bTextField \{/).slice(1).find(b => /id: keyPinField/.test(b)) || ''
assert(pinField, 'the card has a key PIN field')
assert(/visible: root\.pending && root\.keyArmed && root\.keyPin/.test(pinField), 'the PIN field shows only on a pending request with the key armed on a PIN lane')
assert(/password: true/.test(pinField), 'the PIN field is masked')
assert(/onAccepted: root\.submitKeyPin\(\)/.test(pinField), 'Enter in the PIN field sends the PIN')
const submitPin = consent.match(/function submitKeyPin\(\) \{([\s\S]*?)\n  \}/)
assert(submitPin, 'the card has a submitKeyPin function')
assert(/if \(pin\.length === 0 \|\| !root\.pending \|\| !root\.keyArmed \|\| !root\.keyPin\) return/.test(submitPin[1]), 'it sends nothing unless the daemon asked for a PIN on a pending request')
assert(/keyPinField\.text = ""/.test(submitPin[1]), 'the field is cleared as the PIN goes')
assert(/root\.answer\(\["--key-pin"\], pin\)/.test(submitPin[1]), 'the PIN goes as the secret line of an answer, after the token, never on argv')
const freshBlock = open[1].match(/if \(fresh\) \{([\s\S]*?)\n    \}/)
assert(freshBlock && /keyPinField\.text = ""/.test(freshBlock[1]), 'a new request clears the PIN field')
assert(/if \(payload\.key_pin_wanted === true\) root\.keyPinSent = false/.test(open[1]), 'the card asks for the PIN again whenever the daemon says one is wanted')
assert(/root\.keyPinSent \? Commons\.I18n\.t\("faceConsent\.keyTouchNow"\) : Commons\.I18n\.t\("faceConsent\.keyPinThenTouch"\)/.test(consent) && enShell['faceConsent.keyTouchNow'] === 'Now touch your security key.' && enShell['faceConsent.keyPinThenTouch'] === "Or type your security key's PIN, then touch the key.", 'it says to touch the key only while a PIN it sent is in use')
assert(/textFormat: Text\.PlainText/.test(keyBlock) && /font\.pixelSize: Style\.font\.caption/.test(keyBlock), 'the key line is plain caption text')
assert(!/--key(?!-pin")/.test(consent), 'the card sends no key approval, only the key PIN when asked for one')
assert(/autoClose\.interval = root\.state === "approved" \? 700 : 300000/.test(open[1]), 'an approval, by key or nod, fades the card the same way')

// The card is drawn on the output that holds the camera, chosen once for
// both face overlays in FaceAuthOverlay.
const overlay = fs.readFileSync(path.join(root, 'shell/Ui/FaceAuthOverlay.qml'), 'utf8')
const panelBlock = consent.split(/\bPanelWindow \{/)[1] || ''
assert(/^FaceAuthOverlay \{\n  id: root$/m.test(consent), 'the card is a FaceAuthOverlay')
assert(/screen: root\.cameraScreen/.test(panelBlock), 'the card is bound to the camera screen')
assert(/\/\^eDP\/\.test\(String\(screens\[i\]\.name\)\)/.test(overlay), 'the camera screen is the built-in panel when there is one')

// Fix round 14 (Codex 3): successive answers each reach consent-answer with
// their own stdin. This runs the card's own answer code (its `answer` and,
// when there is one, `nextAnswer` function, and answerProc's handlers, all
// taken from the QML) against a model of Quickshell 0.3.2's Process
// (src/io/process.cpp): `stdinEnabled` belongs to the object, not to one
// launch (setStdinEnabled); a launch made with it off has its write channel
// closed from the start (startProcessIfReady); `running = true` while a
// launch runs only marks the next one, which starts, with whatever command
// is set then, when the running one ends (setRunning, startProcessIfReady,
// onFinished); `started` comes after `running` is set, not within it
// (QProcess::started); and a write reaches the child only while its stdin
// is open. The cards: one's acknowledgment and a PIN typed at once, a PIN
// retried, then the next card's acknowledgment.
{
  const fnOf = (name) => {
    const m = consent.match(new RegExp('\\n  function ' + name + '\\(([^)]*)\\) \\{([\\s\\S]*?)\\n  \\}'))
    return m ? { params: m[1], body: m[2] } : null
  }
  const procBlock = consent.match(/\n  Process \{\n    id: answerProc\n([\s\S]*?)\n  \}/)
  assert(procBlock, 'the card has its answer Process')
  const handlerOf = (name) => {
    const m = procBlock[1].match(new RegExp('    ' + name + ': \\{([\\s\\S]*?)\\n    \\}'))
    return m ? m[1] : null
  }
  const events = []
  const Qt = { callLater: (f) => events.push(f) }
  const launches = []
  const proc = {
    lines: [],
    _command: [], _stdin: /stdinEnabled: true/.test(procBlock[1]), _target: false, current: null,
    get command() { return this._command },
    set command(v) { if (JSON.stringify(v) === JSON.stringify(this._command)) return; this._command = v.slice(); this._start() },
    get stdinEnabled() { return this._stdin },
    set stdinEnabled(v) { if (v === this._stdin) return; this._stdin = v; if (!v && this.current) this.current.stdinOpen = false },
    get running() { return this.current !== null },
    set running(v) { this._target = v; if (v) this._start() },
    _start() {
      if (this.current || !this._target || this._command.length === 0) return
      this._target = false
      this.current = { args: this._command.slice(2), stdinOpen: this._stdin, got: '' }
      launches.push(this.current)
      events.push(() => this._handle('onStarted'))
    },
    write(data) { if (this.current && this.current.stdinOpen) this.current.got += data },
    _handle(name) {
      const body = handlerOf(name)
      if (body === null) return
      // The QML handler's scope: the Process's own properties, then the card's.
      new Function('proc', 'root', 'answerProc', 'Qt', 'with (proc) {' + body + '}')(this, card, this, Qt)
    },
    _finish() {
      this.current = null
      this._handle('onExited')
      this._handle('onRunningChanged')
      this._start()
    },
  }
  const card = { token: '', answerQueue: [] }
  for (const name of ['answer', 'nextAnswer']) {
    const f = fnOf(name)
    if (f) card[name] = new Function('root', 'answerProc', 'Qt', 'return function(' + f.params + ') {' + f.body + '}')(card, proc, Qt)
  }
  const drain = () => { while (events.length > 0) events.shift()() }
  const answered = () => { drain(); while (proc.current) { proc._finish(); drain() } }
  card.token = 'A'
  card.answer(['--ack'], '')
  card.answer(['--key-pin'], '1234')
  answered()
  card.answer(['--key-pin'], '5678')
  answered()
  card.token = 'B'
  card.answer(['--ack'], '')
  answered()
  const seen = launches.map(l => l.args.join(' ') + ' <- ' + JSON.stringify(l.got))
  const want = ['--ack <- "A\\n"', '--key-pin <- "A\\n1234\\n"', '--key-pin <- "A\\n5678\\n"', '--ack <- "B\\n"']
  assert(JSON.stringify(seen) === JSON.stringify(want), 'every answer reaches its own consent-answer with its token and its PIN, one after another', JSON.stringify(seen, null, 1))
  assert(launches.every(l => !l.stdinOpen), 'each answer\'s stdin is closed after its lines, so consent-answer reads to its end')
}
JS
