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
```

## Reading it
- Severity: BREAK (audio stops here) > WARN > INFO. The first BREAK is the answer.
- `level` is MEASURED peak, not a setting. SILENT = below -90 dBFS.
- Signal path on this box: app stream -> `rme_phones` (virtual stereo sink "RME Phones 1/2") -> loopback `rme_phones.out` -> ADI-2 Pro pro-output AUX0/AUX1 -> Phones 1/2.

## Known failure -> fix
| Symptom in report | Cause | Fix |
|---|---|---|
| stream connected but SILENT + "started BEFORE the last PipeWire restart" | app's audio engine went stale when PipeWire restarted (2026-11-16 YT incident) | The user fully quits + reopens the app. Never kill the user's daily browser yourself |
| app running, NO audio stream, stale | same | same |
| sink MUTED / volume <=2% | mixer | `pactl set-sink-mute <sink> 0` |
| virtual sink not linked to any hardware sink | RME unplugged/renamed, loopback target gone | replug; check `~/.config/pipewire/pipewire.conf.d/50-rme-adi2-stereo.conf` target.object; `systemctl --user restart pipewire` (warn: stales open apps!) |
| signal at sink but not at hardware sink | loopback links broken | `pw-link rme_phones.out:output_AUX0 <hw>:playback_AUX0` (and AUX1) |
| ADI-2 MUTED / DIM / source not USB | device state | `adi2 set line.mute off` etc. |
| ADI-2 volume <= -70 dB | knob turned down | tell the user; never raise volume yourself |
| tone reaches hardware sink, still silent | device/cable/phones side | check `adi2 dump`, phones jack, cable |
| stream plays to a non-default sink | per-app routing stuck | `pactl move-sink-input <idx> rme_phones` |

## Rules
- Avoid restarting PipeWire while the user has apps open: it is what stales their audio. If you must, tell him which apps to reopen.
- Never raise device or sink volume without asking (ears, speakers).
- GUI view: `qpwgraph` (launch, then move silently to his workspace with
  `hyprctl dispatch 'hl.dsp.window.move({ workspace = N, follow = false, window = "pid:PID" })'`).
