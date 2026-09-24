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
BarWidget {
  id: root
  moduleName: "omarchy.faceauth.presence"

  property bool watching: false
  property string mode: "default"
  property bool busy: false

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
      ? "Walk-away lock: secure. Locks when you are not in frame. Click for default."
      : "Walk-away lock: default. Locks when nobody is there. Click for secure."
    onPressed: root.toggle()
  }
}
