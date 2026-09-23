import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Opened by faceauthd (root) through `omarchy-shell shell summon omarchy.faceauth`
// for every elevation request, so no sudo or polkit request can proceed without
// a window on the desktop. It informs and it can kill; it cannot approve. The
// approval is a nod the daemon watches for on its own camera, or the account
// password typed here and checked by the daemon against the system PAM stack.
// The window stays until the request is approved, refused, dismissed or the
// requester killed; it never times out on its own while a request is live.
// The card shows two lines: what is being asked, labelled by whether the
// daemon read it from /proc itself or the requesting side relayed it, and
// who asked, as the daemon found it in /proc.
Item {
  id: root

  property bool opened: false
  property string state: ""
  property string message: ""
  property var caller: ({})
  property real seconds: 0

  readonly property string fontFamily: Style.font.menuFamily
  readonly property color background: Color.polkit.background
  readonly property color foreground: Color.polkit.text
  readonly property color accent: Color.polkit.accent
  readonly property color scrim: Color.polkit.scrim
  readonly property var borderSpec: Border.surfaceSpec("polkit", "border", Color.polkit.border, Math.max(1, Style.space(2)), "border-alpha")
  readonly property int cornerRadius: Style.cornerRadius
  readonly property int cardWidth: Math.min(Style.space(560), panel.width - Style.gapsOut * 2)

  // Line 1: what is being asked. `verified` is true when the daemon read the
  // command line from /proc itself; false when the text was relayed from the
  // requesting side (a polkit action description), which the daemon cannot
  // check. The label says which, and comes first so wrapping cannot hide it.
  readonly property bool verified: (root.caller || {}).verified === true
  readonly property string commandLine: (root.verified ? "Run as root: " : "Unverified: ") + String((root.caller || {}).command || "")

  // Line 2: who asked, as the daemon found it in /proc.
  readonly property string requesterText: "Requester: " + String((root.caller || {}).who || "")

  // The window owns its own lifetime. A final state lingers long enough to be
  // read (an approval briefly, a refusal longer so kill can still be
  // used); a live state stays up for the daemon, and if the daemon dies or
  // its hide call is lost the window still closes itself.
  Timer {
    id: autoClose
    interval: 30000
    repeat: false
    onTriggered: root.close()
  }

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(String(payloadJson || "{}")) } catch (e) { payload = {} }
    var token = String(payload.token || "")
    // While a request is pending the window is that request's: only a
    // payload carrying its token may change what is shown or end it. The
    // daemon serialises requests, so a summon with another token while one
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
    root.seconds = Number(payload.seconds || 0)
    root.opened = true
    if (fresh) {
      // A new request: nothing typed for the last one carries over, the
      // field is focused (a state change while the user is typing must not
      // steal it), and the daemon is told this window has drawn the
      // request. It reads no nod until that arrives.
      root.token = token
      passwordField.text = ""
      Qt.callLater(function() { passwordField.forceActiveFocus() })
      if (token.length > 0) root.answer(["--ack"], "")
    }
  }

  // The card is drawn on the output that holds the camera: the laptop's own
  // panel when there is one, else the first output. A card on a screen the
  // user is not facing is a card the user is not nodding at.
  readonly property var cameraScreen: {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (/^eDP/.test(String(screens[i].name))) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  property string token: ""
  readonly property bool pending: root.state === "scanning" || root.state === "nod" || root.state === "confirming" || root.state === "password" || root.state === "locked"

  function close() {
    autoClose.stop()
    if (root.pending) root.answer(["--dismiss"], "")
    root.opened = false
    passwordField.text = ""
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
    // Never exclusive: this window informs and offers kill/block; it must not
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
          text: "Root access requested"
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          width: parent.width
          // The whole command, wrapped, never cut: the daemon caps it at 2000
          // characters. No line limit and no elision, so nothing is hidden.
          text: root.commandLine
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WrapAtWordBoundaryOrAnywhere
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
            color: root.state === "denied" ? Color.polkit.textError : root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            width: parent.width - Style.space(48)
            text: root.message
            textFormat: Text.PlainText
            color: root.state === "denied" ? Color.polkit.textError : root.foreground
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
          placeholderText: "Password (instead of a nod or a shake)"
          foreground: root.foreground
          accent: root.accent
          font.family: root.fontFamily
          onAccepted: root.submitPassword()
          Keys.onEscapePressed: root.close()
        }

        Row {
          spacing: Style.spacing.sm
          anchors.right: parent.right

          Button {
            // Only when the daemon could name the requester: for a plain
            // polkit action there is no known process to end.
            visible: root.verified
            text: "Deny and kill"
            bordered: true
            foreground: Color.polkit.textError
            accent: Color.polkit.textError
            fontFamily: root.fontFamily
            onClicked: root.killRequester()
          }

          Button {
            text: "Dismiss"
            bordered: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.close()
          }
        }
      }
    }
  }
}
