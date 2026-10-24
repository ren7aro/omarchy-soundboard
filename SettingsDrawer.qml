import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Settings surface inside the same panel — no second window. Sections read
// top-to-bottom in order of likelihood of use mid-project:
//
//   Sounds          add files (browse, pick a folder, or paste a path)
//   Volume          master + "hear locally" (with the speaker-echo note)
//   Microphone      pin the loopback source, refresh devices
//   Pads            per-pad rename / volume / remove
//   Hotkeys         the twelve slot keys, once, in two lines
//
// The Whole drawer scrolls if a full library meets a short screen; the
// service stays the source of truth — every change goes through it, and
// only the widget-level twin keys (masterVolume / monitorLocally /
// micSource) are also mirrored into the panel's shell.json entry.
Column {
  id: root

  // bound by the panel
  property var svc: null
  property string fontFamily: Style.font.family
  property var slotLabels: []
  property real masterVolumeFallback: 1.0
  property bool monitorFallback: true
  property string micFallback: ""

  signal saveSettings(var values)
  signal requestClose()

  readonly property color foreground: Color.popups.text
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color urgent: Color.urgent
  readonly property var pads: root.svc && Array.isArray(root.svc.pads) ? root.svc.pads : []
  readonly property int missingCount: {
    var count = 0
    for (var i = 0; i < root.pads.length; i++) if (root.pads[i] && root.pads[i].missing) count++
    return count
  }
  readonly property var micOptions: root.buildMicOptions()
  readonly property string currentMic: root.svc && root.svc.micSource
    ? String(root.svc.micSource)
    : root.micFallback

  // --- adding sounds ---------------------------------------------------------
  // The service singleton owns the portal picker (the omarchy-file-select
  // Process must survive the panel's close-before-pick handoff) and its
  // extension list — the single source of truth for the chooser filter and
  // the folder scan. This drawer only asks and reads state back.
  readonly property var audioExtensions: root.svc ? root.svc.audioExtensions : []
  readonly property string extensionsHint: root.svc ? String(root.svc.extensionsHint || "") : ""
  readonly property bool libraryFull: root.pads.length >= 12
  // Picker activity straight from the service:
  // "" = idle · "files"/"folder" = portal dialog open · "folderScan" = reading the folder
  readonly property string pickerKind: root.svc ? String(root.svc.pickerKind || "") : ""
  readonly property bool pickerBusy: root.svc ? !!root.svc.pickerBusy : false
  readonly property string pickerError: root.svc ? String(root.svc.pickerError || "") : ""

  // Launch wiring: buttons bubble this up; the panel closes its overlay,
  // then starts svc.pickFiles(kind) — the drawer must NOT run the picker
  // inline or the dialog maps underneath the panel surface.
  signal requestPick(string kind)

  function focusBrowse() {
    Qt.callLater(function() {
      if (browseButton) browseButton.forceActiveFocus()
    })
  }

  function buildMicOptions() {
    var options = [{ value: "", label: "Auto (denoise mic, then default)" }]
    var candidates = Array.isArray(root.svc && root.svc.micCandidates) ? root.svc.micCandidates : []
    for (var i = 0; i < candidates.length; i++) {
      var candidate = candidates[i] || ({})
      options.push({
        value: String(candidate.nodeName || ""),
        label: String(candidate.description || candidate.nodeName || "Unknown source")
          + (candidate.available === false ? "  — unavailable" : "")
      })
    }
    // Keep a pinned choice selectable even if the node vanished since.
    var found = false
    var pinned = root.currentMic
    for (var k = 0; k < options.length; k++)
      if (options[k].value === pinned) { found = true; break }
    if (!found && pinned !== "")
      options.push({ value: pinned, label: pinned + "  — unavailable" })
    return options
  }

  function slotLabelAt(index) {
    return Array.isArray(slotLabels) && index >= 0 && index < slotLabels.length
      ? String(slotLabels[index] || "")
      : ""
  }

  function slotNumberAt(index) {
    return index + 1 < 10 ? "0" + (index + 1) : String(index + 1)
  }

  function commitPath() {
    var path = pathField.text.trim()
    if (path === "") return
    if (root.svc) root.svc.addFiles([path])
    pathField.clear()
  }

  function toggleMonitor() {
    var next = !(root.svc ? !!root.svc.monitorLocally : root.monitorFallback)
    if (root.svc) root.svc.setMonitorLocally(next)
    root.saveSettings({ monitorLocally: next })
  }

  width: parent.width
  spacing: Style.spacing.panelGap

  // Escape bubbles up to the drawer from whatever control holds focus.
  // Opening the drawer focuses the first control, so keys always land here
  // (the panel's key catcher is blocked while this surface is up).
  Keys.priority: Keys.AfterItem
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape) {
      root.requestClose()
      event.accepted = true
    }
  }
  Component.onCompleted: Qt.callLater(function() {
    browseButton.forceActiveFocus()
  })

  // --- Sounds -----------------------------------------------------------------
  Row {
    width: parent.width

    PanelSectionHeader {
      text: "Sounds"
      foreground: root.foreground
      fontFamily: root.fontFamily
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  Row {
    width: parent.width
    spacing: Style.spacing.md

    Button {
      id: browseButton
      width: (parent.width - parent.spacing) / 2
      enabled: root.svc !== null && !root.libraryFull && !root.pickerBusy
      text: root.pickerKind === "files" ? "Waiting for picker…"
        : (root.libraryFull ? "Library full (12)" : "Browse files")
      iconText: "\uf07c"
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      bordered: true
      tooltipText: root.extensionsHint
      onClicked: root.requestPick("files")
    }

    Button {
      width: (parent.width - parent.spacing) / 2
      enabled: root.svc !== null && !root.libraryFull && !root.pickerBusy
      text: root.pickerKind === "folder" || root.pickerKind === "folderScan"
        ? "Waiting for picker…" : "Add folder"
      iconText: "\uf07b"
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      bordered: true
      tooltipText: "Import audio files from a folder — searched three levels deep"
      onClicked: root.requestPick("folder")
    }
  }

  Row {
    width: parent.width
    spacing: Style.spacing.sm

    TextField {
      id: pathField
      width: parent.width - addPath.implicitWidth - parent.spacing
      placeholderText: "\uf0c1  paste a file path, Enter to add"
      foreground: root.foreground
      accent: root.accent
      font.pixelSize: Style.font.bodySmall
      leftPadding: Style.spacing.controlPaddingX
      enabled: root.svc !== null && !root.libraryFull && !root.pickerBusy
      onAccepted: root.commitPath()
      Keys.onEscapePressed: { root.requestClose(); event.accepted = true }
    }

    Button {
      id: addPath
      anchors.verticalCenter: parent.verticalCenter
      enabled: root.svc !== null && !root.libraryFull && !root.pickerBusy
      text: root.libraryFull ? "Full" : "Add from path"
      iconText: "\uf067"
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      bordered: true
      leftAlign: true
      tooltipText: "Add the pasted path as a pad"
      onClicked: root.commitPath()
    }
  }

  Text {
    width: parent.width
    textFormat: Text.PlainText
    text: root.extensionsHint
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // Chooser failures (exit 2) and empty folder scans say it here — never
  // silent, never modal. The text itself is owned by the service.
  Text {
    width: parent.width
    visible: root.pickerError !== ""
    textFormat: Text.PlainText
    text: root.pickerError
    color: root.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    wrapMode: Text.WordWrap
  }

  PanelSeparator { foreground: root.foreground }

  // --- Volume -----------------------------------------------------------------
  PanelSectionHeader {
    text: "Volume"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Row {
    width: parent.width
    spacing: Style.spacing.lg

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: "\uf028"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.iconSmall
    }

    PanelSlider {
      id: masterSlider
      width: parent.width - volumeReadout.implicitWidth - parent.spacing * 2
      anchors.verticalCenter: parent.verticalCenter
      step: 0.05
      value: {
        var v = root.svc ? Number(root.svc.masterVolume) : root.masterVolumeFallback
        if (!isFinite(v) || v < 0) v = 1.0
        return Math.max(0, Math.min(1, v))
      }

      onReleased: function(v) {
        if (root.svc) root.svc.setMasterVolume(v)
        root.saveSettings({ masterVolume: v })
      }
    }

    Text {
      id: volumeReadout
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: Math.round(Math.max(0, Math.min(1, masterSlider.liveValue)) * 100) + "%"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
  }

  Toggle {
    width: parent.width
    label: "Hear pads locally"
    description: "Each pad also plays to your speakers or headphones. On open speakers the mic can catch the sound back — headphones keep calls clean."
    checked: root.svc ? !!root.svc.monitorLocally : root.monitorFallback
    foreground: root.foreground
    accent: root.accent
    titleSize: Style.font.bodySmall
    descriptionSize: Style.font.caption
    fontFamily: root.fontFamily
    onClicked: root.toggleMonitor()
  }

  PanelSeparator { foreground: root.foreground }

  // --- Microphone ---------------------------------------------------------------
  PanelSectionHeader {
    text: "Microphone"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Dropdown {
    width: parent.width
    label: "Loopback source for Soundboard-Mic"
    value: root.currentMic
    options: root.micOptions
    foreground: root.foreground
    accent: root.accent
    fontFamily: root.fontFamily
    onChanged: function(next) {
      if (root.svc) root.svc.setMicSource(next)
      root.saveSettings({ micSource: next })
    }
  }

  Text {
    width: parent.width
    textFormat: Text.PlainText
    text: "In Discord / Zoom, pick Soundboard-Mic as the input — your voice and the pads go out as one device."
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  PanelSeparator { foreground: root.foreground }

  // --- Pads ----------------------------------------------------------------------
  Row {
    width: parent.width
    spacing: Style.spacing.md

    PanelSectionHeader {
      text: "Pads"
      foreground: root.foreground
      fontFamily: root.fontFamily
      anchors.verticalCenter: parent.verticalCenter
    }

    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth
      - padsCount.implicitWidth - parent.spacing * 2); height: 1
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: padsCount
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.pads.length + " / 12"
      color: root.pads.length >= 12 ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  Text {
    width: parent.width
    visible: root.missingCount > 0
    textFormat: Text.PlainText
    text: root.missingCount === 1
      ? "One pad's file is gone from disk — re-add it or remove the pad."
      : root.missingCount + " pads' files are gone from disk — re-add or remove them."
    color: root.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    wrapMode: Text.WordWrap
  }

  Flickable {
    width: parent.width
    height: Math.min(padsColumn.implicitHeight, Style.space(252))
    clip: true
    contentHeight: padsColumn.implicitHeight
    boundsBehavior: Flickable.StopAtBounds

    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: padsColumn
      width: parent.width
      spacing: Style.spacing.xs

      Repeater {
        model: root.pads

        Item {
          id: padRow
          required property int index
          required property var modelData

          readonly property bool rowMissing: root.pads[index] && root.pads[index].missing
          readonly property real rowVolume: {
            var v = Number(root.pads[index] ? root.pads[index].volume : 1)
            return isFinite(v) && v >= 0 ? Math.min(1, v) : 1
          }

          width: parent.width
          height: Math.max(nameField.implicitHeight, Style.space(30))

          Row {
            anchors.fill: parent
            spacing: Style.spacing.sm

            Text {
              width: Style.space(20)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.slotNumberAt(padRow.index)
              color: padRow.rowMissing ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            TextField {
              id: nameField
              width: parent.width - Style.space(20) - Style.space(104)
                - Style.space(30) - Style.space(22) - parent.spacing * 4
              anchors.verticalCenter: parent.verticalCenter
              leftPadding: Style.spacing.sm
              rightPadding: Style.spacing.sm
              font.pixelSize: Style.font.bodySmall
              foreground: root.foreground
              accent: root.accent
              enabled: root.svc !== null
              text: padRow.modelData && !padRow.rowMissing
                ? String(padRow.modelData.name || "")
                : ""
              placeholderText: padRow.rowMissing ? "file gone — rename anyway?" : ""
              onEditingFinished: {
                // Only committed values reach the service; clearing the
                // field restores the existing name instead of wiping it.
                var desired = text.trim()
                if (!root.svc || desired === "") {
                  text = padRow.modelData ? String(padRow.modelData.name || "") : ""
                  return
                }
                if (padRow.modelData && desired === String(padRow.modelData.name)) return
                root.svc.renamePad(padRow.index, desired)
              }
              Keys.onEscapePressed: {
                root.requestClose()
                event.accepted = true
              }
              Component.onCompleted: if (padRow.modelData) text = String(padRow.modelData.name || "")
            }

            PanelSlider {
              id: padVolume
              width: Style.space(104)
              anchors.verticalCenter: parent.verticalCenter
              step: 0.05
              value: padRow.rowVolume
              onReleased: function(v) {
                if (root.svc) root.svc.setPadVolume(padRow.index, v)
              }
            }

            Text {
              width: Style.space(30)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: Math.round(Math.max(0, Math.min(1, padVolume.liveValue)) * 100) + "%"
              color: padRow.rowMissing ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uf00d"
              tooltipText: "Remove pad — the file on disk is untouched"
              foreground: root.dim
              hoverColor: root.urgent
              fontFamily: root.fontFamily
              enabled: root.svc !== null
              onClicked: if (root.svc) root.svc.removePad(padRow.index)
            }
          }
        }
      }
    }
  }

  PanelSeparator { foreground: root.foreground }

  // --- Hotkeys --------------------------------------------------------------------
  PanelSectionHeader {
    text: "Hotkeys"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Text {
    width: parent.width
    textFormat: Text.PlainText
    text: "ALT+1 … ALT+9, ALT+Q, ALT+W, ALT+E play pads 1 … 12 from any window. Run the plugin's install-binds script once to create them."
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Text {
    width: parent.width
    textFormat: Text.PlainText
    text: "Keys here: arrows move · Enter/Space play or stop · x stop cursor pad · s settings · Esc back"
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Row {
    width: parent.width
    spacing: Style.spacing.md
    layoutDirection: Qt.RightToLeft

    Button {
      text: "Done"
      iconText: "\uf00c"
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      bordered: true
      onClicked: root.requestClose()
    }
  }
}
