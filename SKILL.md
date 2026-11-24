---
name: audio-doctor
description: Diagnose "no sound" / audio problems on this machine fast. Run `audio-doctor` FIRST for any "I don't hear X", "no audio", "sound stopped", "YT is silent", headphones/interface silent, wrong output, crackle-free-but-silent, or after touching PipeWire/WirePlumber config. It meters real signal at every hop (app stream -> sink -> loopback -> hardware sink -> optional RME ADI-2 device state) and names the first broken hop in ~3 s.
---

# audio-doctor

`audio-doctor` (installed in `~/.local/bin`) walks the PipeWire audio chain and prints `VERDICT:` first.

```
audio-doctor                 # always start here (~3 s, passive, no sound made)
audio-doctor --app youtube   # one app's streams only (matches app or tab/media name)
audio-doctor --tone          # ALSO plays a quiet -30 dBFS 440 Hz tone into the default sink; tell the user first
audio-doctor --json          # machine-readable JSON
audio-doctor --fix           # relink streams/loopbacks whose target is back but unlinked, then diagnose
audio-doctor --audit         # config audit only (= `config-audit`)
audio-doctor --help          # usage without running a check
```

## config-audit: catch config traps before they break audio

`config-audit` (folded into every `audio-doctor` run as hop `config`) reads every PipeWire/WirePlumber drop-in (`/usr/share`, `/etc`, `~/.config`) via `spa-json-dump` and compares it with the running graph. Run it after ANY PipeWire/WirePlumber config change.

| check | flags | why it matters |
|---|---|---|
| parse | a drop-in that does not parse | PipeWire may skip it or fail to start |
| reconnect | `target.object` + `node.dont-reconnect` | after the target drops once (power cycle, replug) WirePlumber never relinks. Use `node.dont-fallback` + `node.linger` |
| fallback | `node.dont-fallback` without `node.linger` | WirePlumber destroys the node while its target is missing |
| target | target node missing right now, with the reason (device absent / card on wrong profile) | |
| profile | target is a `pro-output/pro-input` node but no rule pins the card to pro-audio | only remembered state keeps it |
| drift | disk config differs from the running node; WARN if the running node still has the reconnect trap | restart pending |
| live | a stream with a present target and no links | `--fix` relinks by channel |
| dupes / legacy | same `node.name` in two files; WirePlumber 0.4 `*.lua.d` dirs | |

Verify a new loopback flag set without restarting PipeWire: `pw-loopback` against a `pactl load-module module-null-sink`, then unload/reload the sink (present -> gone -> back, cold start, capture direction).

## omarchy-audio-audit: baseline, first install, power checks

`omarchy-audio-audit` measures how fit the machine is for realtime audio. Run it on a first install (`--first-run`), before/after any tuning change, and when troubleshooting crackles or latency.

```
omarchy-audio-audit                                  # ~12 min: idle + synthetic stress; ONE sudo prompt for root probes
omarchy-audio-audit --quick                          # ~4 min smoke test
omarchy-audio-audit --quick --no-root --loads idle   # ~1.5 min smoke test, no sudo
omarchy-audio-audit --daw 60                         # a DAW is connected: xruns at the CURRENT buffer, never changes it
omarchy-audio-audit --disk-path /path/to/samples     # disk wake test on the sample library's drive
omarchy-audio-audit --help                           # usage without starting a run
```

- Per load: latency probes (P/E split on hybrid CPUs), buffer sweep (interface vs client xruns, valid only if the driver ran at that size), context (temp, throttling, top CPU).
- **Power settings, always:** sleep/idle, USB autosuspend per interface + hubs + controller, governor/EPP/turbo, C-states, PCIe ASPM (per link with root), PCI runtime PM, NVIDIA, HDA, PipeWire suspend, NVMe APST, write-back, Wi-Fi, EEE, NMI watchdog, power tuners; verdict keep / session / measure / change. Plus a **disk wake test** (cold vs warm 4 KiB reads).
- Safety: restores `clock.force-quantum` / `clock.force-rate` exactly; refuses the sweep while any DAW is connected (JACK **or** native PipeWire backend); skips it when routing is broken; never restarts PipeWire.
- Output: `~/.local/state/omarchy-studio/audit/<time>/` (`audit.json`, `report.html`, `raw/`), plus `watch_seed`.

## omarchy-audio-watch and footprint

