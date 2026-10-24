# Soundboard (yami.soundboard)

Pads in the Omarchy bar, hotkeys that work while Discord/Zoom has focus, and
one **Soundboard-Mic** the conferencing app selects — so the far end hears
*your voice + the sounds* on a single input device.

```
 mic / omavoice ───►(module-loopback)──┐
                                       ▼
 pads (pw-play) ──► soundboard.mix ──►(module-remap-source)──► soundboard.mic
                              ("Soundboard-Mix")                    ("Soundboard-Mic")
```

The system default source and default sink are never touched. You opt the
conferencing app in by picking **Soundboard-Mic** as its microphone.

## Requirements

- Omarchy with shell plugins (`omarchy plugin validate` present) and Hyprland
- PipeWire + WirePlumber (`pw-play`, `pactl`)
- `omarchy-file-select` — the portal file chooser, ships with Omarchy
- `ffmpeg` only for containers `pw-play` cannot decode (m4a/opus/webm); wav,
  mp3, flac and ogg play natively

## Install

```sh
omarchy plugin add https://github.com/ren7aro/omarchy-soundboard --enable
```

That clones the repo to `~/.config/omarchy/plugins/yami.soundboard` (the folder
name must equal the manifest `id` — that is what the shell loads), validates the
manifest, rescans plugins and drops the pad icon into the right bar section.
Pass `--enable` (or later `omarchy plugin enable yami.soundboard right`) if you
want the widget placed for you.

The hotkeys are ordinary Hyprland binds, so they are a separate idempotent step.
Run it once after installing (it only rewrites its own marked block in
`~/.config/hypr/bindings.lua`):

```sh
~/.config/omarchy/plugins/yami.soundboard/scripts/install-binds
hyprctl reload && hyprctl configerrors   # nothing printed = clean
```

Update a checked-out install with:

```sh
omarchy plugin update yami.soundboard
```

Uninstall:

```sh
~/.config/omarchy/plugins/yami.soundboard/scripts/install-binds --remove
omarchy plugin remove yami.soundboard
```

Removing the plugin unloads the virtual devices it created; your pad library
stays in `~/.local/share/yami.soundboard/`.

## Development

Edit in place: `omarchy plugin validate ~/.config/omarchy/plugins/yami.soundboard`
checks the manifest, and `omarchy-shell shell rescanPlugins` forces a reload.
QML errors surface in `journalctl -t omarchy-shell`. Note that this shell build
does **not** hot-reload QML — `omarchy restart shell` (then wait ~10 s) is what
actually applies changes to `Service.qml`/`Panel.qml`.

## Hotkeys

Install the 12 fixed slots as Hyprland bindings (idempotent; it replaces only
the marked `yami.soundboard` block in `bindings.lua`):

```sh
~/.config/omarchy/plugins/yami.soundboard/scripts/install-binds
hyprctl reload && hyprctl configerrors   # then confirm no errors printed
```

| Keys | Pad | | Keys | Pad |
| --- | --- | --- | --- | --- |
| ALT + 1..9 | pads 1–9 | | ALT + W | pad 11 |
| ALT + Q | pad 10 | | ALT + E | pad 12 |

Slots map to the pad order in the panel; a pad tile shows its own key.

Test the IPC path directly (what the binds call):

```sh
~/.config/omarchy/plugins/yami.soundboard/scripts/soundboard play 1
```

`soundboard` understands `play N`, `stop N`, `stopall` and `status` (JSON).
Add `-q` first (`soundboard -q …`) to suppress output — exactly what the
generated binds call.

## First run

1. Enable the plugin. It creates `soundboard.mix`, replays it as
   **Soundboard-Mic**, and feeds your voice (prefer `omavoice`, which is the
   denoise path, then your default mic, then first hardware mic) into the mix.
2. Open Discord/Zoom and set **microphone = "Soundboard-Mic"**. The panel
   pads play into that mic; your plain speakers can still hear your voice
   via your normal input.
3. Load a few pads from the panel's settings drawer (wav/mp3/flac/ogg play
   natively; m4a/opus/webm go through ffmpeg, which must be installed).
4. `Master volume` scales the mix; `monitorLocally` (default on) also plays
   pads through your normal default sink so you hear them too.

## Widget settings

- `masterVolume` — 0..1, applied to the `soundboard.mix` sink volume.
- `monitorLocally` — mirrored playback on the system default sink.
- `micSource` — empty string = auto (`omavoice` → default → first hardware);
  or pin an explicit PipeWire source node name.

## Troubleshooting

**My voice or the pads echo through the Soundboard-Mic.** With
`monitorLocally` on and the user on open speakers (not headphones), the
microphone re-captures the pad playback. Turn `monitorLocally` off in the
panel settings during calls, or use headphones. The settings drawer shows
this warning once.

**`soundboard.mic` missing from `pactl list short sources`.** Run
`~/.config/omarchy/plugins/yami.soundboard/scripts/soundboard-audio status`
— it prints which of the three modules exist. Then
`…/soundboard-audio setup` to recreate them. `refresh-mic` re-resolves the
input node without touching the rest.

**Module leftovers / duplicated "Soundboard" nodes.** The plugin persists
module ids in `~/.local/share/yami.soundboard/modules.json` and shutdown
unloads exactly those; modules you loaded manually are not auto-removed.
Fix by hand:

```sh
pactl list modules | grep soundboard   # note each "Module #<id>"
pactl unload-module <id>               # only the ones you mean
```

Stray players (shell killed mid-pad) can be killed narrowly:
`pkill -f "pw-play --target=soundboard.mix"` — never a broader sweep.

**Hotkeys run but nothing plays.** Check `omarchy-shell soundboard status`
answers; make sure the plugin is enabled and
`journalctl -t omarchy-shell -n 40 --no-pager` shows no `Service.qml` load
errors. A pad whose file is missing is skipped and reports it via the
service (`lastError`).
