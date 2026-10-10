import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

// Base item for the face authentication overlays, the consent card and the
// enrollment walk-through. Both wear the menu's palette, so they look like the
// system's own windows, and both are drawn on the output that holds the
// camera.
Item {
  readonly property string fontFamily: Style.font.menuFamily
  readonly property color background: Commons.Color.menu.background
  readonly property color foreground: Commons.Color.menu.text
  readonly property color accent: Commons.Color.menu.selectedText
  readonly property color scrim: Commons.Color.menu.scrim
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, Math.max(1, Style.space(2)), "border-alpha")
  readonly property int cornerRadius: Style.cornerRadius

  // The laptop's own panel when there is one, else the first output. A
  // window on a screen the user is not facing is one the camera cannot see
  // them answer.
  readonly property var cameraScreen: {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (/^eDP/.test(String(screens[i].name))) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }
}
