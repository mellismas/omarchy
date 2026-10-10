import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The enrollment walk-through. Opened by faceauthd (root) through
// `omarchy-shell shell summon omarchy.faceauth.enrol` when a session starts.
// The window then watches the daemon's stream over its own socket
// connection: one line per frame with where the face is, how big, which way
// it is turned, the step at hand and whether the frame counts. It draws a
// dot the person steers into a target and never sees a camera image. Its
// buttons send continue, redo and cancel back; the daemon decides
// everything else and stores the templates. FaceAuthOverlay gives the
// window the menu's palette and the camera's screen.
FaceAuthOverlay {
  id: root

  property bool opened: false
  property string user: ""
  property string step: ""
  property string zone: ""
  property bool face: false
  property real size: 0
  property string distance: "far"
  // The dot and the target, in ring units from the daemon: 0 is the
  // center, 1 is the ring. The daemon maps the readings, so what counts
  // and what is drawn agree.
  property real dotUx: 0
  property real dotUy: 0
  property real targetUx: 0
  property real targetUy: 0
  property bool onTarget: false
  property int taken: 0
  property int wanted: 0
  property string message: ""
  // The gesture and everyday rounds after the looks.
  property string round: ""
  property int roundNo: 0
  property int roundOf: 0
  property real secondsLeft: 0
  property bool countdown: false
  property int readSlot: -1
  // Whether the daemon's stream has been up for this session. Once it
  // was, the stream closing means the session is over, however it ended
  // (the daemon finished it, failed it, or went away), and the window
  // must not stay over the screen waiting for a tick that will not come.
  property bool streamed: false
  readonly property var readTexts: [
    Commons.I18n.t("faceEnroll.readHead"),
    Commons.I18n.t("faceEnroll.readNoImage"),
    Commons.I18n.t("faceEnroll.readNodShake"),
    Commons.I18n.t("faceEnroll.readOrdinary"),
    Commons.I18n.t("faceEnroll.readPurpose")
  ]

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
  readonly property bool inRound: root.step === "round"
  // The round's whole length, from the first seconds-left reading it sends.
  property real roundSeconds: 0
  onSecondsLeftChanged: if (!root.countdown && root.secondsLeft > root.roundSeconds) root.roundSeconds = root.secondsLeft
  onRoundNoChanged: root.roundSeconds = 0
  // The dashed circle: at the center while the center is learned, then
  // wherever the daemon walks it.
  readonly property bool showTarget: root.step === "centre" || root.step === "path" || root.step === "hold"

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(String(payloadJson || "{}")) } catch (e) { payload = {} }
    root.user = String(payload.user || Quickshell.env("USER") || "")
    root.step = String(payload.start || "welcome")
    root.message = Commons.I18n.t("faceEnroll.welcome")
    root.opened = true
    root.streamed = false
    watch.connected = false
    watch.connected = true
  }

  function close() {
    root.opened = false
    root.streamed = false
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
        root.streamed = true
        write(JSON.stringify({ user: root.user, enrol_watch: true }) + "\n")
        flush()
      } else if (root.streamed) {
        // The daemon closed the stream: the session is over. A done or
        // failed tick already started the timer that shows its message;
        // otherwise close now.
        root.streamed = false
        if (!doneTimer.running) root.close()
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
        root.round = String(t.round || "")
        root.roundNo = Number(t.round_no || 0)
        root.roundOf = Number(t.round_of || 0)
        root.secondsLeft = Number(t.seconds_left || 0)
        root.countdown = !!t.countdown
        root.readSlot = (t.read_slot === null || t.read_slot === undefined) ? -1 : Number(t.read_slot)
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

    // The reading round: one short text at a time, placed around the
    // screen so the eyes and head move the way they do when reading.
    Repeater {
      model: 5
      Text {
        required property int index
        visible: root.inRound && root.round === "read" && !root.countdown && root.readSlot === index
        text: root.readTexts[index]
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        x: index === 0 || index === 3 ? Style.gapsOut * 2 : (index === 4 ? (panel.width - width) / 2 : panel.width - width - Style.gapsOut * 2)
        y: index === 0 || index === 1 ? Style.gapsOut * 2 + Style.space(40) : (index === 4 ? panel.height - height - Style.gapsOut * 2 - Style.space(40) : panel.height - height - Style.gapsOut * 2 - Style.space(120))
      }
    }


    BorderSurface {
      id: card
      width: Math.min(Style.space(720), panel.width - Style.gapsOut * 2)
      height: column.implicitHeight + Style.spacing.panelPadding * 2
      radius: root.cornerRadius
      anchors.centerIn: parent
      // Translucent enough to see the ring's surroundings, opaque enough
      // to read the round's prompt over whatever is behind.
      color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.85)
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
          text: Commons.I18n.t("faceEnroll.title")
          textFormat: Text.PlainText
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

        // A round: which one, and a bar running down as it records.
        Item {
          width: parent.width
          height: root.inRound ? Style.space(36) : 0
          visible: root.inRound

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.countdown ? Commons.I18n.t("faceEnroll.roundStarting").arg(Commons.I18n.formatNumber(root.roundNo)).arg(Commons.I18n.formatNumber(root.roundOf)) : Commons.I18n.t("faceEnroll.roundRecording").arg(Commons.I18n.formatNumber(root.roundNo)).arg(Commons.I18n.formatNumber(root.roundOf)).arg(Commons.I18n.formatNumber(Math.ceil(root.secondsLeft)))
            textFormat: Text.PlainText
            color: root.countdown ? root.foreground : root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Rectangle {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(200)
            height: Style.space(6)
            radius: height / 2
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
            Rectangle {
              height: parent.height
              radius: parent.radius
              width: parent.width * (root.countdown ? 0 : Math.max(0, Math.min(1, 1 - root.secondsLeft / Math.max(1, root.roundSeconds))))
              color: root.accent
            }
          }
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

          // The head outline sits at the center; the dot is the nose.
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
            text: root.step === "centre" ? (root.distance === "right" ? Commons.I18n.t("faceEnroll.holdStill") : (root.distance === "close" ? Commons.I18n.t("faceEnroll.moveBack") : Commons.I18n.t("faceEnroll.moveCloser")))
                : (root.step === "path" || root.step === "hold" ? Commons.I18n.tn("faceEnroll.taken", root.taken).arg(Commons.I18n.formatNumber(root.taken)) : "")
            textFormat: Text.PlainText
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
            text: Commons.I18n.t("common.cancel")
            bordered: true
            foreground: Commons.Color.polkit.textError
            accent: Commons.Color.polkit.textError
            fontFamily: root.fontFamily
            onClicked: root.control("cancel")
          }

          Button {
            visible: root.step === "range" || root.step === "path" || root.step === "hold" || root.step === "round"
            text: Commons.I18n.t("faceEnroll.redo")
            bordered: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.control("redo")
          }

          Button {
            visible: root.step === "welcome" || root.step === "bridge"
            text: Commons.I18n.t("faceEnroll.continue")
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
