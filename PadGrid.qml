import QtQuick
import qs.Commons

// The pad grid: four columns, one fixed slot per tile. The twelve hotkey
// slots always exist — pads fill them in order, and everything after the
// last pad renders as a quiet "free slot" tile so the key map is visible
// before a single sound exists. Cursor logic (roving focus) also lives
// here: drawn per tile from `cursorSlot`, moved from the panel's key
// catcher.
Grid {
  id: root

  property var pads: []
  // { padId: playerIndex } straight from the Service; keyed by pad id,
  // never mutated here.
  property var playingMap: ({})
  property int cursorSlot: -1
  // e.g. ["ALT+1", …, "ALT+E", ""]; sized to at least 12 by the panel.
  property var labels: []
  property string fontFamily: Style.font.family

  signal padActivated(int index)
  signal slotAddRequested(int index)

  width: parent.width
  columns: 4
  columnSpacing: Style.spacing.md
  rowSpacing: Style.spacing.lg

  readonly property int displaySlots: Math.max(12, Array.isArray(pads) ? pads.length : 0)

  function padAt(index) {
    return Array.isArray(pads) && index >= 0 && index < pads.length ? pads[index] : null
  }

  function labelAt(index) {
    return Array.isArray(labels) && index >= 0 && index < labels.length
      ? String(labels[index] || "")
      : ""
  }

  function isPlaying(pad) {
    return !!(pad && playingMap && playingMap[pad.id] !== undefined)
  }

  Repeater {
    model: root.displaySlots

    delegate: Pad {
      required property int index

      readonly property var tilePad: root.padAt(index)

      pad: tilePad
      slotLabel: root.labelAt(index)
      playing: root.isPlaying(tilePad)
      cursor: root.cursorSlot === index
      fontFamily: root.fontFamily
      width: (root.width - root.columnSpacing * (root.columns - 1)) / root.columns

      onActivated: root.padActivated(index)
      onAddRequested: root.slotAddRequested(index)
    }
  }
}
