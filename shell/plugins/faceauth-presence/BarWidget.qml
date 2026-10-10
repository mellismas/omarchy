import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The walk-away lock has two modes. Default keeps the session open while
// anyone is looking at the screen, whoever it is, and locks once nobody has
// been in front of it for the away time. Secure checks identity on every
// look, locks at once on the first look that finds a face which is not the
// enrolled user's, and locks an empty chair after the away time. The mode
// lives in the daemon until it restarts (it does not persist); this widget reads it from
// the daemon through faceauth and switches it with a click. Both directions
// go through the daemon's own socket, where only a local process of the
// watched user is heard, so the widget holds no state the daemon does not.
// It is hidden when the presence watch is off or faceauth is not installed.
// Right click drops a menu of the two modes. A camera that cannot flash its
// IR light cannot hold the secure mode's promise; the daemon says so, and
// the widget then offers secure nowhere and says why.
BarWidget {
  id: root
  moduleName: "omarchy.faceauth.presence"

  property bool watching: false
  property string mode: "default"
  property bool secureAvailable: true
  property bool busy: false
  property bool switching: false
  property bool menuOpen: false

  readonly property string secureUnavailableHint: I18n.t("facePresence.secureUnavailableHint")

  function close() { menuOpen = false }

  function choose(next) {
    root.menuOpen = false
    if (root.busy || !root.watching || next === root.mode) return
    if (next === "secure" && !root.secureAvailable) return
    root.busy = true
    root.switching = true
    watchdog.restart()
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
    root.switching = false
    watchdog.restart()
    modeProc.command = ["/usr/bin/faceauth", "presence", "mode"]
    modeProc.running = true
  }

  function toggle() {
    if (root.busy || !root.watching) return
    if (!root.secure && !root.secureAvailable) return
    root.busy = true
    root.switching = true
    watchdog.restart()
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
      root.secureAvailable = p.secure_available !== false
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
      watchdog.stop()
      root.busy = false
      var wasSwitch = root.switching
      root.switching = false
      // A refused switch (the camera cannot hold secure mode, or has not
      // been checked since faceauth started) leaves the widget up and
      // reads the state afresh; only a failed read hides it.
      if (exitCode !== 0) {
        if (wasSwitch) root.refresh()
        else root.watching = false
      }
    }
  }

  // The bar exists once per monitor, and an IPC target routes to one
  // instance, so the owner relays the refresh to its peers as the other
  // widgets do; otherwise the chord's refresh would land on one screen and
  // leave the others on the old mode until their own poll.
  ShellIpc {
    target: "omarchy.faceauth.presence"

    function refresh(): void {
      root.broadcast("refresh")
    }
  }

  // The state changes on the widget's own click, on the chord (whose script
  // sends the IPC refresh above), when faceauth restarts (the mode goes back
  // to the config) and when a face is enrolled or deleted. The timer is only
  // for the last two, so it is slow: every poll is a daemon connection, and
  // the daemon answers it from its own bookkeeping without touching the
  // camera, so a poll can never queue behind an enrollment.
  Timer {
    interval: 300000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Quickshell's Process reports a program that never started (faceauth
  // not installed, or not executable) with no exited signal, so busy would
  // stay set for the life of the shell and every later refresh would return
  // at once. The CLI itself gives up on the daemon after a few seconds, so
  // a call still running at this point is one that never ran. The widget
  // then stays hidden until a refresh that does answer.
  Timer {
    id: watchdog
    interval: 10000
    onTriggered: {
      root.busy = false
      root.watching = false
    }
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
      ? I18n.t("facePresence.tooltipSecure")
      : I18n.t("facePresence.tooltipDefault") + " "
        + (root.secureAvailable ? I18n.t("facePresence.tooltipDefaultSwitch") : I18n.t("facePresence.secureUnavailable"))
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
        text: I18n.t("facePresence.title")
        color: Qt.darker(root.bar.foreground, 1.3)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        width: parent.width
      }

      Repeater {
        model: [
          { value: "default", label: I18n.t("facePresence.modeDefault"), hint: I18n.t("facePresence.modeDefaultHint") },
          { value: "secure", label: I18n.t("facePresence.modeSecure"), hint: I18n.t("facePresence.modeSecureHint") }
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
            enabled: parent.modelData.value !== "secure" || root.secureAvailable
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.choose(parent.modelData.value)
          }

          Text {
            textFormat: Text.PlainText
            text: parent.modelData.value !== "secure" || root.secureAvailable ? parent.modelData.hint : root.secureUnavailableHint
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