- `omarchy-audio-watch`: 30 s background monitor (CPU temp/throttling, NVMe temps, PipeWire hardware/DAW xruns, NVIDIA GPU metrics if present) with `omarchy-audio-watch report OUT.html` and `omarchy-audio-watch event "text"`.
- `footprint NAME [--secs 30]` / `footprint compare A B`: CPU, memory, threads and PipeWire graph snapshots for before/after comparisons.

## Optional RME ADI-2 Pro module: studio-keepalive

Only active when an RME ADI-2 Pro (`2a39:3fd2`) is on USB. The ADI-2 has auto-standby: after a quiet stretch it powers down and drops off USB until someone presses its button or remote (the host cannot wake it).

```
studio-keepalive on        # starts a read-only MIDI status pulse every 60 s, never changes a device setting (no RME on USB: "module off", exit 0)
studio-keepalive off       # stops the pulse; nothing to restore (a killed or crashed pulse just stops, the device timer runs again)
studio-keepalive status
```

- While a DAW (such as Bitwig) holds the ADI-2's MIDI port raw, the pulse cannot reach the device: `on` refuses (exit 1) and `status` says so (exit 1). The pulse also ends by itself after 8 h (`KEEPALIVE_MAX_HOURS`).
- The keepalive never writes `device.auto_standby`: that stays the user's choice (`adi2 set device.auto_standby off|30min|1h|2h|4h`).

## whatis: which app is that process really?

`whatis` names the real app behind generic process names. `audio-doctor` imports it to label every stream owner and app.

```
whatis PID            # one pid -> real app, runtime, Wine/Proton prefix, SteamAppId
whatis discord        # by comm / real name / window class or title
whatis --gui          # every window
whatis --audio        # every window app + every PipeWire client
whatis --json ...     # machine-readable JSON
```

Runtimes: native, chromium-webapp (`--app=` URL), electron (`app.asar`), wine-proton (`WINEPREFIX` / `STEAM_COMPAT_DATA_PATH` / default `~/.wine`, `PROTONPATH`, `SteamAppId`), appimage, flatpak, interpreter-script.

- `stale` = started before `pipewire-pulse`'s `ActiveEnterTimestamp` AND no PipeWire client. `audio-doctor` only reports stale apps that also show audio library evidence.

## Reading it

- Severity: `BREAK` (audio stops here) > `WARN` > `INFO`. The first `BREAK` is the answer.
- `level` is MEASURED peak, not a setting. `SILENT` = below -90 dBFS.

## Known failure -> fix

| Symptom in report | Cause | Fix |
|---|---|---|
| stream connected but SILENT + "started BEFORE the last PipeWire restart" | app's audio engine went stale when PipeWire restarted | The user fully quits + reopens the app. Never kill the user's browser yourself |
| "opened before the PipeWire restart ..., no audio connection: X, Y" | same: those apps lost their PipeWire connection in the restart | The user fully quits + reopens each one they want sound from |
| sink MUTED / volume <=2% | mixer | `pactl set-sink-mute <sink> 0` (ask before raising volume) |
| virtual sink not linked to any hardware sink / `[BREAK] routing ... not linked although its target is present` | device power-cycled and loopback did not relink (`node.dont-reconnect` trap) | `audio-doctor --fix` (pw-link by channel, no restart). Permanent: replace `node.dont-reconnect` with `node.dont-fallback` + `node.linger` |
| virtual sink not linked, target missing | device off/unplugged/renamed, or card on wrong profile | power on/replug; `config-audit` names which; check `target.object` and profile rule |
| signal at sink but not at hardware sink | loopback links broken | `audio-doctor --fix`, or inspect links in `qpwgraph` |
| ADI-2 MUTED / DIM / source not USB | device state | `adi2 set line.mute off` etc. |
| ADI-2 volume <= -70 dB | knob turned down | tell the user; never raise volume yourself |
| tone reaches hardware sink, still silent | device/cable/headphones side | check hardware output, cable, headphones jack |
| stream plays to a non-default sink | per-app routing stuck | `pactl move-sink-input <idx> <default-sink>` |
| USB interface nodes present but **no ports**, loopbacks unlinked, `--fix` cannot link | WirePlumber wedged on the device after a USB reset/re-enumeration | `systemctl --user restart wireplumber` (apps keep their connections; NOT a PipeWire restart), then relaunch the DAW |

## Rules

- Never restart PipeWire or `pipewire-pulse` while the user has apps open: it stales their audio. If a restart is unavoidable, run `whatis --audio` first and tell the user which apps to reopen.
- Never raise device or sink volume without asking (ears, speakers).
- Never send write, erase, or unknown vendor USB commands to an audio interface.
