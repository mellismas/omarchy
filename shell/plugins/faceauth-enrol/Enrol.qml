import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The enrolment walk-through. Opened by faceauthd (root) through
// `omarchy-shell shell summon omarchy.faceauth.enrol` when a session starts.
// The window then watches the daemon's stream over its own socket
// connection: one line per frame with where the face is, how big, which way
// it is turned, the step at hand and whether the frame counts. It draws a
// dot the person steers into a target and never sees a camera image. Its
// buttons send continue, redo and cancel back; the daemon decides
// everything else and stores the templates.
Item {
  id: root

  property bool opened: false
  property string user: ""
  property string step: ""
  property string zone: ""
  property bool face: false
  property real size: 0
  property string distance: "far"
  // The dot and the target, in ring units from the daemon: 0 is the
  // centre, 1 is the ring. The daemon maps the readings, so what counts
  // and what is drawn agree.
  property real dotUx: 0
  property real dotUy: 0
  property real targetUx: 0
  property real targetUy: 0
  property bool onTarget: false
  property int taken: 0
  property int wanted: 0
  property string message: ""

  readonly property string fontFamily: Style.font.menuFamily
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color accent: Color.menu.selectedText
  readonly property color scrim: Color.menu.scrim
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)), "border-alpha")
  readonly property int cornerRadius: Style.cornerRadius

  // The ring's radius on screen, and how far a turn or a tilt moves the
  // dot: a turn reading of 0.30 (about a quarter turn) reaches the ring.
  // The tilt measure is lopsided with a camera that looks up from the lid,
  // a comfortable chin-up moves it about 0.04 under the person's level and
  // a chin-down about 0.12 over, so each direction has its own scale and
  // both limits land on the ring.
  readonly property real ringRadius: Style.space(150)
  readonly property real dotX: root.dotUx * root.ringRadius
  readonly property real dotY: root.dotUy * root.ringRadius
  // The dot's size follows the distance: it fits the target at the right
  // distance, grows past it too close, shrinks too far.
  readonly property real dotRadius: Style.space(14) * Math.max(0.5, Math.min(2.0, root.size / 0.19))
  readonly property bool showRing: root.step === "centre" || root.step === "range" || root.step === "path" || root.step === "hold" || root.step === "verify" || root.step === "record"
  // The dashed circle: at the centre while the centre is learned, then
  // wherever the daemon walks it.
  readonly property bool showTarget: root.step === "centre" || root.step === "path" || root.step === "hold"

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(String(payloadJson || "{}")) } catch (e) { payload = {} }
    root.user = String(payload.user || Quickshell.env("USER") || "")
    root.step = String(payload.start || "welcome")
    root.message = "Welcome to FaceAuth enrolment. Follow the instructions on the screen."
    root.opened = true
    watch.connected = false
    watch.connected = true
  }

  function close() {
    root.opened = false
    watch.connected = false
  }

  function control(word) {
    controlProc.command = ["/usr/bin/faceauth", "enrol-control", word, "--user", root.user]
    controlProc.running = true
  }

  Process { id: controlProc }

  // The stream. One request line up, then a line per frame down until the
  // session ends and the daemon closes it.
  Socket {
    id: watch
    path: "/run/faceauth/sock"
    onConnectionStateChanged: {
      if (connected) {
        write(JSON.stringify({ user: root.user, enrol_watch: true }) + "\n")
        flush()
      }
    }
    parser: SplitParser {
      onRead: line => {
        var t = {}
        try { t = JSON.parse(String(line)) } catch (e) { return }
        if (t.result) { root.message = String(t.message || t.result); return }
        root.step = String(t.step || "")
        root.zone = String(t.zone || "")
        root.face = !!t.face
        root.size = Number(t.size || 0)
        root.distance = String(t.distance || "far")
        root.dotUx = Number(t.dot_x || 0)
        root.dotUy = Number(t.dot_y || 0)
        root.targetUx = Number(t.target_x || 0)
        root.targetUy = Number(t.target_y || 0)
        root.onTarget = !!t.on_target
        root.taken = Number(t.taken || 0)
        root.wanted = Number(t.wanted || 0)
        root.message = String(t.message || "")
        if (root.step === "done" || root.step === "failed") doneTimer.restart()
      }
    }
  }

  Timer {
    id: doneTimer
    interval: 2500
    repeat: false
    onTriggered: root.close()
  }

  readonly property var cameraScreen: {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (/^eDP/.test(String(screens[i].name))) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.cameraScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-faceauth-enrol"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }


    BorderSurface {
      id: card
      width: Math.min(Style.space(720), panel.width - Style.gapsOut * 2)
      height: column.implicitHeight + Style.spacing.panelPadding * 2
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.45)
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      Item {
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.control("cancel"); event.accepted = true }
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.control("continue"); event.accepted = true }
        }
      }

      Column {
        id: column
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding
        spacing: Style.spacing.md

        Text {
          width: parent.width
          text: "Face enrolment"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          width: parent.width
          text: root.message
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        }

        // The ring, the target and the dot.
        Item {
          width: parent.width
          height: root.showRing ? root.ringRadius * 2 + Style.space(60) : 0
          visible: root.showRing
          clip: true

          Rectangle {
            width: root.ringRadius * 2
            height: root.ringRadius * 2
            radius: width / 2
            color: "transparent"
            border.color: root.foreground
            border.width: 2
            opacity: 0.6
            anchors.centerIn: parent
          }

          // The head outline sits at the centre; the dot is the nose.
          Rectangle {
            width: root.ringRadius * 0.9
            height: root.ringRadius * 1.15
            radius: width / 2
            color: "transparent"
            border.color: root.foreground
            border.width: 1
            opacity: 0.25
            anchors.centerIn: parent
          }

          // The dashed target circle, green while the dot is in it. Its
          // radius is the daemon's acceptance along the look (0.35 of the
          // ring), so a dot inside the circle is a frame that counts.
          Canvas {
            id: targetMark
            visible: root.showTarget
            width: root.ringRadius * 0.70
            height: width
            x: parent.width / 2 + root.targetUx * root.ringRadius - width / 2
            y: parent.height / 2 + root.targetUy * root.ringRadius - height / 2
            property color stroke: root.onTarget ? root.accent : root.foreground
            onStrokeChanged: requestPaint()
            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              ctx.setLineDash([6, 5])
              ctx.lineWidth = root.onTarget ? 3 : 2
              ctx.strokeStyle = stroke
              ctx.beginPath()
              ctx.arc(width / 2, height / 2, width / 2 - 3, 0, 2 * Math.PI)
              ctx.stroke()
            }
          }

          Rectangle {
            visible: root.face
            width: root.dotRadius * 2
            height: width
            radius: width / 2
            color: root.onTarget ? root.accent : root.foreground
            // No animation: the daemon already smooths the readings, and
            // the dot must sit where the head is now, not where it was.
            x: parent.width / 2 + root.dotX - width / 2
            y: parent.height / 2 + root.dotY - height / 2
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            text: root.step === "centre" ? (root.distance === "right" ? "Right there, hold still" : (root.distance === "close" ? "A little further back" : "A little closer"))
                : (root.step === "path" || root.step === "hold" ? (root.taken + " taken") : "")
            color: root.foreground
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          spacing: Style.spacing.sm
          anchors.right: parent.right

          Button {
            text: "Cancel"
            bordered: true
            foreground: Color.polkit.textError
            accent: Color.polkit.textError
            fontFamily: root.fontFamily
            onClicked: root.control("cancel")
          }

          Button {
            visible: root.step === "range" || root.step === "path" || root.step === "hold"
            text: "Redo this one"
            bordered: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.control("redo")
          }

          Button {
            visible: root.step === "welcome"
            text: "Continue"
            bordered: true
            foreground: root.accent
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.control("continue")
          }
        }
      }
    }
  }
}
