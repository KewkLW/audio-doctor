---
name: audio-doctor
description: Diagnose "no sound" / audio problems on this machine fast. Run `audio-doctor` FIRST for any "I don't hear X", "no audio", "sound stopped", "YT is silent", headphones/RME/interface silent, wrong output, crackle-free-but-silent, or after touching PipeWire/WirePlumber config. It meters real signal at every hop (app stream -> sink -> loopback -> hardware sink -> RME ADI-2 device state) and names the first broken hop in ~2 s.
---

# audio-doctor

`audio-doctor` (~/.local/bin, repo ~/build/audio-doctor) walks the chain and prints `VERDICT:` first.

```
audio-doctor              # always start here (~2 s, passive, no sound made)
audio-doctor --app youtube   # one app's streams only (matches app or tab/media name)
audio-doctor --tone       # ALSO plays a quiet -30 dBFS 440 Hz tone into the default sink; tell the user first
audio-doctor --json       # for scripting
audio-doctor --fix        # relink streams/loopbacks whose target is back but unlinked, then diagnose
audio-doctor --audit      # config audit only (= `config-audit`)
```

## config-audit: catch config traps before they break audio
`config-audit` (same repo, in ~/.local/bin, folded into every audio-doctor run as hop `config`) reads every PipeWire/WirePlumber drop-in (/usr/share, /etc, ~/.config) via `spa-json-dump` and compares it with the running graph. Run it after ANY PipeWire/WirePlumber config change, and as part of Omarchy Studio setup checks.
| check | flags | why it matters |
|---|---|---|
| parse | a drop-in that does not parse | PipeWire may skip it or fail to start |
| reconnect | `target.object` + `node.dont-reconnect` | after the target drops once (power cycle, replug) WirePlumber never relinks (2026-11-17 RME incident). Use `node.dont-fallback` + `node.linger` |
| fallback | `node.dont-fallback` without `node.linger` | WirePlumber destroys the node while its target is missing |
| target | target node missing right now, with the reason (device absent / card on wrong profile) | |
| profile | target is a `pro-output/pro-input` node but no rule pins the card to pro-audio | only remembered state keeps it |
| drift | disk config differs from the running node; WARN if the running node still has the reconnect trap | restart pending |
| live | a stream with a present target and no links | `--fix` relinks by channel |
| dupes / legacy | same node.name in two files; WirePlumber 0.4 `*.lua.d` dirs | |
Verify a new loopback flag set without restarting PipeWire: `pw-loopback` against a `pactl load-module module-null-sink`, then unload/reload the sink (present -> gone -> back, cold start, capture direction).

## omarchy-audio-audit: baseline, first install, power checks
`omarchy-audio-audit` (same repo, in ~/.local/bin) measures how fit the machine is for realtime audio. Run it on a first install (`--first-run`), before/after any tuning change, and when troubleshooting crackles or latency.
```
omarchy-audio-audit               # ~12 min: idle + synthetic stress; ONE sudo (ntfy) for cyclictest/rtla/turbostat/lspci
omarchy-audio-audit --quick --no-root --loads idle   # ~1.5 min smoke test, no sudo
omarchy-audio-audit --daw 60      # a DAW is connected: xruns at the CURRENT buffer, never changes it
omarchy-audio-audit --disk-path /path/to/samples     # disk wake test on the sample library's drive
```
- Per load: latency probes (P/E split), buffer sweep (interface vs client xruns, valid only if the driver ran at that size), context (temp, throttling, top CPU).
- **Power settings, always:** sleep/idle, USB autosuspend per interface + hubs + controller, governor/EPP/turbo, C-states, PCIe ASPM (per link with root), PCI runtime PM, NVIDIA, HDA, PipeWire suspend, NVMe APST, write-back, Wi-Fi, EEE, NMI watchdog, power tuners; verdict keep / session / measure / change. Plus a **disk wake test** (cold vs warm 4 KiB reads).
- Safety: restores force-quantum/force-rate exactly; refuses the sweep while any DAW is connected (JACK **or** native PipeWire backend: a buffer change kills Bitwig's engine); skips it when routing is broken; never restarts PipeWire.
- Output: `~/.local/state/omarchy-studio/audit/<time>/` (`audit.json`, `report.html`, `raw/`), `watch_seed` for the future watcher.
- Helpers in `audit/`: `footprint NAME` / `footprint compare A B` (memory/CPU before vs after, e.g. DAW loaded), `quiet-park park|unpark|status` (freeze background stuff for a test), `quiet-report`, `boot-inventory OUT.html` (everything that starts at boot).

## Keep the interface awake: studio-keepalive (ALWAYS for unattended runs)
The RME ADI-2 has **auto-standby**: after a quiet stretch it powers down and **drops off USB** (kernel: `usb 1-2: USB disconnect`, no reconnect). Audio is then gone until someone presses its button or uses its remote; the host can't wake it (a USB port power-cycle doesn't either).
```
studio-keepalive on        # saves device.auto_standby and sets it off (refuses if the RME is asleep/off USB)
studio-keepalive off       # restores the saved value (also after a crashed run)
studio-keepalive status
```
- Run `on` **before** a DAW starts and `off` **after** it quits: Bitwig holds the ADI-2's MIDI port, and `adi2` can't reach the device while it does.
- `audit/m2-bisect.sh` and `omarchy-audio-audit` already do this; any new long or unattended test must too (refuse to run if `on` fails).
- Permanent choice is the user's: `adi2 set device.auto_standby off|30min|1h|2h|4h`.

