import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The walk-away lock has two modes. Default locks once nobody has been in
// front of the screen for the away time, so a coworker sitting down keeps
// nothing open past that. Secure locks once the enrolled user has been out
// of frame for the away time, whoever else is there. The mode lives in the
// daemon for the session (it does not persist); this widget reads it from
// the daemon through faceauth and switches it with a click. Both directions
// go through the daemon's own socket, where only a local process of the
// watched user is heard, so the widget holds no state the daemon does not.
// It is hidden when the presence watch is off or faceauth is not installed.
//
// Right click drops a menu of the three levels: Default, Secure, and MFA.
// MFA is two-factor authentication for sudo, polkit and the lock screen,
// and implies secure walk-away. It is designed (design/plan-two-factor in
// the FaceAuth pack) and not built yet, so its row says so; when it lands,
// choosing it turns two-factor on with no prompt and leaving it asks for
// any two factors first.
BarWidget {
  id: root
  moduleName: "omarchy.faceauth.presence"

  property bool watching: false
  property string mode: "default"
  property bool busy: false
  property bool menuOpen: false

  function close() { menuOpen = false }

  function choose(next) {
    root.menuOpen = false
    if (next === "mfa") {
      if (root.bar) root.bar.run("omarchy-notification-send -u low 'Two-factor mode' 'Not set up yet.'")
      return
    }
    if (root.busy || !root.watching || next === root.mode) return
    root.busy = true
    modeProc.command = ["/usr/bin/faceauth", "presence", "mode", next]
    modeProc.running = true
  }

  readonly property bool secure: mode === "secure"

  visible: watching
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() {
    if (root.busy) return
    root.busy = true
    modeProc.command = ["/usr/bin/faceauth", "presence", "mode"]
    modeProc.running = true
  }

  function toggle() {
    if (root.busy || !root.watching) return
    root.busy = true
    modeProc.command = ["/usr/bin/faceauth", "presence", "mode", root.secure ? "default" : "secure"]
    modeProc.running = true
  }

  function applyLine(line) {
    try {
      var o = JSON.parse(line)
      var p = o && o.presence ? o.presence : null
      if (!p) return
      root.watching = p.watching === true
      root.mode = p.mode === "secure" ? "secure" : "default"
    } catch (e) {
      // Not a state line: the daemon is not there or refused. Say nothing
      // and show nothing until the next refresh.
    }
  }

  Process {
    id: modeProc
    stdout: SplitParser {
      onRead: function(line) { root.applyLine(line) }
    }
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode !== 0) root.watching = false
    }
  }

  IpcHandler {
    target: "omarchy.faceauth.presence"

    function refresh(): void {
      root.refresh()
    }
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.secure ? "󰒃" : "󰒄"
    active: root.secure
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.secure
      ? "Walk-away lock: secure. Locks when you are not in frame. Click for default, right-click to choose."
      : "Walk-away lock: default. Locks when nobody is there. Click for secure, right-click to choose."
    onPressed: function(b) {
      if (b === Qt.RightButton) root.menuOpen = !root.menuOpen
      else root.toggle()
    }
  }

  PopupCard {
    id: menu
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.menuOpen
    contentWidth: menu.fittedContentWidth(Style.space(300))
    contentHeight: menu.fittedContentHeight(rows.implicitHeight)

    Column {
      id: rows
      anchors.fill: parent
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        text: "Walk-away lock"
        color: Qt.darker(root.bar.foreground, 1.3)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        width: parent.width
      }

      Repeater {
        model: [
          { value: "default", label: "Default", hint: "Locks when nobody is there" },
          { value: "secure", label: "Secure", hint: "Locks when you are not in frame" },
          { value: "mfa", label: "MFA", hint: "Two factors for sudo, polkit and the lock screen. Not set up yet." }
        ]

        Column {
          required property var modelData
          width: rows.width
          spacing: 0

          Button {
            width: parent.width
            leftAlign: true
            text: parent.modelData.label
            foreground: root.bar.foreground
            fontSize: Style.font.bodySmall
            selected: parent.modelData.value === root.mode
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.choose(parent.modelData.value)
          }

          Text {
            textFormat: Text.PlainText
            text: parent.modelData.hint
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            width: parent.width - Style.spacing.controlPaddingX * 2
            x: Style.spacing.controlPaddingX
          }
        }
      }
    }
  }
}
