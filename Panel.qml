import QtQuick
import qs.Commons
import qs.Ui

// Soundboard — bar icon + popup panel.
//
// The pad grid opens on click or IPC ("yami.soundboard open"). A second IPC
// target, "soundboard", exists purely for Hyprland hotkeys: play/stop/stopAll
// must work while another window owns focus, so the panel itself is never
// opened by them. Pad data lives in the plugin Service; this widget is
// read-only state + commands. Widget-level settings (masterVolume,
// monitorLocally, micSource) persist through bar.shell.updateEntryInline so
// the Settings → Plugins form agrees with what the drawer shows.
Panel {
  id: root

  moduleName: "yami.soundboard"
  ipcTarget: "yami.soundboard"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // --- injected by the panel loader, if declared ---
  property var shell: null
  property var service: null

  // --- visual tokens (no hand-rolled colors; theme owns everything) ---
  readonly property color foreground: Color.popups.text
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color urgent: Color.urgent
  readonly property string fontFamily: root.bar && root.bar.fontFamily
    ? root.bar.fontFamily
    : Style.font.family

  // --- data access. The Service singleton, three safe routes so the widget
  // renders even while the service is still being wired up. ---
  readonly property var svc: {
    if (root.service) return root.service
    if (root.shell && typeof root.shell.serviceFor === "function")
      return root.shell.serviceFor("yami.soundboard") || null
    if (root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function")
      return root.bar.shell.serviceFor("yami.soundboard") || null
    return null
  }
  readonly property bool hasService: root.svc !== null
  readonly property var padList: root.hasService && Array.isArray(root.svc.pads)
    ? root.svc.pads
    : []
  readonly property int padCount: root.padList.length

  // 12 hotkey slots: 1..9, then Q/W/E. The grid and drawer both read these;
  // they are the single source of slot-key truth. Slots beyond 12 (extra
  // pads) get an empty label.
  readonly property var hotkeyLabels: {
    var keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "Q", "W", "E"]
    var out = []
    var span = Math.max(12, root.padCount)
    for (var i = 0; i < span; i++) out.push(i < keys.length ? "ALT+" + keys[i] : "")
    return out
  }

  // --- panel state ---
  property bool settingsOpen: false
  property int cursorSlot: -1

  function padAt(index) {
    return index >= 0 && index < root.padCount ? root.padList[index] : null
  }

  function isPlaying(index) {
    var pad = root.padAt(index)
    var playing = root.hasService && root.svc.playing ? root.svc.playing : null
    return !!(pad && playing && playing[pad.id] !== undefined)
  }

  function moveCursor(dx, dy) {
    if (!root.hasService) return
    if (root.cursorSlot < 0) { root.cursorSlot = 0; return }
    var span = Math.max(12, root.padCount)
    root.cursorSlot = Math.max(0, Math.min(span - 1, root.cursorSlot + dx + dy * 4))
  }

  // Enter/Space/click on a slot: play, or stop if already playing (mid-call
  // double-press should silence, not retrigger). Empty slot → open the drawer
  // where "Add sounds" lives. A pad whose file is gone never reacts.
  function activateSlot(index) {
    if (!root.hasService) return
    var pad = root.padAt(index)
    if (!pad) { root.setSettingsOpen(true); return }
    if (pad.missing) return
    if (root.isPlaying(index)) root.svc.stop(index)
    else root.svc.play(index)
  }

  function setSettingsOpen(value) {
    root.settingsOpen = value
    if (!value)
      Qt.callLater(function() {
        if (root.opened && keyCatcher) keyCatcher.forceActiveFocus()
      })
  }

  // Widget-level settings. Mirrors the activity-monitor pattern: merge the
  // current entry, overlay the changed keys, push through the bar shell.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    var current = root.settings || ({})
    for (var existing in current) if (existing !== "id") entry[existing] = current[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // --- status line: device state, activity, and the mic to pick in Discord ---
  readonly property string statusText: {
    if (!root.hasService) return "Service loading…"
    var parts = []
    var s = String(root.svc.audioStatus || "off")
    if (s === "error") parts.push("Audio error")
    else if (root.svc.audioReady) parts.push("Mix ready")
    else if (s === "starting") parts.push("Devices starting…")
    else parts.push("Mic off")
    if (root.svc.activeCount > 0) parts.push(root.svc.activeCount + (root.svc.activeCount === 1 ? " playing" : " playing"))
    parts.push("\uf130 Soundboard-Mic")
    return parts.join(" · ")
  }

  // Settings fallbacks while the service isn't up yet: the widget entry's own
  // persisted values, so the drawer doesn't lie before the service responds.
  readonly property real masterVolumeFallback: {
    var v = Number(setting("masterVolume", 1.0))
    return isFinite(v) ? Math.max(0, Math.min(1, v)) : 1.0
  }
  readonly property bool monitorFallback: setting("monitorLocally", true) !== false
  readonly property string micFallback: String(setting("micSource", "") || "")

  onOpenedChanged: {
    if (opened) {
      root.settingsOpen = false
      root.cursorSlot = root.padCount > 0 ? 0 : -1
    } else {
      root.settingsOpen = false
      root.cursorSlot = -1
    }
  }

  // --- picker launch: close-before-pick handoff ---
  // This panel (KeyboardPanel) is a FULL-SCREEN layer-shell surface on the
  // overlay layer, so a portal file dialog spawned while it is up maps
  // UNDERNEATH it and never receives clicks. A pick therefore always closes
  // the panel first and waits just past the 140 ms card fade-out before the
  // service's picker starts (Qt.callLater fires while the overlay still owns
  // the screen). The pick itself lives in the Service singleton, so the
  // dialog outlives this widget's drawer being destroyed.
  property bool pickFromPanel: false // panel was open when the pick started

  function startPick(kind) {
    if (!root.hasService || root.svc.pickerBusy || pickDelay.running) return
    root.pickFromPanel = root.opened
    var wanted = (kind === "folder") ? "folder" : "files"
    if (root.opened) {
      root.close() // same call the editor and IPC paths use
      pickDelay.pickKind = wanted
      pickDelay.restart()
    } else {
      // panel already closed (e.g. the CTA path ran during close): pick now
      root.svc.pickFiles(wanted)
    }
  }

  Timer {
    id: pickDelay
    interval: 220 // fade-out is 140 ms; a little margin lets the surface unmap
    repeat: false
    property string pickKind: ""

    onTriggered: {
      var kind = pickDelay.pickKind
      pickDelay.pickKind = ""
      if (kind !== "" && root.hasService) root.svc.pickFiles(kind)
    }
  }

  // Result surfacing: when the pick started from an open panel and anything
  // happened (pads added, or the chooser failed and says why), bring the
  // panel back with settings open so the user sees it. Silent cancels stay
  // closed — a quiet no-op.
  Connections {
    target: root.hasService ? root.svc : null

    function onPickerFinished(kind, addedCount) {
      if (!root.pickFromPanel) return
      root.pickFromPanel = false
      var surfaced = addedCount > 0
        || (root.hasService && root.svc.pickerError !== "")
      if (surfaced && !root.opened) {
        root.open()
        // after open(): onOpenedChanged resets settingsOpen when opening
        root.settingsOpen = true
      }
    }
  }

  // --- bar icon ---
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf009"
    tooltipText: "Soundboard"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }

  // One glance at the bar tells you whether a pad is playing.
  Rectangle {
    visible: root.hasService && root.svc.activeCount > 0
    width: Style.space(5)
    height: Style.space(5)
    radius: width / 2
    color: Color.bar.active
    border.color: root.bar ? Color.bar.background : Color.background
    border.width: Math.max(1, Style.space(1))
    anchors { bottom: parent.bottom; right: parent.right
      bottomMargin: Style.space(2); rightMargin: Style.space(2) }
  }

  // --- popup panel ---
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    centerOnBar: false
    contentWidth: panel.fittedContentWidth(Style.space(424))
    contentHeight: panel.fittedContentHeight(
      contentLoader.item ? contentLoader.item.implicitHeight : Style.space(320))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.settingsOpen

      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: {
        root.activateSlot(root.cursorSlot >= 0 ? root.cursorSlot : 0)
      }
      onCloseRequested: {
        if (root.settingsOpen) root.setSettingsOpen(false)
        else if (root.opened) root.close()
      }
      onDeleteRequested: {
        // "x": stop whichever pad sits under the cursor. Stopping is safe
        // while removing a pad is drawer-only, so x never deletes.
        var pad = root.padAt(root.cursorSlot)
        if (pad && !pad.missing && root.hasService && root.isPlaying(root.cursorSlot))
          root.svc.stop(root.cursorSlot)
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        var key = String(text || "").toLowerCase()
        if (key === "s") root.setSettingsOpen(true)
        else if (key === "r" && root.hasService) root.svc.refreshAudio()
      }

      Loader {
        id: contentLoader
        width: parent.width
        sourceComponent: root.settingsOpen ? drawerContent : boardContent
      }
    }
  }

  // hero glyph declared here (Component id) so the deferred boardContent
  // scope resolves it.
  Component {
    id: boardIcon

    Text {
      textFormat: Text.PlainText
      text: "\uf009"
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.display
    }
  }

  Component {
    id: drawerContent

    SettingsDrawer {
      svc: root.svc
      fontFamily: root.fontFamily
      slotLabels: root.hotkeyLabels
      masterVolumeFallback: root.masterVolumeFallback
      monitorFallback: root.monitorFallback
      micFallback: root.micFallback
      onSaveSettings: function(values) { root.persistSettings(values) }
      onRequestClose: root.setSettingsOpen(false)
      // Picker buttons never run inline — bubble up to the close-before-pick
      // handoff above (full-screen overlay would sit over the dialog).
      onRequestPick: function(kind) { root.startPick(kind) }
    }
  }

  Component {
    id: boardContent

    Column {
      id: page
      width: contentLoader.width
      spacing: Style.spacing.panelGap

      Row {
        width: parent.width
        spacing: Style.spacing.md

        PanelHero {
          width: Math.max(1, parent.width - headerActions.implicitWidth - parent.spacing)
          anchors.verticalCenter: parent.verticalCenter
          iconComponent: boardIcon
          title: "Soundboard"
          meta: root.statusText
          detail: root.hasService && root.svc.activeCount > 0
            ? (root.svc.activeCount + " playing")
            : ""
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Row {
          id: headerActions
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.sm

          PanelActionButton {
            iconText: "\uf013"
            tooltipText: root.settingsOpen ? "Back to pads" : "Settings"
            foreground: root.settingsOpen ? root.accent : root.foreground
            hoverColor: root.accent
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.setSettingsOpen(!root.settingsOpen)
          }
        }
      }

      // Service-level audio trouble renders inline — a call is the wrong
      // moment for a modal.
      Text {
        width: parent.width
        visible: root.hasService && root.svc.audioStatus === "error"
        text: "\uf071  " + (root.hasService ? String(root.svc.lastError || "Audio devices failed") : "")
        textFormat: Text.PlainText
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        wrapMode: Text.WordWrap
      }

      PanelSeparator { foreground: root.foreground }

      PadGrid {
        visible: root.padCount > 0
        width: parent.width
        pads: root.padList
        playingMap: root.hasService && root.svc.playing ? root.svc.playing : ({})
        cursorSlot: root.cursorSlot
        labels: root.hotkeyLabels
        fontFamily: root.fontFamily
        onPadActivated: function(index) { root.activateSlot(index) }
        onSlotAddRequested: function(index) {
          root.cursorSlot = index
          root.setSettingsOpen(true)
        }
      }

      EmptyState {
        visible: root.hasService && root.padCount === 0
        width: parent.width
        // First run: one click straight to the working file picker — through
        // the close-before-pick handoff, never by opening the drawer first.
        onAddRequested: root.startPick("files")
      }

      Text {
        width: parent.width
        visible: !root.hasService
        text: "Service is starting…"
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
      }

      // Footer: device state · who is playing · stop all — one row, mouse or
      // keyboard (x stops the cursor's pad; the button is the mouse path).
      Row {
        width: parent.width
        spacing: Style.spacing.md

        MouseArea {
          id: footerZone
          width: parent.width - (stopAll.visible ? stopAll.implicitWidth + parent.spacing : 0)
          implicitHeight: footerLine.implicitHeight
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor

          Text {
            id: footerLine
            width: parent.width
            text: root.statusText
            textFormat: Text.PlainText
            color: root.hasService && root.svc.audioStatus === "error" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
          }

          PanelToolTip {
            visible: footerZone.containsMouse && root.hasService
              && root.svc.audioStatus !== "error"
            text: "In Discord / Zoom, pick Soundboard-Mic as your input — your voice and the pads travel together."
            fontFamily: root.fontFamily
          }
        }

        Button {
          id: stopAll
          visible: root.hasService && root.svc.activeCount > 0
          text: "Stop all"
          iconText: "\uf04d"
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          bordered: true
          anchors.verticalCenter: parent.verticalCenter
          onClicked: if (root.hasService) root.svc.stopAll()
        }
      }
    }
  }

  component EmptyState: Column {
    id: emptyState

    width: parent.width
    spacing: Style.spacing.md

    signal addRequested()

    Item {
      width: parent.width
      height: emptyGlyph.implicitHeight

      Text {
        id: emptyGlyph
        textFormat: Text.PlainText
        text: "\uf009"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.displayLarge
        anchors.horizontalCenter: parent.horizontalCenter
      }
    }

    Item {
      width: parent.width
      height: emptyTitle.implicitHeight

      Text {
        id: emptyTitle
        textFormat: Text.PlainText
        text: "No sounds yet"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        anchors.horizontalCenter: parent.horizontalCenter
      }
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: "Add audio files — they fill the twelve hotkey slots in order, and play with ALT+1 … ALT+E even while a call has focus."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      horizontalAlignment: Text.AlignHCenter
    }

    Button {
      width: Style.space(180)
      anchors.horizontalCenter: parent.horizontalCenter
      text: "Add sounds"
      iconText: "\uf067"
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      bordered: true
      onClicked: emptyState.addRequested()
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: "In Discord / Zoom, pick Soundboard-Mic as the input — your voice and the pads arrive together."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      horizontalAlignment: Text.AlignHCenter
      opacity: 0.85
    }
  }
}