## Test and tuning tools (audit/)
| tool | what it does |
|---|---|
| `daw-ramp` | Bitwig dropout ramp/bisect through BitwigBridge (opens chunk projects, activates groups, proves play, counts xruns per sample). `m2-bisect.sh` wraps it unattended (mute, keepalive, silent launch, restore). |
| `power-ab OUT USER TORCH_PYTHON` | root, once: runtime-only A/B of NMI watchdog, GPU lock under load, NVMe APST, ASPM; originals saved, reverted, read back |
| `studio-power-apply OUT USER SERIAL[=LABEL]...` | root, once: NVMe APST cap per audio drive (udev by serial, gated) + `studio-gpu-lock` service |
| `omarchy-audio-watch` | always-on 30 s monitor (GPU/CPU/NVMe/xruns/Xid, activity-tagged) + `report OUT.html`; `event "text"` marks changes |
| `footprint NAME` / `compare A B` | memory/CPU/threads before vs after (e.g. DAW loaded) |
| `quiet-park park|unpark` | freeze background services for a clean test (never auto-unpark) |
| `boot-inventory OUT.html` | everything that starts at boot, grouped, with recommendations |

## whatis: which app is that process really?
`whatis` (same repo, symlinked into ~/.local/bin) names the real app behind generic process names. audio-doctor imports it to label every stream owner and app.
```
whatis 698290        # one pid      -> Battle.net (wine), prefix, Proton, SteamAppId
whatis discord       # by comm / real name / window class or title
whatis --gui         # every window
whatis --audio       # every window app + every PipeWire client
whatis --json ...    # for scripting
```
Runtimes: native, chromium-webapp (`--app=` URL), electron (app.asar), wine-proton (WINEPREFIX / STEAM_COMPAT_DATA_PATH / default ~/.wine, PROTONPATH, SteamAppId -> appmanifest), appimage (APPIMAGE env, or the AppRun + .desktop AppDir layout when env was reset), flatpak, interpreter-script. Tauri/WebKitGTK apps show as native with a "WebKitGTK webview" evidence line, named from the window title.
- Stream owners: helper pids resolve to the windowed app (chromium/electron children, Wine siblings in the same prefix); a terminal window is a boundary, so mpv started from a shell is "mpv", not "Foot".
- `launcher scope` is only where the app was started from, never the app's boundary: an app opened from a URI handler sits in the browser's old scope, an installer started by an agent sits in that agent's terminal scope. The `note:` line says which.
- `agent_session`: the CLAUDE_CODE_SESSION_ID in the process env, i.e. the Claude session that launched it. Read that session's JSONL under ~/.claude/projects/.
- `pipewire client`: this pid, a descendant (not for terminals: their children are other apps), or (for Wine) a sibling in the same prefix holds a PipeWire Client (matched on `application.process.id`; `pipewire.sec.pid` is pipewire-pulse for pulse clients).
- `audio evidence`: libpulse / libpipewire / libjack / libopenal / libportaudio / winepulse / winealsa mapped anywhere in the process tree. libasound alone does NOT count (Electron links it without playing).
- `stale` = started before pipewire-pulse's ActiveEnterTimestamp (wall clock) AND no PipeWire client. audio-doctor only reports stale apps that also have audio evidence, as one line:
  `opened before the PipeWire restart (17:02), no audio connection: Discord (web app), Battle.net (wine)`.
  Terminals and similar stale-but-silent windows are left out.

