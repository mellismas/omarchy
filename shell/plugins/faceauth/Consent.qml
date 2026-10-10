import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Opened by faceauthd (root) through `omarchy-shell shell summon omarchy.faceauth`
// for every elevation request, so no sudo or polkit request can proceed without
// a window on the desktop. It informs and it can kill; it cannot approve. The
// approval is a nod the daemon watches for on its own camera, or the account
// password typed here and checked by the daemon against the system PAM stack.
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
    root.waiting = payload.waiting === true
    root.opened = true
    if (fresh) {
      // A new request: nothing typed for the last one carries over, the
      // field is focused (a state change while the user is typing must not
      // steal it), and the daemon is told this window has drawn the
      // request. It reads no nod until that arrives.
      root.token = token
      passwordField.text = ""
      commandArea.contentY = 0
      Qt.callLater(function() { passwordField.forceActiveFocus() })
    }
    if (token.length > 0 && (fresh || riderChanged)) root.answer(["--ack"], "")
  }

  property string token: ""
  readonly property bool pending: root.state === "scanning" || root.state === "nod" || root.state === "confirming" || root.state === "password" || root.state === "locked"

  function close() {
    autoClose.stop()
    if (root.pending) root.answer(["--dismiss"], "")
    root.opened = false
    passwordField.text = ""
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

  function readyToNod() {
    if (!root.pending || !root.waiting) return
    root.answer(["--rearm"], "")
  }

  // Send an answer for the pending request to the daemon. The token from
  // the payload goes first on stdin, the password (if any) second; nothing
  // secret is ever on argv. The daemon accepts it only while this user's
  // request is live, and only from this user's own uid.
  function answer(args, secret) {
    answerProc.lines = [root.token].concat(secret.length > 0 ? [secret] : [])
    answerProc.command = ["/usr/bin/faceauth", "consent-answer"].concat(args)
    answerProc.running = true
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
    stdinEnabled: true
    onStarted: {
      for (var i = 0; i < lines.length; i++) write(lines[i] + "\n")
      lines = []
      stdinEnabled = false
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

  function killRequester() {
    var pid = Number((root.caller || {}).kill_pid || 0)
    if (pid > 1) {
      killProc.command = ["/usr/bin/kill", "-TERM", String(pid)]
      killProc.running = true
    }
    root.close()
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
            color: root.state === "denied" ? Commons.Color.polkit.textError : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            width: parent.width - Style.space(48)
            text: root.message
            textFormat: Text.PlainText
            color: root.state === "denied" ? Commons.Color.polkit.textError : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
            anchors.verticalCenter: parent.verticalCenter
          }
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
              // Only when the daemon could name the requester: for a plain
              // polkit action there is no known process to end.
              visible: root.verified
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
