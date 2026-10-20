import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Opened by faceauthd (root) through `omarchy-shell -s shell summon omarchy.faceauth`
// for every elevation request, so no sudo or polkit request can proceed without
// a window on the desktop. The payload, answer token included, reaches the shell
// over its own socket from omarchy-shell's stdin, so no command line shows it. It informs and it can kill; it cannot approve. The
// approval is a nod the daemon watches for on its own camera, the account
// password typed here and checked by the daemon against the system PAM stack,
// or a touch of the user's security key, which the daemon asks for itself.
// The window stays until the request is approved, refused, dismissed or the
// requester killed. While a request waits the daemon re-sends it every
// minute; a card no daemon has spoken to for five minutes hides itself
// without answering, so a dead daemon leaves no card and a live request is
// never refused by the card's own clock.
// The card shows two lines: what is being asked, labeled by whether the
// daemon read it from /proc itself or the requesting side relayed it, and
// who asked, as the daemon found it in /proc.
// FaceAuthOverlay gives the card the menu's palette and the camera's screen:
// the foreground for the border and title, the theme accent only where
// something is positive (Approve, the armed note), red only for the refusal.
FaceAuthOverlay {
  id: root

  property bool opened: false
  property string state: ""
  property string message: ""
  property var caller: ({})

  // Wide enough for the passwordless row and the three answer buttons to
  // sit on their own lines without wrapping or crowding.
  readonly property int cardWidth: Math.min(Style.space(760), panel.width - Style.gapsOut * 2)

  // Line 1: what is being asked. `verified` is true when the daemon read the
  // command line from /proc itself; false when the text was relayed from the
  // requesting side (a polkit action description), which the daemon cannot
  // check. The label says which, and comes first so wrapping cannot hide it.
  readonly property bool verified: (root.caller || {}).verified === true
  // Once a passwordless rider is armed, what the nod approves includes
  // it, so the line the user reads says so. The rider comes from the
  // daemon's payload, never from this card's own button press: the card
  // shows what the daemon will grant, and nothing armed over the socket
  // can hide from the card.
  // The command is appended in code, never through .arg(), so a translation
  // can relabel the line but cannot drop what it runs.
  readonly property string commandLine: (root.verified ? Commons.I18n.t("faceConsent.runAsRoot") : Commons.I18n.t("faceConsent.unverified")) + " " + String((root.caller || {}).command || "") + (root.passwordlessArmed.length > 0 ? "  " + Commons.I18n.t("faceConsent.passwordlessRider").arg(root.passwordlessArmed) : "") + ((root.caller || {}).clipped === true ? "  " + Commons.I18n.t("faceConsent.commandClipped") : "")

  // Line 2: who asked, as the daemon found it in /proc.
  readonly property string requesterText: Commons.I18n.t("faceConsent.requester") + " " + String((root.caller || {}).who || "")

  // The window owns its own lifetime. A final state lingers long enough to be
  // read (an approval briefly, a refusal longer so kill can still be
  // used); a live state stays up for the daemon, which re-sends it every
  // minute, and if the daemon dies or its hide call is lost the window
  // still hides itself. Expiry hides without answering: the daemon owns the
  // request, and a card that went quiet is not the user saying no.
  Timer {
    id: autoClose
    interval: 30000
    repeat: false
    onTriggered: root.expire()
  }

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(String(payloadJson || "{}")) } catch (e) { payload = {} }
    var token = String(payload.token || "")
    // A request whose card was closed is over (close()).
    if (token.length > 0 && token === root.closedToken) return
    // While a request is pending the window is that request's: only a
    // payload carrying its token may change what is shown or end it. The
    // daemon serializes requests, so a summon with another token while one
    // is pending is not the daemon's next request; it is something of the
    // user's imitating the daemon, and it changes nothing.
    if (root.pending && token !== root.token) {
      console.log("omarchy faceauth: ignored a summon that does not carry the pending request's token")
      return
    }
    var fresh = !root.opened || token !== root.token
    root.state = String(payload.state || "")
    // Pending states and refusals stay until a verdict, a button or Escape;
    // only an approval fades on its own. The long interval is a safety net for
    // a daemon that died mid-request.
    autoClose.interval = root.state === "approved" ? 700 : 300000
    autoClose.restart()
    root.message = String(payload.message || "")
    root.caller = payload.caller || {}
    // The rider and the face, as the daemon knows them. A payload that
    // changes the rider is a card the user has not read yet: the daemon
    // reads no nod until this window acknowledges it again.
    var riderChanged = Number(payload.passwordless_minutes || 0) !== root.riderMinutes
    root.riderMinutes = Number(payload.passwordless_minutes || 0)
    root.facePresent = payload.face_present === true
    root.keyArmed = payload.key_armed === true
    root.keyPin = payload.key_pin === true
    // The daemon asks for the PIN again once a PIN has been spent on a
    // check that ended without a touch.
    if (payload.key_pin_wanted === true) root.keyPinSent = false
    root.waiting = payload.waiting === true
    root.opened = true
    if (fresh) {
      // A new request: nothing typed for the last one carries over, the
      // field is focused (a state change while the user is typing must not
      // steal it), and the daemon is told this window has drawn the
      // request. It reads no nod until that arrives.
      root.token = token
      passwordField.text = ""
      keyPinField.text = ""
      root.keyPinSent = false
      commandArea.contentY = 0
      Qt.callLater(function() { passwordField.forceActiveFocus() })
    }
    // The daemon also asks outright when it holds no acknowledgment for
    // this show: the card coming back after an unlock is read afresh.
    if (token.length > 0 && (fresh || riderChanged || payload.ack_wanted === true)) root.answer(["--ack"], "")
  }

  property string token: ""
  readonly property bool pending: root.state === "scanning" || root.state === "nod" || root.state === "confirming" || root.state === "password" || root.state === "locked"
  // The daemon counts nods only from the scan's match. The status line
  // shows that moment in the accent and in bold, so a nod made while the
  // face was still being looked for, and not counted, is not taken for one
  // that was. A card waiting for "Ready to nod" counts none and stays plain,
  // and so does one whose face has left the camera's view: the daemon counts
  // nothing until it is back. A card that names a passwordless rider stays
  // plain too: the daemon holds its nods back a moment, and the eye belongs
  // on the rider's warning.
  readonly property bool nodNow: root.state === "nod" && !root.waiting && root.facePresent && root.riderMinutes === 0
  readonly property color statusColor: root.state === "denied" ? Commons.Color.polkit.textError : (root.nodNow ? root.accent : root.foreground)
  // The request whose card was last closed. The daemon never shows a
  // request again once its card is closed, so a payload for it that
  // arrives late (a re-send that crossed the close) changes nothing.
  property string closedToken: ""

  function close() {
    autoClose.stop()
    var wasPending = root.pending
    if (root.pending) root.answer(["--dismiss"], "")
    root.opened = false
    passwordField.text = ""
    // A closed card is over, whoever closed it: Dismiss or Escape (whose no
    // above already carries the token), or the daemon's hide after a head
    // shake or a requester gone. Holding its token as pending would turn
    // the next request's summon away (live test 2, 2026-10-13).
    if (root.token.length > 0) root.closedToken = root.token
    root.state = ""
    root.token = ""
    // Each close is logged, with whether it said no (round 19): a no that
    // never reached the daemon leaves a trace.
    console.log("omarchy faceauth: card closed, " + (wasPending ? "no sent" : "nothing pending"))
  }

  // The safety net: hide, answer nothing. A live request keeps waiting in
  // the daemon and comes back with its next re-send.
  function expire() {
    autoClose.stop()
    root.opened = false
    // The request the window was holding is over as far as the window is
    // concerned: a later summon with a new token must not be ignored for it.
    root.state = ""
    root.token = ""
    passwordField.text = ""
  }

  // After a nod window passed unanswered the daemon disarms the nods until
  // the enrolled face is back at the card, or the user says so here. The
  // button re-arms; it approves nothing.
  property bool waiting: false

  // The daemon is asking the user's security key alongside the nod, so a
  // touch approves too. Only the payload sets it; a touch closes the card
  // with the daemon's approval, as a nod does.
  property bool keyArmed: false
  // The key's line in the stack asks for its PIN: the card takes it in a
  // field of its own and hands it to the daemon like the password, on stdin
  // with the token, for one check of the key. Only the payload sets it.
  property bool keyPin: false
  property bool keyPinSent: false
  readonly property string keyHintText: !root.keyPin
    ? Commons.I18n.t("faceConsent.keyTouch")
    : (root.keyPinSent ? Commons.I18n.t("faceConsent.keyTouchNow") : Commons.I18n.t("faceConsent.keyPinThenTouch"))

  function submitKeyPin() {
    var pin = keyPinField.text
    if (pin.length === 0 || !root.pending || !root.keyArmed || !root.keyPin) return
    keyPinField.text = ""
    root.keyPinSent = true
    root.answer(["--key-pin"], pin)
  }

  function readyToNod() {
    if (!root.pending || !root.waiting) return
    root.answer(["--rearm"], "")
  }

  // Send an answer for the pending request to the daemon. The token from
  // the payload goes first on stdin, the password (if any) second; nothing
  // secret is ever on argv. The daemon accepts it only while this user's
  // request is live, and only from this user's own uid. Answers queue,
  // each with the token it was given for, and run one at a time, oldest
  // first (nextAnswer).
  property var answerQueue: []

  function answer(args, secret) {
    root.answerQueue = root.answerQueue.concat([{ kind: args.length > 0 ? args[0] : "password", token: root.token, args: args, lines: [root.token].concat(secret.length > 0 ? [secret] : []) }])
    root.nextAnswer()
  }

  // The oldest waiting answer, once no other is running (fix round 14, Codex
  // 3). Quickshell's Process keeps one stdinEnabled for all its launches,
  // and a launch made with it off has its stdin closed from the start
  // (src/io/process.cpp, setStdinEnabled, startProcessIfReady), so it is
  // turned back on before each one. `running = true` while a launch runs
  // only marks the next for when it ends, with whatever command and lines
  // are set by then (setRunning, onFinished), so nothing is set until the
  // last one is over.
  function nextAnswer() {
    if (answerProc.running || root.answerQueue.length === 0) return
    var next = root.answerQueue[0]
    root.answerQueue = root.answerQueue.slice(1)
    // Logged by kind alone, never its lines (round 19).
    answerProc.kind = next.kind
    answerProc.answerToken = next.token
    answerProc.launched = false
    console.log("omarchy faceauth: answer " + next.kind + " sent")
    answerProc.lines = next.lines
    answerProc.stdinEnabled = true
    answerProc.command = ["/usr/bin/faceauth", "consent-answer"].concat(next.args)
    answerProc.running = true
  }

  // An answer whose consent-answer never started (Codex 19, 1): logged, and
  // a no among them never reached the daemon.
  function answerFailedToStart(kind, token) {
    console.log("omarchy faceauth: answer " + kind + " did not start")
    if (kind === "--dismiss") root.noNotTaken(token)
  }

  // A no for `token` that the daemon did not take (Codex 19, 1): the card
  // lets go of its close, so a request still waiting, its key armed, gets
  // its card back with the daemon's next re-send. It draws nothing itself
  // (Codex 19b N1): a request the daemon has ended is never re-sent, and a
  // card redrawn from its last payload could revive one and turn the next
  // request away.
  function noNotTaken(token) {
    if (token.length > 0 && root.closedToken === token) root.closedToken = ""
  }

  function submitPassword() {
    var pw = passwordField.text
    if (pw.length === 0 || !root.pending) return
    passwordField.text = ""
    root.answer([], pw)
  }

  Process {
    id: answerProc
    property var lines: []
    property string kind: ""
    property string answerToken: ""
    // Whether this launch started (Codex 19, 1): one that fails to start
    // ends with no exit at all, and is caught when it stops running.
    property bool launched: false
    stdinEnabled: true
    // Its lines, then the end of its stdin, so consent-answer reads to it.
    onStarted: {
      launched = true
      for (var i = 0; i < lines.length; i++) write(lines[i] + "\n")
      lines = []
      stdinEnabled = false
    }
    // How it ended, by kind (round 19): consent-answer exits 0 when the
    // daemon took the answer.
    onExited: function(exitCode, exitStatus) {
      console.log("omarchy faceauth: answer " + kind + " ended with " + exitCode)
      // A no that did not get through lets go of the card's close.
      if (kind === "--dismiss" && exitCode !== 0) root.noNotTaken(answerToken)
    }
    // Ended, or failed to start: the next answer's turn.
    onRunningChanged: {
      if (!running && !launched) root.answerFailedToStart(kind, answerToken)
      if (!running) Qt.callLater(root.nextAnswer)
    }
  }

  // Passwordless sudo for a while, from the card. The button approves
  // nothing on its own: it tells the daemon, with this request's token,
  // that the approval of this request should also turn passwordless sudo
  // on for the minutes typed. The nod (or the password) that approves the
  // request is the only consent; nothing else appears, and the daemon
  // writes the same rule and expiry timer Omarchy's own command would.
  // Only on a sudo request: polkit is not covered by the sudoers rule.
  // The button is grayed unless the daemon says the enrolled face is in
  // frame right now (`face_present` in the payload); the daemon refuses
  // an arm otherwise too, so the socket is no wider than the button.
  readonly property bool sudoRequest: String((root.caller || {}).via || "") === "sudo" && !/(^|[\s\/])omarchy-sudo-passwordless(\s|$)/.test(String((root.caller || {}).command || ""))
  readonly property string passwordlessMinutes: {
    var m = parseInt(String(minutesField.text || "").trim(), 10)
    return (m > 0 && m <= 1440) ? String(m) : ""
  }
  // From the payload: the minutes the daemon has armed on this request,
  // and whether the enrolled face is in the nod window now.
  property int riderMinutes: 0
  property bool facePresent: false
  readonly property string passwordlessArmed: root.riderMinutes > 0 ? String(root.riderMinutes) : ""
  // Omarchy's own command says this before it turns the rule on; the card
  // says the same, in the same words.
  readonly property string passwordlessWarning: Commons.I18n.t("faceConsent.passwordlessWarning").arg(root.passwordlessArmed.length > 0 ? root.passwordlessArmed : (root.passwordlessMinutes.length > 0 ? root.passwordlessMinutes : "?"))

  function armPasswordless() {
    if (root.passwordlessMinutes.length === 0 || !root.pending || !root.facePresent) return
    root.answer(["--passwordless", root.passwordlessMinutes], "")
  }

  // Deny and kill (round 19, live test 2): the no first, then faceauth ends
  // the process the daemon pinned for this card, named by pid and pidfs id,
  // so a pid another process holds by then is never signalled. With no
  // pinned process the button is hidden, and this kills nothing.
  readonly property bool killPinned: Number((root.caller || {}).kill_pid || 0) > 1 && /^[1-9][0-9]*$/.test(String((root.caller || {}).kill_ino || ""))

  function killRequester() {
    var caller = root.caller || {}
    var pid = Number(caller.kill_pid || 0)
    var ino = String(caller.kill_ino || "")
    root.close()
    if (pid > 1 && /^[1-9][0-9]*$/.test(ino)) {
      killProc.command = ["/usr/bin/faceauth", "kill-requester", "--pid", String(pid), "--ino", ino]
      killProc.running = true
    }
  }

  Process { id: killProc }

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.cameraScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-faceauth"
    WlrLayershell.layer: WlrLayer.Overlay
    // Never exclusive: this window informs and offers a nod, a shake, the
    // password, a dismissal or, for a named requester, a kill; it must not
    // be able to hold the keyboard hostage if the daemon fails to hide it.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: column.implicitHeight + Style.spacing.panelPadding * 2
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
          }
        }
      }

      Column {
        id: column
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding
        spacing: Style.spacing.md

        Text {
          width: parent.width
          text: Commons.I18n.t("faceConsent.title")
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        // The whole command, wrapped, never cut: no line limit and no
        // elision, so nothing is hidden. The area grows with the command up to
        // two fifths of the screen and then scrolls, so a long command, or one
        // full of line separators, cannot push the requester line and the
        // buttons off the card. The card is a layer surface that cannot be
        // moved, so anything pushed off it would be unreachable.
        Flickable {
          id: commandArea
          width: parent.width
          readonly property int maxHeight: panel.height > 0 ? Math.round(panel.height * 0.4) : commandText.implicitHeight
          height: Math.min(commandText.implicitHeight, commandArea.maxHeight)
          contentWidth: width
          contentHeight: commandText.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }

          Text {
            id: commandText
            width: commandArea.width
            text: root.commandLine
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
          }
        }

        Text {
          width: parent.width
          text: root.requesterText
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.9
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        }

        Rectangle { width: parent.width; height: 1; color: root.foreground; opacity: 0.15 }

        Row {
          spacing: Style.spacing.md
          width: parent.width

          Text {
            text: root.state === "approved" ? "󰖎" : (root.state === "denied" ? "󰅙" : "󰵃")
            textFormat: Text.PlainText
            color: root.statusColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            width: parent.width - Style.space(48)
            text: root.message
            textFormat: Text.PlainText
            color: root.statusColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: root.nodNow
            wrapMode: Text.Wrap
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Text {
          id: keyHint
          width: parent.width
          visible: root.pending && root.keyArmed
          text: root.keyHintText
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.9
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        }

        TextField {
          id: keyPinField
          width: parent.width
          visible: root.pending && root.keyArmed && root.keyPin
          password: true
          placeholderText: Commons.I18n.t("faceConsent.keyPinPlaceholder")
          foreground: root.foreground
          accent: root.accent
          font.family: root.fontFamily
          onAccepted: root.submitKeyPin()
          Keys.onEscapePressed: root.close()
        }

        TextField {
          id: passwordField
          width: parent.width
          visible: root.pending
          password: true
          placeholderText: Commons.I18n.t("faceConsent.passwordPlaceholder")
          foreground: root.foreground
          accent: root.accent
          font.family: root.fontFamily
          onAccepted: root.submitPassword()
          Keys.onEscapePressed: root.close()
        }

        // Upstream's warning, shown while the user is at the minutes field
        // and for as long as a rider is armed.
        Text {
          id: passwordlessWarningText
          width: parent.width
          visible: root.sudoRequest && root.pending && (root.passwordlessArmed.length > 0 || minutesField.activeFocus)
          text: root.passwordlessWarning
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.9
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        }

        // One line: the passwordless controls on the left, set apart from
        // the answer buttons on the right, all centered on the same axis.
        Item {
          width: parent.width
          height: Math.max(passwordlessRow.implicitHeight, answerRow.implicitHeight)

          Row {
            id: passwordlessRow
            spacing: Style.spacing.sm
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: root.sudoRequest && root.pending

            TextField {
              id: minutesField
              // Room for three digits, up to a day.
              width: Style.space(52)
              visible: root.passwordlessArmed.length === 0
              enabled: root.facePresent
              opacity: root.facePresent ? 1.0 : 0.4
              anchors.verticalCenter: parent.verticalCenter
              text: "15"
              placeholderText: "min"
              foreground: root.foreground
              accent: root.accent
              font.family: root.fontFamily
              onAccepted: root.armPasswordless()
              Keys.onEscapePressed: root.close()
            }

            Button {
              visible: root.passwordlessArmed.length === 0
              // Grayed until the daemon reports the enrolled face in frame:
              // the person at the camera arms it, nothing else does.
              enabled: root.passwordlessMinutes.length > 0 && root.facePresent
              opacity: root.facePresent ? 1.0 : 0.4
              anchors.verticalCenter: parent.verticalCenter
              text: root.facePresent ? Commons.I18n.t("faceConsent.passwordlessFor").arg(root.passwordlessMinutes.length > 0 ? root.passwordlessMinutes : "?") : Commons.I18n.t("faceConsent.passwordlessLook")
              bordered: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.armPasswordless()
            }

            Text {
              visible: root.passwordlessArmed.length > 0
              anchors.verticalCenter: parent.verticalCenter
              text: Commons.I18n.t("faceConsent.passwordlessArmed").arg(root.passwordlessArmed)
              textFormat: Text.PlainText
              color: root.accent
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Row {
            id: answerRow
            spacing: Style.spacing.sm
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Button {
              // Only when the daemon could name the requester and pinned it:
              // for a plain polkit action there is no known process to end.
              visible: root.verified && root.killPinned
              anchors.verticalCenter: parent.verticalCenter
              text: Commons.I18n.t("faceConsent.denyAndKill")
              bordered: true
              foreground: Commons.Color.polkit.textError
              accent: Commons.Color.polkit.textError
              fontFamily: root.fontFamily
              onClicked: root.killRequester()
            }

            Button {
              visible: root.pending && root.waiting
              anchors.verticalCenter: parent.verticalCenter
              text: Commons.I18n.t("faceConsent.readyToNod")
              bordered: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.readyToNod()
            }

            Button {
              anchors.verticalCenter: parent.verticalCenter
              text: Commons.I18n.t("faceConsent.dismiss")
              bordered: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.close()
            }

            Button {
              // The mouse form of Enter in the password field: it submits the
              // typed password and nothing else. Without one there is only
              // the nod.
              visible: root.pending
              enabled: passwordField.text.length > 0
              anchors.verticalCenter: parent.verticalCenter
              text: Commons.I18n.t("faceConsent.approve")
              bordered: true
              foreground: root.accent
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.submitPassword()
            }
          }
        }
      }
    }
  }
}