## Reading it
- Severity: BREAK (audio stops here) > WARN > INFO. The first BREAK is the answer.
- `level` is MEASURED peak, not a setting. SILENT = below -90 dBFS.
- Signal path on this box: app stream -> `rme_phones` (virtual stereo sink "RME Phones 1/2") -> loopback `rme_phones.out` -> ADI-2 Pro pro-output AUX0/AUX1 -> Phones 1/2.

## Known failure -> fix
| Symptom in report | Cause | Fix |
|---|---|---|
| stream connected but SILENT + "started BEFORE the last PipeWire restart" | app's audio engine went stale when PipeWire restarted (2026-11-16 YT incident) | The user fully quits + reopens the app. Never kill the user's daily browser yourself |
| "opened before the PipeWire restart ..., no audio connection: X, Y" | same: those apps lost their PipeWire connection in the restart | The user fully quits + reopens each one they want sound from |
| sink MUTED / volume <=2% | mixer | `pactl set-sink-mute <sink> 0` |
| virtual sink not linked to any hardware sink / `[BREAK] routing ... not linked although its target is present` | device power-cycled and the loopback did not relink (`node.dont-reconnect` trap, 2026-11-17) | `audio-doctor --fix` (pw-link by channel, no restart). Permanent: config uses `node.dont-fallback` + `node.linger` (adi2-control `config/`) |
| virtual sink not linked, target missing | RME off/unplugged/renamed, or card not on pro-audio | power on/replug; `config-audit` names which; check target.object and the pro-audio rule |
| signal at sink but not at hardware sink | loopback links broken | `pw-link rme_phones.out:output_AUX0 <hw>:playback_AUX0` (and AUX1) |
| ADI-2 MUTED / DIM / source not USB | device state | `adi2 set line.mute off` etc. |
| ADI-2 volume <= -70 dB | knob turned down | tell the user; never raise volume yourself |
| tone reaches hardware sink, still silent | device/cable/phones side | check `adi2 dump`, phones jack, cable |
| stream plays to a non-default sink | per-app routing stuck | `pactl move-sink-input <idx> rme_phones` |
| browser/system audio silent right after starting Bitwig | Bitwig (PipeWire backend) re-creates the RME nodes; old loopback flags don't relink | `audio-doctor --fix`; permanent once the new flags are live (PipeWire start) |
| RME gone: `lsusb` has no `2a39:`, kernel shows `usb 1-2: USB disconnect` with no reconnect | **RME auto-standby** (or powered off) | press its button / remote (the host can't wake it); for test runs use `studio-keepalive`; it relinks by itself on wake |
| RME nodes present but **no ports** (`pw-link -i` has no `RME_ADI...playback_AUX`), loopbacks unlinked, `--fix` can't link, Bitwig engine hangs after "Opening MIDI device" | WirePlumber wedged on the device after a USB reset/re-enumeration (2026-11-17 12:38) | `systemctl --user restart wireplumber` (apps keep their connections; NOT a PipeWire restart), then quit/relaunch the DAW |
| graph stuck at a forced quantum, stray `pw-play` reading stdin | `omarchy-studio-bitwig` wrapper's warm-up player hung with no sink | kill the wrapper + its pw-play by PID with SIGKILL (its EXIT trap changes the buffer), then `pw-metadata -n settings 0 clock.force-quantum 1024` and `0` |

## Rules
- Avoid restarting PipeWire while the user has apps open: it is what stales their audio. If you must, run `whatis --audio` first and tell the user which apps to reopen.
- Never raise device or sink volume without asking (ears, speakers).
- GUI view: `qpwgraph` (launch, then move silently to their workspace with
  `hyprctl dispatch 'hl.dsp.window.move({ workspace = N, follow = false, window = "pid:PID" })'`).
