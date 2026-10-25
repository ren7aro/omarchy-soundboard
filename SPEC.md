# Soundboard — Omarchy shell plugin

A soundboard for calls: pads in the Omarchy bar, hotkeys that work while
Discord/Zoom has focus, and a virtual microphone that carries **your voice +
the sounds** so the far end hears both on one device.

Author: hand-built for this machine. Plugin id `yami.soundboard`.
Install location (also the source of truth): `~/.config/omarchy/plugins/yami.soundboard/`.

---

## 1. Environment (verified on this machine, do not re-derive)

| Fact | Value |
| --- | --- |
| OS | Omarchy (Arch), Hyprland 0.56.2 |
| Audio | PipeWire 1.6.9 + pipewire-pulse (`pactl` works) |
| Quickshell | 0.3.2 (`qs --version`), Qt 6.12 |
| Shell | `omarchy-shell` running, IPC alive (`omarchy-shell shell ping` → `ok`) |
| Default source | `omavoice` (Omavoice plugin's denoise virtual mic) |
| Default sink | `alsa_output.pci-0000_09_00.4.analog-stereo` |
| Hardware mic | `alsa_input.usb-MV-SILICON_fifine_Microphone_20190808-00.analog-stereo` |
| Tools | `pw-play`, `pw-record`, `pw-cat`, `ffmpeg`, `pactl` all present |
| Logs | `journalctl -t omarchy-shell` |

`~/.config/omarchy/plugins/` is user-owned. **Never edit `/usr/share/omarchy/`.**
Read it freely.

---

## 2. Audio architecture (validated end-to-end)

Validated by recording from the virtual source while playing into the mix sink:
WAV −21 dB peak, MP3 −21 dB peak, two concurrent pads both mixed, mic loopback
coexists. No format transcoding needed for wav/flac/mp3/ogg.

```
                      ┌──────────────────────────────┐
 mic / omavoice ─────►│ module-loopback (20 ms)      │
                      │                              │
 pads (pw-play) ─────►│ module-null-sink             │──► soundboard.mix (sink)
                      │  sink_name=soundboard.mix    │
                      └──────────────┬───────────────┘
                                     │ .monitor
                                     ▼
                        module-remap-source  ──► soundboard.mic  (Audio/Source)
                                                  "Soundboard-Mic"
```

Exact commands (use these; they are proven):

```sh
# 1. mix sink
pactl load-module module-null-sink \
  sink_name=soundboard.mix \
  sink_properties=device.description="Soundboard-Mix"

# 2. the microphone the user already uses (prefer omavoice so denoise stays in path)
pactl load-module module-loopback \
  source=<resolved-mic> sink=soundboard.mix \
  latency_msec=20 source_dont_move=true sink_dont_move=true

# 3. expose the mix as a real input device
pactl load-module module-remap-source \
  master=soundboard.mix.monitor source_name=soundboard.mic \
  source_properties=device.description="Soundboard-Mic"
```

Playback:

```sh
pw-play --target=soundboard.mix --volume=<0..1> --latency=50ms <file>
# exotic formats (m4a, opus, webm) fall back to:
ffmpeg -loglevel error -i <file> -f wav - | pw-play --target=soundboard.mix -
```

Reading a pad's live state: an audio stream is NOT required; the UI tracks
`running` on the QML Process that spawned `pw-play`.

### Invariants (non-negotiable)

1. **Never change the system default source or default sink.** The user picks
   "Soundboard-Mic" in the conferencing app. Hijacking defaults breaks Omavoice
   and their speakers.
2. **Feedback guard:** the mic resolved for the loopback must never be
   `soundboard.mic`, `soundboard.mix.monitor`, or the remap source itself. If it
   resolves to one of those, fall back to the default *hardware* source.
3. **Idempotent setup.** `setup` must detect an already-loaded `soundboard.mix`
   / `soundboard.mic` and reuse it, never stack duplicates.
4. **Teardown on disable/unload.** Unload every module this plugin created.
   Track module ids so teardown is exact (`module id` returned by `pactl`).
5. **Mic resolution order:** explicit user pin → `omavoice` if that node exists
   → system default source → first non-monitor hardware source.
6. **Latency budget:** loopback 20 ms, player 50 ms. Do not raise without need.
7. **The panel must be closed before any portal dialog opens.** `KeyboardPanel`
   is a *full-screen* layer-shell surface on the overlay layer; a portal toplevel
   maps underneath it and never receives clicks, while the click lands on the
   overlay backdrop, closes the panel and destroys whatever owned the dialog.
   Hence: the picker `Process` lives in `Service` (survives the widget), and
   `Panel.startPick()` closes the panel and waits past the 140 ms fade-out
   (220 ms timer) before calling `svc.pickFiles()`. Never spawn a chooser from
   inside the drawer, and never use `Qt.callLater` for that handoff — it fires
   while the overlay still owns the screen.
8. **The mix sink is a bus at unity gain; master volume is per stream.**
   `soundboard.mix` sums pads *and* the voice loopback, so its volume must stay
   at 100 % — scaling it attenuates the user's voice for the far end by the same
   amount (that was a real bug: master 50 % made the user 18 dB quieter). Master
   is baked into each player's `--volume` as `padVolume × masterVolume`, and the
   local monitor copy uses the identical value, so the local preview is honest
   and 0 % is silent on both paths. Never reintroduce sink-volume master.

### Monitoring locally

Optional, persisted in widget settings (`monitorLocally`, default `true`): the
user should hear their own pads. Implement by ALSO spawning a second `pw-play`
to the system default sink (same file, same volume, same start). Do **not**
add a loopback from `soundboard.mix` to the speakers. Keep the two players
independent so a stopped pad stops both.

Echo warning: when monitoring is on and the user is on speakers (not
headphones), the mic can re-capture the pad. Surface this once in the settings
drawer as a one-line note. Do not block it.

---

## 3. Plugin contract (verified against local source)

Evidence: `/usr/share/omarchy/shell/shell.qml:1747`, `services/PluginRegistry.qml:43-116`,
`Ui/{BarWidget,Panel,KeyboardPanel,PopupCard,BarIconButton,PluginBarApi}.qml`,
`/usr/share/omarchy/shell/README.md:46-215`.

### manifest.json

- `schemaVersion` must be `1`.
- Required: `id`, `name`, `version`, `kinds`, `entryPoints`.
- `kinds`: `["service", "bar-widget"]`. This plugin is both: a headless
  singleton that owns audio, and a bar icon that opens the pad panel.
- `entryPoints`: `{ "service": "Service.qml", "barWidget": "Panel.qml" }`.
- `barWidget.defaultSection` must be one of **`left` | `center` | `right`**
  (PluginRegistry.qml:75). Use `right`.
- `barWidget.defaults` + `barWidget.schema` drive the Settings → Plugins form.
  Schema types in use: `string`, `integer`, `enum`, `boolean`, `path`
  (`{key,type,label,defaultValue,description,min,max,step,options}`).
- Top-level `keepLoaded: true` so the service survives hide/unload.
- The plugin dir name must equal the id. No `/`, no `..`, must not start with
  `omarchy.` (reserved).

### Injected properties

Every entry point receives, **if it declares them**: `omarchyPath`, `shell`
(capability facade: `serviceFor`, `summon/hide/toggle`, `updateEntryInline`,
`mutateShellConfig`), `manifest`. Bar widgets additionally get `bar`,
`moduleName`, `settings`.

### Root components

- **Service** (`Service.qml`): non-visual `QtObject`. Instantiated **once**
  (`shell.qml:904-954`), survives hot-reload with a refreshed `shell`.
  Reach it from the widget with `shell.serviceFor("yami.soundboard")`.
- **Bar widget** (`Panel.qml`): extend `qs.Ui` `Panel` (NOT bare `Item`) —
  that base already owns `opened`, `open()`, `close()`, `toggle()`,
  `ipcTarget`, and an `IpcHandler` with `open/close/show/hide/toggle`.
  Working reference: `~/.config/omarchy/plugins/stappmus.activity-monitor/Panel.qml`
  (`moduleName` + `ipcTarget` + `BarIconButton` + `KeyboardPanel`). Copy its structure.

```qml
Panel {
  moduleName: "yami.soundboard"
  ipcTarget: "yami.soundboard"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton { id: button; anchors.fill: parent; bar: root.bar
                  text: "…"; tooltipText: "Soundboard"
                  onPressed: function(b) { if (b === Qt.LeftButton) root.toggle() } }

  KeyboardPanel { anchorItem: button; owner: root; bar: root.bar
                  open: root.opened
                  contentWidth: fittedContentWidth(…)
                  contentHeight: fittedContentHeight(…) }
}
```

- **Add IPC methods for the hotkeys.** `Panel`'s base `IpcHandler` only has
  open/close. Declare a second handler with a separate target so scripts and
  Hyprland binds can drive playback:
  `IpcHandler { target: "soundboard"; function play(n:int); function stopAll(); function stop(n:int) }`
  → callable as `omarchy-shell soundboard play 3`. Verify it registers; if a
  second target inside the widget is rejected by the shell, move the handler
  into `Service.qml` and confirm `IpcHandler` works from a non-visual service
  (test it early — it is the hotkey path and must not be guessed).

### Settings read/write

- Read: `setting("key", fallback)` (base class).
- Write: merge into a full entry and push it:
  ```qml
  var entry = { id: moduleName }; var cur = root.settings || ({})
  for (var k in cur) if (k !== "id") entry[k] = cur[k]
  for (var k2 in values) entry[k2] = values[k2]
  root.settings = entry
  bar.shell.updateEntryInline(moduleName, entry)
  ```
  Reference: activity-monitor `Panel.qml:242-258`.

### Subprocess (Quickshell.Io)

- `Process { command: ["pw-play", "--target=soundboard.mix", file] }` — **argv
  array, never a shell string.** Use `["bash","-lc", …]` when you need a shell.
- `onExited: function(code) { … }`; `running = false` sends SIGTERM (that is how
  a pad is stopped). `stdout: StdioCollector { waitForEnd: true }` for one-shots,
  `SplitParser` for streaming.
- Fire-and-forget: `Quickshell.execDetached([...])`.

### Hot reload / validation

- Saving any file under the plugin dir hot-reloads it (~1 s). Force:
  `omarchy-shell shell rescanPlugins`.
- Validate manifest: `omarchy plugin validate ~/.config/omarchy/plugins/yami.soundboard`.
- QML errors: `journalctl -t omarchy-shell -n 80 --no-pager`.
- Enable in the bar: `omarchy plugin enable yami.soundboard --section right`
  (or add `yami.soundboard` to `~/.config/omarchy/shell.json` bar layout).
  A bar widget is enabled exactly when its id appears in the bar layout.

---

## 4. File layout & write ownership

Two lanes build in parallel. **Do not write files outside your lane.**

| File | Owner | Purpose |
| --- | --- | --- |
| `manifest.json` | fixer | schema, kinds, defaults, settings schema |
| `Service.qml` | fixer | library model, playback, audio lifecycle, state |
| `scripts/soundboard-audio` | fixer | `setup`/`teardown`/`status`/`refresh-mic` (bash, tested standalone) |
| `scripts/install-binds` | fixer | append the marked hotkey block to `~/.config/hypr/bindings.lua` |
| `scripts/soundboard` | fixer | thin CLI: `play N`, `stop N`, `stopall`, `status` → IPC |
| `README.md` | fixer | install, first-run, troubleshooting |
| `Panel.qml` | designer | bar icon + `KeyboardPanel` + layout/navigation |
| `PadGrid.qml` | designer | the pad grid |
| `Pad.qml` | designer | one pad tile (idle / playing / missing / hover) |
| `SettingsDrawer.qml` | designer | import, volume, mic picker, monitor toggle, hotkey list |
| `library.json` | runtime | `~/.local/share/yami.soundboard/library.json` |

Designer owns all visuals. Fixer owns no visual file. If the service must
change shape, fixer updates `Service.qml` and tells the lead — **the API in
section 5 is the contract**.

---

## 5. Service API (contract between Service.qml and the UI)

```qml
// ---- state (all NOTIFYable) ----
property bool   ready            // service initialised
property bool   audioReady       // virtual devices up and verified
property string audioStatus      // "ready" | "starting" | "error" | "off"
property string lastError        // human-readable, "" when fine
property var    pads             // [{ id, name, path, volume, slot, missing }]
property var    playing          // { padId: playerIndex } — drives the glow
property int    activeCount      // number of sounds currently audible
property real   masterVolume     // 0..1 per-pad stream gain; the sink stays 100%
property bool   monitorLocally   // mirror pads to the system default sink
property string micSource        // "" = auto, else pinned node name
property var    micCandidates    // [{ nodeName, description, available }]

// ---- playback ----
function play(index)             // overlapping; same pad retrigger restarts it
function stop(index)             // SIGTERM that pad's player(s) incl. monitor copy
function stopAll()
function isPlaying(index) -> bool

// ---- library ----
function addFiles(paths)         // append, auto-name from filename, dedupe by path
function removePad(index)
function movePad(from, to)
function renamePad(index, name)
function setPadVolume(index, v)  // 0..1, persisted
function reload()                // re-read library.json

// ---- audio device ----
function refreshAudio()          // idempotent setup + re-point mic loopback
function setMonitorLocally(bool)
function setMasterVolume(v)      // applies to soundboard.mix sink volume
function setMicSource(nodeName)  // "" = auto
```

Rules:
- `play()` must work with `audioReady === false` by calling `refreshAudio()`
  first, then playing. If that fails, set `lastError` and stay silent rather
  than dropping the request silently.
- Pad volume 0 means effectively muted but still "playing" (UI consistency).
- Every mutation persists `library.json` atomically (write temp + rename) and
  updates `pads`.
- Library entries whose file disappeared load with `missing: true`, stay
  visible, and are skipped on play. Never auto-delete a user's pad.

`library.json` shape:

```json
{ "version": 1, "masterVolume": 1.0, "monitorLocally": true, "micSource": "",
  "pads": [ { "id": "p1", "name": "Airhorn", "path": "/abs/file.mp3",
              "volume": 1.0, "slot": 1 } ] }
```

Slots 1..12 are fixed hotkey slots, assigned in pad order. A pad shows the key
binding for its slot so the hotkey is discoverable on the tile itself.

---

## 6. Hotkeys (Hyprland keybinds → IPC)

Quickshell exposes `hyprland_global_shortcuts_manager_v1` on this Hyprland, but
Omarchy's own convention (and the robust path) is a Hyprland binding that calls
the shell's IPC. Use that.

`~/.config/hypr/bindings.lua` — `o.bind(keys, description, dispatcher)` where a
string dispatcher becomes `hl.dsp.exec_cmd` (`default/hypr/helpers.lua:92-106`):

```lua
-- >>> yami.soundboard >>>
o.bind("ALT + 1", "Soundboard pad 1", "omarchy-shell -q soundboard play 1")
...
o.bind("ALT + Q", "Soundboard pad 10", "omarchy-shell -q soundboard play 10")
o.bind("ALT + W", "Soundboard pad 11", "omarchy-shell -q soundboard play 11")
o.bind("ALT + E", "Soundboard pad 12", "omarchy-shell -q soundboard play 12")
-- <<< yami.soundboard <<<
```

12 slots: `ALT + 1..9`, then `ALT + Q`, `ALT + W`, `ALT + E`.
`install-binds` must be idempotent (replace an existing marked block, never
duplicate) and must not touch any other line. After editing, the caller runs
`hyprctl reload` and checks `hyprctl configerrors`.

---

## 7. Definition of done

1. `omarchy plugin validate` passes on the plugin dir.
2. No QML errors in `journalctl -t omarchy-shell` after a reload.
3. `soundboard.mic` appears in `pactl list short sources` while the plugin is
   enabled, and disappears when it is disabled/removed.
4. `omarchy-shell soundboard play 1` from a terminal audibly reaches
   `soundboard.mic` (verified by recording it with `pw-record` and measuring
   peak with ffmpeg volumedetect — the technique used in section 2).
5. `ALT + 1` while another window has focus triggers that pad.
6. Two pads overlap; `stopAll` silences both; a finished pad clears its glow.
7. `pactl get-default-source` and `pactl get-default-sink` are **unchanged**
   from the values in section 1 after all tests.
8. Re-enabling the plugin does not stack duplicate modules.

### Verification record (2026-10-25)

All eight items above verified on this machine, plus:

- Independent verifier `~/Work/soundboard-verify.sh`: 17 pass, 0 fail, 1 skip
  (the skip is only the journal heuristic; 35 `soundboard` journal lines were
  inspected separately with zero `error`/`failed`/`ReferenceError` hits).
- DoD 4: tone read back from `soundboard.mic` with `parec`, peak **−21.1 dB**.
- DoD 5: real physical `ALT + 1` press captured on `soundboard.mic` at
  **−21.1 dB**, 4.0 s — synthetic key injection cannot reach Hyprland binds
  (`wtype` uses the virtual-keyboard protocol, which Hyprland ignores); the
  payload was additionally proven through Hyprland's own dispatcher with
  `hyprctl dispatch 'hl.dsp.exec_cmd("omarchy-shell -q soundboard play 1")'`.
  `hyprctl dispatch __lua N` is the wrong CLI form for Lua binds.
- Panel click on pad 1 captured separately at **−21.1 dB**, 4.0 s, 4 s after
  the hotkey event (both paths reach the virtual mic).
- Final state: 3 PulseAudio modules (sink, loopback, remap), 12 binds,
  `hyprctl configerrors` clean, defaults `omavoice` /
  `alsa_output.pci-0000_09_00.4.analog-stereo` unchanged, library reset to
  empty pads.
- Remaining manual, by design: adding sounds via the portal picker and folder
  import (needs a human in a file dialog), and mixing against a live call app.
