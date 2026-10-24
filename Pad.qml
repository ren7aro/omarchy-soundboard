import QtQuick
import qs.Commons
import qs.Ui

// One pad tile. Width comes from the grid delegate; everything a pad needs
// to be understood at a glance lives inside:
//
//   [glyph]                [ALT+1]     ← glyph = play ▸ / stop ■ / missing ⚠
//   Pad name
//   effect.wav             ▂▄▂         ← source file + live equalizer bars
//
// States stay legible without leaning on color alone:
//   idle      filled surface, play glyph, normal border
//   hover     hover fill + cursor border
//   pressed   pressed fill (deepest state, one click: tile is small)
//   cursor    focus fill + focus border ring (roving keyboard focus)
//   playing   selected fill + border; glyph becomes a stop square; the slot
//             key lights; three bars breathe — shape + motion + emphasis
//   missing   no fill, urgent warning glyph, "file gone" caption
//   empty     no fill, dim plus glyph + the free slot key, centered
BorderSurface {
  id: tile

  property var pad: null
  property string slotLabel: ""
  property bool playing: false
  property bool cursor: false
  property string fontFamily: Style.font.family
  readonly property color foreground: Color.popups.text
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color urgent: Color.urgent

  signal activated()
  signal addRequested()

  readonly property bool isEmpty: pad === null
  readonly property bool isMissing: pad !== null && pad.missing === true
  readonly property bool isFilled: pad !== null && !isMissing
  readonly property bool hot: mouse.containsMouse
  readonly property bool pressed: mouse.pressed
  readonly property string sourceName: tile.pad && tile.pad.path
    ? String(tile.pad.path).substring(String(tile.pad.path).lastIndexOf("/") + 1)
    : ""

  implicitWidth: Style.space(92)
  implicitHeight: Style.space(92)
  radius: Style.cornerRadius

  borderSpec: tile.cursor ? Border.controlSpec("focus", foreground, accent)
    : tile.playing ? Border.controlSpec("selected", foreground, accent)
    : tile.hot ? Border.controlSpec("hover-cursor", foreground, accent)
    : !tile.isEmpty ? Border.controlSpec("normal", foreground, accent)
    : Border.none()

  color: tile.pressed ? Style.pressedFillFor(foreground, accent)
    : tile.cursor ? Style.focusFillFor(foreground, accent)
    : tile.playing ? Style.selectedFillFor(foreground, accent)
    : tile.hot ? Style.hoverFillFor(foreground, accent)
    : tile.isFilled ? Style.normalFillFor(foreground, accent)
    : "transparent"

  Behavior on color { ColorAnimation { duration: 120 } }

  // roving-focus ring. The shared focus border token is tuned for dense
  // chrome; on a large tile it reads as texture, not as focus. A dedicated
  // ring (same idiom as ToggleSwitch's cursor ring) carries the keyboard
  // cursor unambiguously.
  BorderSurface {
    anchors.fill: parent
    radius: tile.radius
    color: "transparent"
    visible: tile.cursor
    borderSpec: Border.controlSpec("selected", tile.foreground, tile.accent)
  }

  // top row: state glyph left · hotkey badge right. Hidden on empty slots —
  // they carry their own centered call to action.
  Item {
    id: topRow
    visible: !tile.isEmpty
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.margins: Style.spacing.lg
    height: Math.max(stateGlyph.implicitHeight, slotText.implicitHeight)

    Text {
      id: stateGlyph
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: tile.isMissing ? "\uf071"
        : tile.playing ? "\uf04d"
        : "\uf04b"
      color: tile.isMissing ? tile.urgent
        : tile.playing ? tile.accent
        : tile.dim
      Behavior on color { ColorAnimation { duration: 120 } }
      font.family: fontFamily
      font.pixelSize: Style.font.iconSmall
    }

    Text {
      id: slotText
      visible: tile.slotLabel !== ""
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: tile.slotLabel
      color: tile.playing ? tile.accent : tile.dim
      Behavior on color { ColorAnimation { duration: 120 } }
      font.family: fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton
    cursorShape: tile.isMissing ? Qt.ArrowCursor : Qt.PointingHandCursor

    onClicked: {
      if (tile.isEmpty) tile.addRequested()
      else if (!tile.isMissing) tile.activated()
    }
  }

  PanelToolTip {
    visible: mouse.containsMouse
    text: tile.isMissing
      ? "File missing — re-add it or remove the pad in settings."
      : tile.isEmpty
        ? "Free slot — click to add a sound."
        : (tile.playing ? "Stop · " : "Play · ")
          + (tile.pad && tile.pad.path ? String(tile.pad.path) : String(tile.pad.name || ""))
    fontFamily: fontFamily
  }

  // bottom block: name + source/missing caption + playing bars
  Column {
    id: bottomBlock
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.margins: Style.spacing.lg
    spacing: Style.spacing.xs

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: tile.isEmpty ? "" : String(tile.pad.name || "Untitled")
      color: tile.isMissing ? tile.dim : tile.foreground
      font.family: fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
      elide: Text.ElideRight
    }

    Item {
      id: captionRow
      width: parent.width
      height: Math.max(caption.implicitHeight, bars.implicitHeight)
      visible: !tile.isEmpty

      Text {
        id: caption
        width: tile.playing
          ? Math.max(0, parent.width - bars.width - Style.spacing.sm)
          : parent.width
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: tile.isMissing ? "file gone"
          : (tile.playing ? "" : tile.sourceName)
        color: tile.isMissing ? tile.urgent : tile.dim
        font.family: fontFamily
        font.pixelSize: Style.font.caption
        font.bold: tile.isMissing
        elide: Text.ElideRight
      }

      // Playing indicator: three breathing bars, animated only while the pad
      // is audible. Motion carries "this is live" independently of color;
      // the stop glyph carries the action.
      Row {
        id: bars
        visible: tile.playing
        spacing: Style.space(2)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter

        Repeater {
          id: barsRepeater
          model: 3

          Rectangle {
            required property int index
            width: Style.space(3)
            height: Style.space(4)
            radius: 1
            color: tile.accent
            anchors.verticalCenter: parent.verticalCenter

            SequentialAnimation on height {
              running: tile.playing
              loops: Animation.Infinite

              NumberAnimation {
                to: Style.space(14)
                duration: 150 + index * 50
                easing.type: Easing.OutQuad
              }

              NumberAnimation {
                to: Style.space(4)
                duration: 150 + index * 50
                easing.type: Easing.InQuad
              }
            }
          }
        }
      }
    }
  }

  // empty slot: centered plus glyph + free hotkey
  Column {
    anchors.centerIn: parent
    spacing: Style.spacing.xs
    visible: tile.isEmpty

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: "\uf067"
      color: tile.hot ? tile.accent : tile.dim
      Behavior on color { ColorAnimation { duration: 120 } }
      font.family: fontFamily
      font.pixelSize: Style.font.iconLarge
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: tile.slotLabel
      color: tile.dim
      font.family: fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      opacity: 0.8
    }
  }

  // Reset the equalizer bars to their resting height when a pad goes quiet.
  onPlayingChanged: {
    if (playing) return
    for (var i = 0; i < barsRepeater.count; i++) {
      var bar = barsRepeater.itemAt(i)
      if (bar) bar.height = Style.space(4)
    }
  }
}
