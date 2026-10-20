import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Polkit
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "PolkitModel.js" as PolkitModel

Item {
  id: root

  property string fontFamily: Style.font.menuFamily
  // Bound to the central [polkit] section in shell.toml via Commons.Color.qml.
  property color accent: Commons.Color.polkit.accent
  property color background: Commons.Color.polkit.background
  property color foreground: Commons.Color.polkit.text
  property color border: Commons.Color.polkit.border
  property color borderError: Commons.Color.polkit.borderError
  property var borderSpec: Border.surfaceSpec("polkit", errorFlash ? "border-error" : "border", errorFlash ? borderError : border, Math.max(1, Style.space(2)), "border-alpha")
  property color scrim: Commons.Color.polkit.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int fieldHeight: Math.max(Style.space(42), Style.spacing.controlHeight)

  property bool closing: false
  property bool submitted: false
  property string currentMessage: ""
  property string currentPrompt: ""
  property string currentSupplementary: ""
  property bool responseRequired: false
  property bool responseVisible: false
  property bool failed: false
  property bool errorFlash: false
  // pam_fprintd appears in the polkit PAM stack (a sensor is enrolled).
  property bool fingerprintConfigured: false
  // pam_faceauth with consent is in the stack: the face daemon's own window
  // handles the request, and this dialog only appears once PAM wants a password.
  property bool faceConfigured: false
  // Lid shut right now — the reader is physically unreachable, so we fall back
  // to the password even when a sensor is enrolled. Refreshed per request.
  property bool laptopClosed: false
  property int shakeOffset: 0

  readonly property bool faceMode: faceConfigured && agentActive && !responseRequired && !submitted && !errorFlash
  // Set when a face refusal is being turned into a cancel: polkit asks for a
  // password in the instant before the cancel lands, and the dialog must not
  // flash for that.
  property bool refusing: false
  readonly property bool dialogVisible: (agentActive || closing) && !faceMode && !refusing
  // We show one method at a time. Fingerprint owns the dialog while PAM is
  // waiting on the reader (lid open, sensor enrolled); the moment PAM asks for
  // a password — including immediately when the lid is shut and the clamshell
  // gate skips pam_fprintd — we switch to the password field instead.
  readonly property bool fingerprintMode: fingerprintConfigured && !laptopClosed && dialogVisible && !faceMode && !responseRequired && !submitted && !errorFlash
  readonly property int cardHeight: panel.height > 0 ? Math.min(fieldHeight + contentMargin * 2, panel.height - Style.gapsOut * 2) : fieldHeight + contentMargin * 2
  // Password mode is a wide field; fingerprint mode collapses to a square that
  // just frames the centered sensor icon.
  readonly property int cardWidth: fingerprintMode ? cardHeight : Math.min(Style.space(312), Math.max(Style.space(260), panel.width - Style.gapsOut * 2))

  function authorizationLabel(message) {
    return message ? PolkitModel.authorizationLabel(message, I18n.t) : I18n.t("polkit.authenticationNeeded")
  }

  function loadPamConfig(raw) {
    fingerprintConfigured = PolkitModel.fingerprintConfiguredFromPamConfig(raw)
    faceConfigured = PolkitModel.faceConsentConfiguredFromPamConfig(raw)
  }

  function refreshLidState() {
    if (!laptopClosedProc.running) laptopClosedProc.running = true
  }

  function resetSnapshot() {
    currentMessage = ""
    currentPrompt = ""
    currentSupplementary = ""
    responseRequired = false
    responseVisible = false
    failed = false
    errorFlash = false
    submitted = false
    passwordInput.text = ""
  }

  function syncFromFlow() {
    var flow = polkitAgent ? polkitAgent.flow : null
    if (!flow) return

    // pam_faceauth asks, through polkit's own helper, for the cookie of the
    // request it serves, so the face card names this request and no other.
    // Answered at once with the question's challenge and never shown, even
    // when it carries no challenge; with face not configured the agent
    // never said it answers, so no cookie is given.
    if (flow.isResponseRequired && PolkitModel.isFaceauthCookiePrompt(flow.inputPrompt)) {
      flow.submit(PolkitModel.faceauthCookieAnswer(flow.inputPrompt, root.faceConfigured ? flow.cookie : ""))
      return
    }

    currentMessage = String(flow.message || "")
    currentPrompt = String(flow.inputPrompt || "")
    currentSupplementary = String(flow.supplementaryMessage || "")
    responseRequired = !!flow.isResponseRequired
    responseVisible = !!flow.responseVisible
    failed = !!flow.failed

    if (responseRequired) submitted = false
  }

  property bool detailsWarned: false

  // The face daemon's consent window names the request; polkit's helper
  // carries nothing about it, so the agent, which heard the action and the
  // message from polkitd, tells the daemon as the request starts. It must
  // do so over its own connection, not through a child process: the daemon
  // serves a context only to a request whose helper systemd says was
  // connected by the very process that sent it, so a description planted
  // by some other process of the user's never labels a request.
  function tellFaceauth() {
    var flow = polkitAgent ? polkitAgent.flow : null
    if (!flow) { console.log("omarchy polkit: no flow to tell faceauth about"); return }
    if (!faceConfigured) { console.log("omarchy polkit: face not configured, not telling faceauth"); return }
    console.log("omarchy polkit: telling faceauth about " + flow.actionId)
    // Said once per shell, not per request: a stock Quickshell without the
    // details property works, just with the requester unverified on the card.
    if (flow.details === undefined && !root.detailsWarned) {
      root.detailsWarned = true
      console.warn("omarchy polkit: this Quickshell does not expose polkit request details; the face card will show the requester unverified")
    }
    // polkitd attaches the pid of the process that asked it (from that
    // process's D-Bus credentials) and of the process the authorization is
    // for. A Quickshell that exposes the request's details passes them on;
    // the daemon reads the requester from /proc itself and shows it as
    // verified. Without them the card shows polkit's text, unverified.
    var details = flow.details || {}
    var context = {
      user: String(Quickshell.env("USER") || ""),
      context_action: String(flow.actionId || ""),
      context_message: String(flow.message || ""),
      context_cookie: String(flow.cookie || ""),
      // pam_faceauth may ask for that cookie through polkit's helper
      // (syncFromFlow answers it), which ties this context to the request.
      // Named by the prompt's own text, so the daemon asks only a shell that
      // answers exactly that prompt.
      context_cookie_prompt: PolkitModel.FACEAUTH_COOKIE_PROMPT
    }
    var callerPid = parseInt(String(details["polkit.caller-pid"] || ""), 10)
    var subjectPid = parseInt(String(details["polkit.subject-pid"] || ""), 10)
    if (callerPid > 0) context.context_caller_pid = callerPid
    if (subjectPid > 0) context.context_subject_pid = subjectPid
    contextSocket.pending = JSON.stringify(context) + "\n"
    contextSocket.connected = false
    contextSocket.connected = true
  }

  Socket {
    id: contextSocket
    path: "/run/faceauth/sock"
    property string pending: ""
    onConnectionStateChanged: {
      if (!connected || pending.length === 0) return
      write(pending)
      flush()
      pending = ""
    }
    parser: SplitParser {
      onRead: line => { console.log("omarchy polkit: faceauth answered " + line); contextSocket.connected = false }
    }
    onError: error => console.log("omarchy polkit: faceauth socket error " + error)
  }

  function beginFlow() {
    closeTimer.stop()
    closing = false
    refusing = false
    submitted = false
    // The close (endFlow) can hand this request a failure still flashing
    // from the one before it: that flash is not this request's.
    errorTimer.stop()
    errorFlash = false
    passwordInput.text = ""
    refreshLidState()
    syncFromFlow()
    Qt.callLater(refocus)
  }

  function refocus() {
    if (!dialogVisible) return
    // In fingerprint mode there is no field to type into — park focus on the
    // key catcher so Escape still cancels; otherwise focus the password field.
    if (fingerprintMode) keyCatcher.forceActiveFocus()
    else passwordInput.forceActiveFocus()
  }

  function submitResponse() {
    var flow = polkitAgent ? polkitAgent.flow : null
    if (!flow || !flow.isResponseRequired) return
    submitted = true
    errorFlash = false
    flow.submit(passwordInput.text)
    passwordInput.text = ""
    keyCatcher.forceActiveFocus()
  }

  function cancelRequest() {
    var flow = polkitAgent ? polkitAgent.flow : null
    passwordInput.text = ""
    submitted = false
    closing = true
    closeTimer.restart()
    if (flow) flow.cancelAuthenticationRequest()
  }

  // A request that ends on its own (granted, or cancelled by polkit) has
  // already left polkitAgent.flow when its flow says so, so the Connections
  // below never hear the success or the cancel. The card gets the same short
  // close from here instead, which also hands it to a queued request without
  // unmapping in between. A face request never showed the card, so it is only
  // cleared: holding it would flash the password card after a nod.
  function endFlow() {
    if (faceConfigured && !responseRequired && !submitted && !errorFlash) {
      resetSnapshot()
    } else {
      closing = true
      closeTimer.restart()
    }
  }

  function triggerFailureFeedback() {
    submitted = false
    errorFlash = true
    passwordInput.text = ""
    errorTimer.restart()
    shakeAnimation.restart()
    Qt.callLater(refocus)
  }

  Timer {
    id: closeTimer
    interval: 300
    repeat: false
    onTriggered: {
      closing = false
      refusing = false
      resetSnapshot()
    }
  }

  Timer {
    id: errorTimer
    interval: 1200
    repeat: false
    onTriggered: root.errorFlash = false
  }

  SequentialAnimation {
    id: shakeAnimation
    NumberAnimation { target: root; property: "shakeOffset"; to: -8; duration: Style.duration(35); easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "shakeOffset"; to: 8; duration: Style.duration(50); easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "shakeOffset"; to: 0; duration: Style.duration(55); easing.type: Easing.OutQuad }
  }
  FileView {
    path: "/etc/pam.d/polkit-1"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadPamConfig(text())
    onLoadFailed: { root.fingerprintConfigured = false; root.faceConfigured = false }
    onFileChanged: reload()
  }

  Process {
    id: laptopClosedProc
    command: ["bash", "-c", "omarchy-hw-laptop-closed && echo closed || echo open"]
    stdout: StdioCollector { id: laptopClosedOut; waitForEnd: true }
    onExited: root.laptopClosed = String(laptopClosedOut.text || "").trim() === "closed"
  }

  // The agent lives in a Loader so it can be made again: Quickshell asks
  // polkit for the agent slot once, when the object is created, and never
  // again. A shell relaunched by its crash handler asks while the crashed
  // instance is still being dumped and still holds the slot, loses, and
  // from then on every pkexec fails for want of an agent. So while the
  // agent is not registered, make a fresh one every few seconds.
  readonly property var polkitAgent: agentLoader.item
  readonly property bool agentActive: !!polkitAgent && polkitAgent.isActive
  readonly property bool agentRegistered: !!polkitAgent && polkitAgent.isRegistered

  Loader {
    id: agentLoader
    active: true
    sourceComponent: PolkitAgent {
      path: "/org/omarchy/PolkitAgent"

      onAuthenticationRequestStarted: {
        root.beginFlow()
        root.tellFaceauth()
      }
      onIsActiveChanged: {
        if (isActive) root.syncFromFlow()
        else if (!root.closing) root.endFlow()
      }
      onIsRegisteredChanged: {
        if (isRegistered) console.log("omarchy polkit agent registered")
        else console.warn("omarchy polkit agent is not registered; another agent may be running, retrying")
      }
    }
  }

  // The old agent is only deleted once control returns to the event loop, and
  // while it lives it holds Quickshell's one agent slot, so an agent made in
  // the same handler never registers. The new one is made on the next turn,
  // after the old one is gone.
  Timer {
    id: registerRetry
    interval: 3000
    repeat: true
    running: !root.agentRegistered && !root.agentActive
    onTriggered: {
      if (root.agentRegistered) return
      agentLoader.active = false
      Qt.callLater(root.reloadAgent)
    }
  }

  function reloadAgent() {
    agentLoader.active = true
  }

  Connections {
    target: polkitAgent ? polkitAgent.flow : null

    function onIsResponseRequiredChanged() {
      root.syncFromFlow()
      if (!polkitAgent || !polkitAgent.flow || !polkitAgent.flow.isResponseRequired) passwordInput.text = ""
      Qt.callLater(root.refocus)
    }

    function onInputPromptChanged() { root.syncFromFlow() }
    function onResponseVisibleChanged() { root.syncFromFlow() }
    function onSupplementaryMessageChanged() { root.syncFromFlow() }
    function onFailedChanged() { root.syncFromFlow() }

    function onAuthenticationFailed() {
      // In face mode a failure with no password submitted from here can only
      // be the face window's refusal (a head shake, a dismissal): the answer
      // is no. Polkit would start the helper again and ask forever, so the
      // agent cancels the request instead, exactly as Escape does. Deferred:
      // the flow restarts its session right after this signal, and the cancel
      // has to land on that session for the request to end.
      if (root.faceConfigured && !root.submitted) {
        console.log("omarchy polkit: face consent refused, cancelling the request")
        root.refusing = true
        Qt.callLater(root.cancelRequest)
        return
      }
      root.syncFromFlow()
      root.triggerFailureFeedback()
    }

    function onAuthenticationSucceeded() {
      root.closing = true
      closeTimer.restart()
    }

    function onAuthenticationRequestCancelled() {
      root.closing = true
      closeTimer.restart()
    }
  }

  PanelWindow {
    id: panel
    // Right-to-left languages read this window mirrored.
    Binding { target: panel.contentItem; property: "LayoutMirroring.enabled"; value: Commons.I18n.rightToLeft }
    Binding { target: panel.contentItem; property: "LayoutMirroring.childrenInherit"; value: true }

    visible: root.dialogVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-polkit"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.refocus()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: root.shakeOffset
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: root.refocus() }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.cancelRequest()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.responseRequired) root.submitResponse()
            event.accepted = true
          }
        }
      }

      // Fingerprint mode shows just the sensor icon, centered and alone \u2014 no
      // padlock, no field, no prompt text.
      OpticalGlyph {
        anchors.centerIn: parent
        width: Math.round(root.fieldHeight * 0.7)
        height: width
        visible: root.fingerprintMode
        text: "\udb80\ude37"
        fontFamily: root.fontFamily
        fontSize: Math.round(root.fieldHeight * 0.7)
        color: root.errorFlash ? Commons.Color.polkit.textError : root.accent
      }

      Row {
        id: cardRow
        visible: !root.fingerprintMode
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.space(14)

        Text {
          text: "\uf023"
          color: root.errorFlash ? Commons.Color.polkit.textError : root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.iconLarge
          width: Style.space(26)
          height: root.fieldHeight
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }

        Item {
          width: parent.width - Style.space(40)
          height: root.fieldHeight

          TextInput {
            id: passwordInput
            anchors.fill: parent
            verticalAlignment: TextInput.AlignVCenter
            activeFocusOnPress: true
            clip: true
            selectionColor: Util.alpha(root.accent, 0.45)
            selectedTextColor: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
            echoMode: root.responseVisible ? TextInput.Normal : TextInput.Password
            passwordCharacter: "\u2022"
            color: root.errorFlash ? Commons.Color.polkit.textError : root.foreground
            cursorVisible: activeFocus && !root.submitted && !root.errorFlash
            readOnly: root.submitted || root.errorFlash
            enabled: root.dialogVisible
            onAccepted: root.submitResponse()
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                root.cancelRequest()
                event.accepted = true
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.errorFlash ? I18n.t("polkit.wrong") : (root.submitted ? I18n.t("polkit.checking") : I18n.t("polkit.enterPassword"))
            color: root.errorFlash ? Commons.Color.polkit.textError : root.foreground
            opacity: root.errorFlash ? 1 : 0.36
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
            elide: Text.ElideRight
            visible: passwordInput.text.length === 0
          }

          Rectangle {
            width: Math.max(1, Style.space(2))
            height: Style.space(24)
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            color: root.errorFlash ? Commons.Color.polkit.textError : root.foreground
            visible: passwordInput.visible && passwordInput.activeFocus && passwordInput.text.length === 0 && !root.submitted && !root.errorFlash
          }

          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            enabled: passwordInput.visible
            onClicked: passwordInput.forceActiveFocus()
          }
        }
      }
    }

    Rectangle {
      width: Math.min(justificationText.implicitWidth + Style.space(24), panel.width - Style.gapsOut * 2)
      height: Style.space(28)
      anchors.horizontalCenter: card.horizontalCenter
      anchors.bottom: card.top
      anchors.bottomMargin: Style.space(10)
      radius: root.cornerRadius
      color: root.background

      Text {
        id: justificationText
        textFormat: Text.PlainText
        anchors.fill: parent
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(12)
        text: root.authorizationLabel(root.currentMessage)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideMiddle
      }
    }
  }
}
