pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// yami.soundboard — headless service (SPEC §5 contract).
//
// Owns the audio lifecycle by delegating module plumbing to the plugin's
// bash script (scripts/soundboard-audio: setup / refresh-mic / status), owns
// library.json (~/.local/share/yami.soundboard/library.json, atomic
// temp+rename writes), and runs the playback pool (Quickshell.Io Process per
// `pw-play`, argv arrays only — never shell strings).
//
// Reach it from the bar widget with: shell.serviceFor("yami.soundboard")
// Hotkey path: IpcHandler target "soundboard" → omarchy-shell soundboard play 1
//
// Root is Quickshell.Scope, not bare QtObject: SPEC §3 says "non-visual
// QtObject", but QtObject has no default property, so it cannot own the
// IpcHandler / Process / Component children this service needs. Scope is the
// Quickshell non-visual root for exactly this (working precedent:
// twiking.omasettings' service). It instantiates once like a QtObject.
Scope {
  id: root

  // ------------------------------------------------ injected by the shell
  property var shell: null        // capability facade (summon/hide/serviceFor…)
  property var manifest: null     // stamped manifest object
  property string omarchyPath: ""

  // ------------------------------------------------ state (NOTIFY-able)
  property bool ready: false                 // service initialised
  property bool audioReady: false            // virtual devices up and verified
  property string audioStatus: "off"         // "ready" | "starting" | "error" | "off"
  property string lastError: ""
  property var pads: []                      // [{ id, name, path, volume, slot, missing, key }]
  property var playing: ({})                 // { padId: true } — main players live
  property int activeCount: 0                // sounds currently audible
  property real masterVolume: 1.0            // 0..1 → per-pad stream gain (never the mix sink)
  property bool monitorLocally: true         // mirror pads to the system default sink
  property string micSource: ""              // "" = auto, else pinned source node
  property var micCandidates: []             // [{ nodeName, description, available }]

  // Portal picker state — the process lives here (singleton), so a pick
  // survives the panel closing (see the picker API section below).
  property bool pickerBusy: false            // a pick (incl. folder scan) is in flight
  property string pickerKind: ""             // "" idle · "files"/"folder" dialog open · "folderScan" reading folder
  property string pickerError: ""            // inline failure text, cleared when a pick starts

  // ------------------------------------------------ internals
  readonly property string pluginDir: {
    // Qt.resolvedUrl(".") is how sibling plugins derive their own dir; a URL
    // may be percent-encoded, so decode it.
    var v = String(Qt.resolvedUrl("."))
    if (v.indexOf("file://") === 0) v = v.substring(7)
    try { v = decodeURIComponent(v) } catch (e) {}
    return v.replace(/\/$/, "")
  }
  readonly property string audioScript: pluginDir + "/scripts/soundboard-audio"
  readonly property string libDir: (Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share") + "/yami.soundboard"
  readonly property string libPath: libDir + "/library.json"

  readonly property var slotKeys: ["1","2","3","4","5","6","7","8","9","Q","W","E"]
  readonly property int maxPads: 12
  readonly property int maxPlayers: 24

  property var _pool: []            // live player wrappers: { proc, padId, monitor, dead }
  property var _pendingPlay: []     // pad indexes queued while audio is coming up
  property bool _libLoaded: false   // Ignore mutations that arrive before the store is loaded
  property bool _saving: false
  property string _pendingSave: ""
  property int _idSeq: 0

  // ------------------------------------------------ library persistence
  // Every mutation: update root state → saveLibrary() (atomic temp + rename)
  // → _syncPads() (NOTIFY the UI).

  function _defaultLibrary() {
    return { version: 1, masterVolume: 1.0, monitorLocally: true, micSource: "", pads: [] }
  }

  function _clamp01(v) {
    var n = Number(v)
    if (isNaN(n)) return 0
    return Math.min(1, Math.max(0, n))
  }

  function saveLibrary() {
    var lib = {
      version: 1,
      masterVolume: root.masterVolume,
      monitorLocally: root.monitorLocally,
      micSource: root.micSource,
      pads: []
    }
    for (var i = 0; i < root._storePads.length; i++) {
      var p = root._storePads[i]
      lib.pads.push({
        id: String(p.id || ""),
        name: String(p.name || ""),
        path: String(p.path || ""),
        volume: root._clamp01(p.volume === undefined ? 1 : p.volume),
        // slots 1..12 are fixed hotkey slots, assigned in pad order
        slot: (i < root.maxPads) ? (i + 1) : 0
      })
    }
    var json = JSON.stringify(lib, null, 2)
    if (root._saving) { root._pendingSave = json; return }
    root._saving = true
    root._atomicWrite(json)
  }

  function _atomicWrite(json) {
    saveProc.command = [
      "bash", "-c",
      'tmp=$(mktemp "$1.XXXXXX") && printf \'%s\' "$2" > "$tmp" && mv -f "$tmp" "$1"',
      "atomic-write", root.libPath, json
    ]
    saveProc.running = false
    saveProc.running = true
  }

  // backing store for pads (raw entries), kept in sync with pad mutations
  property var _storePads: []

  function _syncPads() { // recompute public `pads` from _storePads
    var list = []
    for (var i = 0; i < root._storePads.length; i++) {
      var p = root._storePads[i]
      var slot = (i < root.maxPads) ? (i + 1) : 0
      list.push({
        id: String(p.id || ""),
        name: String(p.name || ""),
        path: String(p.path || ""),
        volume: root._clamp01(p.volume === undefined ? 1 : p.volume),
        slot: slot,
        missing: String(p.missing || "") === "1",
        key: slot > 0 ? ("ALT + " + root.slotKeys[slot - 1]) : ""
      })
    }
    root.pads = list
  }

  // ------------------------------------------------ playback pool

  Component {
    id: playerComponent

    Process {
      id: proc
      property string padId: ""          // value properties (strings/bools) —
      property bool monitorRole: false   // survive createObject property copy

      stdout: StdioCollector { waitForEnd: false }
      stderr: StdioCollector { waitForEnd: false }

      onExited: { root._playerDone(proc) }
    }
  }

  function _spawn(argv, padId, monitor) {
    if (!argv || argv.length === 0) return

    // steal the oldest live player when the pool is exhausted
    while (root._pool.length >= root.maxPlayers) {
      var oldest = root._pool[0]
      root._pool.shift()
      oldest.running = false // SIGTERM; it reaps itself in _playerDone
    }

    var proc = playerComponent.createObject(null, {
      command: argv,
      padId: String(padId || ""),
      monitorRole: !!monitor
    })
    if (!proc) {
      root.lastError = "could not spawn player process"
      console.debug("soundboard: createObject failed for", JSON.stringify(argv))
      return
    }
    proc.running = true
    root._pool.push(proc)
    root._syncPlayback()
  }

  function _playerDone(proc) {
    var at = root._pool.indexOf(proc)
    if (at === -1) { proc.destroy(); return } // killed earlier; just reap
    root._pool.splice(at, 1)
    proc.destroy()
    root._syncPlayback()
  }

  function _syncPlayback() { // rebuild `playing` + `activeCount` from live pool
    var map = {}
    var count = 0
    for (var i = 0; i < root._pool.length; i++) {
      var w = root._pool[i]
      if (!w.padId || w.monitorRole) continue
      if (!(w.padId in map)) { map[w.padId] = i; count++ }
    }
    root.playing = map
    root.activeCount = count
  }

  function _killPad(padId) { // SIGTERM this pad's players incl. monitor copy
    for (var i = 0; i < root._pool.length; i++) {
      var proc = root._pool[i]
      if (proc.padId === padId) proc.running = false
    }
    root._pool = root._pool.filter(function (p) { return (p.padId || "") !== String(padId) })
    root._syncPlayback()
  }

  function isPlaying(index) {
    var p = root.pads[index]
    return p ? (root.playing["" + p.id] !== undefined) : false
  }

  // ------------------------------------------------ pad helpers

  function padForId(padId) {
    for (var i = 0; i < root._storePads.length; i++)
      if (String(root._storePads[i].id) === String(padId)) return root._storePads[i]
    return null
  }

  function _baseNameOf(path) {
    var s = String(path).replace(/\/+$/, "")
    var at = s.lastIndexOf("/")
    var base = (at >= 0) ? s.substring(at + 1) : s
    var dot = base.lastIndexOf(".")
    return (dot > 0) ? base.substring(0, dot) : base
  }

  // ------------------------------------------------ playback (API)

  function play(index) {
    if (index === undefined || index < 0 || index >= root.pads.length) return false
    var pad = root.pads[index]
    if (!pad) return false

    if (pad.missing) {
      root.lastError = "pad '" + pad.name + "' is missing its file"
      return true // pad stays visible; playback skipped (do not auto-delete)
    }

    if (!root.audioReady) {
      root.refreshAudio()
      if (root._pendingPlay.indexOf(index) === -1) root._pendingPlay.push(index)
      return true
    }

    var store = root.padForId(pad.id)
    if (!store) return false

    // retrigger semantics: same pad restarts rather than stacks
    root._killPad(pad.id)

    var file = String(store.path)
    var padVol = root._clamp01(store.volume === undefined ? 1 : store.volume)
    // Master is applied per stream, never on the mix sink: that sink also
    // carries the voice loopback, so scaling it would make the far end hear
    // the user quieter by the same amount. Stream gain keeps the voice at
    // unity, and because the local monitor copy uses this same value, what you
    // hear is what they hear (0 % is genuinely silent on both paths).
    var vol = (padVol * root._clamp01(root.masterVolume)).toFixed(3)
    var ext = (file.lastIndexOf(".") >= 0)
      ? file.substring(file.lastIndexOf(".") + 1).toLowerCase() : ""

    // SPEC §2: wav/flac/mp3/ogg go straight through pw-play; exotic formats
    // (m4a, opus-in-capsule, webm…) fall back to an ffmpeg wav pipe.
    var direct = (["wav", "flac", "mp3", "ogg", "oga"].indexOf(ext) !== -1)

    var main
    if (direct) {
      main = ["pw-play", "--target=soundboard.mix", "--volume=" + vol,
              "--latency=50ms", file]
    } else {
      main = ["bash", "-lc",
              'ffmpeg -loglevel error -i "$1" -f wav - | ' +
              'pw-play --target=soundboard.mix --volume="$2" --latency=50ms -',
              "soundboard-pipe", file, vol]
    }
    root._spawn(main, pad.id, false)

    if (root.monitorLocally) {
      var monitor
      if (direct) {
        monitor = ["pw-play", "--volume=" + vol, "--latency=50ms", file]
      } else {
        monitor = ["bash", "-lc",
                   'ffmpeg -loglevel error -i "$1" -f wav - | ' +
                   'pw-play --volume="$2" --latency=50ms -',
                   "soundboard-pipe-monitor", file, vol]
      }
      root._spawn(monitor, pad.id, true)
    }

    root._syncPlayback()
    return true
  }

  function stop(index) {
    if (index === undefined || index < 0 || index >= root.pads.length) return
    var pad = root.pads[index]
    if (pad) root._killPad(pad.id)
  }

  function stopAll() {
    for (var i = 0; i < root._pool.length; i++) {
      var proc = root._pool[i]
      proc.running = false
    }
    root._pool = []
    root._syncPlayback()
  }

  // ------------------------------------------------ library (API)

  function addFiles(paths) {
    if (!paths || paths.length === 0) return
    var added = false
    for (var i = 0; i < paths.length; i++) {
      var path = String(paths[i])
      var exists = false
      for (var j = 0; j < root._storePads.length; j++)
        if (String(root._storePads[j].path) === path) { exists = true; break }
      if (exists || path === "") continue
      root._idSeq++
      var entry = {
        id: "p" + root._idSeq,
        name: root._baseNameOf(path),
        path: path,
        volume: 1
      }
      root._storePads.push(entry)
      added = true
    }
    if (added) { root.saveLibrary(); root._syncPads() }
  }

  function removePad(index) {
    if (index === undefined || index < 0 || index >= root._storePads.length) return
    var pad = root.pads[index]
    if (pad) root._killPad(pad.id)
    root._storePads.splice(index, 1)
    root.saveLibrary()
    root._syncPads()
  }

  function movePad(from, to) {
    if (from < 0 || from >= root._storePads.length) return
    to = Math.min(to, root._storePads.length - 1)
    if (to < 0 || from === to) return
    var pad = root._storePads.splice(from, 1)[0]
    root._storePads.splice(to, 0, pad)
    root.saveLibrary()
    root._syncPads()
  }

  function renamePad(index, name) {
    if (index === undefined || index < 0 || index >= root._storePads.length) return
    root._storePads[index].name = String(name)
    root.saveLibrary()
    root._syncPads()
  }

  function setPadVolume(index, v) {
    if (index === undefined || index < 0 || index >= root._storePads.length) return
    root._storePads[index].volume = root._clamp01(v)
    root.saveLibrary()
    root._syncPads()
  }

  // ------------------------------------------------ portal file picker (API)
  // The drawer only asks (requestPick → widget → pickFiles); this service
  // owns the omarchy-file-select Process so a pick survives the panel
  // closing — the dialog is a normal toplevel and must not map underneath
  // the panel's full-screen overlay surface.
  //
  // Flow: pickFiles() runs the chooser; exit 0 with lines either adds pads
  // directly ("files") or scans the chosen directory for audio files up to
  // three levels deep ("folder" → find). Exit codes decide everything:
  // 2 = chooser itself failed (say so inline), any other non-zero = the
  // user cancelled — a quiet no-op. pickerFinished(kind, addedCount) fires
  // exactly once per pick, after the folder scan is folded in; kind ends up
  // "files" or "folder", never "".
  readonly property var audioExtensions: ["wav", "mp3", "ogg", "flac", "m4a", "opus", "aiff", "webm", "oga"]
  readonly property string extensionsHint: "Audio types: " + root.audioExtensions.join(" · ")
  signal pickerFinished(string kind, int addedCount)

  property string _pickRequested: "files" // the pick's original kind — must survive the folder-scan stage
  property string _pickOut: ""            // stdout snapshots (StdioCollector keeps .text only until the next run)
  property string _scanOut: ""

  function pickFiles(kind) {
    if (root.pickerBusy) return
    root.pickerError = ""
    root.pickerBusy = true
    root._pickRequested = (kind === "folder") ? "folder" : "files"
    root.pickerKind = root._pickRequested
    root._pickOut = ""
    // Same argv as the drawer used to build: dialog titles preserved, the
    // extension list feeds the multiple-file chooser filter.
    pickProc.command = root._pickRequested === "folder"
      ? ["omarchy-file-select", "--title", "Add sounds — pick a folder", "--directory"]
      : ["omarchy-file-select", "--title", "Add sounds — pick audio files",
         "--multiple", "--extensions", root.audioExtensions.join(" ")]
    pickProc.running = true
  }

  function _pickExited(code) {
    var requested = root._pickRequested
    var out = String(root._pickOut || "")
    root._pickOut = ""
    if (code === 2) {
      root.pickerError = "The chooser didn't open — try again, or paste a file path below."
      root._pickerDone(requested, 0)
      return
    }
    if (code !== 0) { root._pickerDone(requested, 0); return } // user cancelled: quiet no-op
    var lines = root._linesOf(out)
    if (lines.length === 0) { root._pickerDone(requested, 0); return }
    if (requested === "folder") {
      var target = String(lines[0] || "").trim()
      if (target === "") { root._pickerDone(requested, 0); return }
      root.pickerKind = "folderScan"
      // argv only (never a shell string), so the path needs no quoting.
      // NOTE: do NOT use -iregex here. GNU find's -regex/-iregex speaks Emacs
      // regex, where a bare "(" and "|" are literals — ".*\.(wav|mp3)$" matches
      // nothing at all. Explicit -iname alternation is dialect-proof.
      var findArgs = ["find", "-L", target, "-maxdepth", "3", "-type", "f", "("]
      for (var e = 0; e < root.audioExtensions.length; e++) {
        if (e > 0) findArgs.push("-o")
        findArgs.push("-iname", "*." + root.audioExtensions[e])
      }
      findArgs.push(")")
      scanProc.command = findArgs
      scanProc.running = true
    } else {
      var added = root._countNewPads(lines)
      root.addFiles(lines)
      root._pickerDone("files", added)
    }
  }

  // Folder import, stage two: the chooser gave one directory; a find argv
  // pulls out audio files up to three levels deep. Empty result still
  // deserves a sentence.
  function _scanExited(code) {
    var out = String(root._scanOut || "")
    root._scanOut = ""
    if (code !== 0) {
      root.pickerError = "Couldn't read that folder — try picking the files one by one."
      root._pickerDone("folder", 0)
      return
    }
    var paths = root._linesOf(out)
    if (paths.length === 0) {
      root.pickerError = "No audio files in that folder (searched three levels deep)."
      root._pickerDone("folder", 0)
      return
    }
    var added = root._countNewPads(paths)
    root.addFiles(paths)
    root._pickerDone("folder", added)
  }

  // Exact one completion per pick: busy/kind reset, then the signal (the
  // panel decides on reopened state from the signal handler).
  function _pickerDone(kind, addedCount) {
    root.pickerKind = ""
    root.pickerBusy = false
    root.pickerFinished(kind, addedCount)
  }

  function _linesOf(text) {
    var out = []
    var parts = String(text || "").split("\n")
    for (var i = 0; i < parts.length; i++) {
      var line = String(parts[i]).trim()
      if (line !== "") out.push(line)
    }
    return out
  }

  // How many of these paths are not pads yet; addFiles() dedupes by path,
  // so this mirrors it — counted BEFORE the call mutates the store.
  function _countNewPads(paths) {
    var n = 0
    for (var i = 0; i < paths.length; i++) {
      var path = String(paths[i])
      if (path === "") continue
      var exists = false
      for (var j = 0; j < root._storePads.length; j++)
        if (String(root._storePads[j].path) === path) { exists = true; break }
      if (!exists) n++
    }
    return n
  }

  function reload() {
    loadProc.running = false
    loadProc.running = true
  }

  // ------------------------------------------------ audio device (API)

  function refreshAudio() {
    if (root.audioStatus !== "ready") root.audioStatus = "starting"
    var argv = [root.audioScript, "setup"]
    if (root.micSource !== "") argv.push("--mic", root.micSource)
    audioProc.command = argv
    audioProc.running = true
  }

  function readAudioStatus() {
    statusProc.running = false
    statusProc.running = true
  }

  function setMonitorLocally(b) {
    root.monitorLocally = !!b
    saveLibrary()
  }

  function setMasterVolume(v) {
    root.masterVolume = root._clamp01(v)
    saveLibrary()
    root._normalizeMixVolume()
  }

  // The mix sink is a summing bus for pads *and* the voice loopback, so its
  // volume is not ours to scale — pad gain lives on the player streams. Older
  // builds did store master there (attenuating the user's voice with it), so
  // reset it to unity whenever master moves and after every setup.
  function _normalizeMixVolume() {
    Quickshell.execDetached([
      "bash", "-c",
      'sink_exists() { pactl list short sinks | awk -v n="$1" \'{ if ($2 == n) f = 1 } END { exit f ? 0 : 1 }\'; }\n' +
      'sink_exists soundboard.mix && pactl set-sink-volume soundboard.mix 100%',
      "soundboard-volume-normalize"
    ])
  }

  function setMicSource(nodeName) {
    root.micSource = String(nodeName || "")
    saveLibrary()
    refreshAudio()
  }

  // ------------------------------------------------ processes

  Process {
    id: audioProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onTextChanged: {
        var lines = String(text).split("\n").filter(Boolean)
        root._audioStderrTail = lines.length ? lines[lines.length - 1] : ""
      }
    }

    onExited: function (code) {
      if (code === 0) {
        root.audioStatus = "ready"
        root.audioReady = true
        root.lastError = ""
        root._normalizeMixVolume()   // sink is a bus, not a gain stage
      } else {
        root.audioStatus = "error"
        root.audioReady = false
        root.lastError = "soundboard.mic did not come up" +
          (root._audioStderrTail ? " (script: " + root._audioStderrTail + ")" : "")
      }
      root.readAudioStatus()
      root._drainPendingPlay()
    }
  }

  property string _audioStderrTail: ""

  // The conferencing graph settles after ours: Omavoice re-creates its AEC
  // pipeline on shell restart and on preset change, and WirePlumber can then
  // move our remap stream to the default sink monitor. The mic still exists
  // and reports ready while carrying no pads, so re-assert the feed. This is
  // two pactl calls and a no-op when the wiring is already correct.
  Timer {
    interval: 5000
    repeat: true
    running: root.audioReady
    onTriggered: if (!pinProc.running) pinProc.running = true
  }

  Process {
    id: pinProc
    command: [root.audioScript, "pin"]
  }

  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onTextChanged: root._statusJson = text
    }

    onExited: function (code) {
      if (code !== 0 || root._statusJson === "") return
      try {
        var data = JSON.parse(root._statusJson)
        root.micCandidates = data.micCandidates || []
        if (data.ready) {
          root.audioReady = true
          root.audioStatus = "ready"
        } else {
          root.audioReady = false
          root.audioStatus = root.audioStatus === "starting" ? "starting" : "error"
        }
      } catch (e) {
        root.lastError = "could not parse audio status: " + e
      }
      root._statusJson = ""
      root._drainPendingPlay()
    }
  }

  property string _statusJson: ""

  // loadProc: cat library.json (one shot, not a watcher — `reload()` re-runs)
  Process {
    id: loadProc
    command: [
      "bash", "-c",
      'mkdir -p "$1"\n' +
      'if [ -f "$2" ]; then cat "$2"; fi',
      "load-library", root.libDir, root.libPath
    ]
    stdout: StdioCollector { waitForEnd: true; onTextChanged: root._libJson = text }

    onExited: function (code) {
      root._applyLibraryJson(code === 0 ? root._libJson : "")
    }
  }

  // saveProc: atomic temp+rename write (SPEC §5 rule)
  Process {
    id: saveProc
    stdout: StdioCollector {}

    onExited: function (code) {
      root._saving = false
      if (code !== 0) root.lastError = "could not save library.json"
      if (root._pendingSave !== "") {
        var json = root._pendingSave
        root._pendingSave = ""
        root._saving = true
        root._atomicWrite(json)
      }
    }
  }

  // missingProc: batch `[ -f path ]` test, one 0/1 per pad, same order
  Process {
    id: missingProc
    stdout: StdioCollector { waitForEnd: true; onTextChanged: root._missingOut = text }

    onExited: function () {
      var lines = root._missingOut.split("\n").filter(Boolean)
      for (var i = 0; i < root._storePads.length; i++)
        root._storePads[i].missing = (lines[i] === "0") ? "1" : "0"
      root._missingOut = ""
      root._syncPads()
    }
  }

  property string _missingOut: ""
  property string _libJson: ""

  // Portal picker processes. Living here (the singleton), not in the
  // drawer, is the point: the panel closes and unmaps its overlay before
  // the dialog is clickable, and a drawer-owned Process would die with the
  // drawer the moment that happens.
  Process {
    id: pickProc
    command: ["omarchy-file-select"]
    stdout: StdioCollector {
      waitForEnd: true
      onTextChanged: root._pickOut = text
    }
    onExited: function (code) { root._pickExited(code) }
  }

  // Folder scan (used only by the "folder" pick stage two — see _pickExited)
  Process {
    id: scanProc
    command: ["true"]
    stdout: StdioCollector {
      waitForEnd: true
      onTextChanged: root._scanOut = text
    }
    onExited: function (code) { root._scanExited(code) }
  }

  function _updateMissing() {
    var paths = []
    for (var i = 0; i < root._storePads.length; i++)
      paths.push(String(root._storePads[i].path || ""))
    missingProc.command = [
      "bash", "-c",
      'for p in "$@"; do [ -n "$p" ] && [ -f "$p" ] && echo 1 || echo 0; done',
      "missing-check"
    ]
    for (var j = 0; j < paths.length; j++) missingProc.command.push(paths[j])
    missingProc.running = false
    missingProc.running = true
  }

  function _applyLibraryJson(text) {
    var lib = root._defaultLibrary()
    if (text) {
      try { lib = JSON.parse(text) } catch (e) {
        root.lastError = "library.json unreadable, starting fresh: " + e
        lib = root._defaultLibrary()
      }
    }
    if (!lib.pads || !Array.isArray(lib.pads)) lib.pads = []
    root.masterVolume = root._clamp01(lib.masterVolume === undefined ? 1 : lib.masterVolume)
    root.monitorLocally = (lib.monitorLocally !== undefined) ? !!lib.monitorLocally : true
    root.micSource = String(lib.micSource || "")

    root._storePads = []
    var seen = {}
    for (var i = 0; i < lib.pads.length; i++) {
      var p = lib.pads[i]
      if (!p || !p.path) continue
      if (seen[String(p.path)]) continue // dedupe by path, never auto-delete a pad
      seen[String(p.path)] = true
      root._storePads.push({
        id: String(p.id || ("p" + i)),
        name: String(p.name || root._baseNameOf(p.path)),
        path: String(p.path),
        volume: root._clamp01(p.volume === undefined ? 1 : p.volume)
      })
      var idx = String(p.id || "")
      var m = /^(p)(\d+)$/.exec(idx)
      if (m) root._idSeq = Math.max(root._idSeq, parseInt(m[2]))
    }
    root._libLoaded = true
    root.ready = true
    root._syncPads()
    root._updateMissing()
  }

  function _drainPendingPlay() {
    if (!root.audioReady || root._pendingPlay.length === 0) return
    var queue = root._pendingPlay
    root._pendingPlay = []
    for (var i = 0; i < queue.length; i++) root.play(queue[i])
  }

  // ------------------------------------------------ IPC (hotkey path)
  //(panel's own ipcTarget owns open/close; playback is exposed here under a
  // separate target so Hyprland binds work whether the bar is visible or not)

  IpcHandler {
    target: "soundboard"

    // Hotkey/CLI convention is 1-based slot numbers (ALT + N), matching how
    // pads are shown. The service API itself is 0-based pad indexes.
    function play(slot: int): void { root.play(slot > 0 ? slot - 1 : slot) }
    function stop(slot: int): void { root.stop(slot > 0 ? slot - 1 : slot) }
    function stopAll(): void { root.stopAll() }
    function status(): string {
      return JSON.stringify({
        ready: root.ready,
        audioReady: root.audioReady,
        audioStatus: root.audioStatus,
        lastError: root.lastError,
        pads: root.pads,
        playing: root.playing,
        activeCount: root.activeCount
      })
    }
  }

  // ------------------------------------------------ lifecycle

  Component.onCompleted: {
    loadProc.running = true               // read library.json
    root.refreshAudio()                   // idempotent module setup
  }

  // Unload/disable must remove the virtual devices (DoD #3); detached so it
  // survives the destruction of this object. Teardown is exact — it unloads
  // only modules created with the soundboard names.
  Component.onDestruction: {
    Quickshell.execDetached([root.audioScript, "teardown"])
  }
}




