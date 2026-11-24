# audio-doctor

A diagnostics kit for PipeWire audio on Arch based systems (built for Omarchy Studio). It finds where sound stops, lints PipeWire and WirePlumber configuration, and measures how fit a machine is for realtime audio. It only diagnoses; it does not tune your system unless you explicitly ask.

## Quickstart

```bash
git clone https://github.com/KewkLW/audio-doctor
cd audio-doctor
./install.sh
```

Then run:

```bash
audio-doctor                        # ~3 s passive check: prints VERDICT: first
omarchy-audio-audit --quick         # ~4 min realtime fitness + power audit (1 sudo prompt; add --no-root to skip sudo)
```

Every command supports `-h` / `--help` and exits cleanly without touching audio or starting a run.

**Alpha testers:** please test install, `audio-doctor`, `config-audit`, `omarchy-audio-audit --quick`, and `./uninstall.sh`, and share any traceback, missing dependency, unexpected warning, or generated HTML report.

## The tools

| Command | What it does |
|---|---|
| `audio-doctor` | Walks the audio chain (services, hardware, routing, real signal levels, device, stale apps) and prints a `VERDICT:` line naming the first broken hop. Takes about 3 seconds. Start here for any "no sound" problem. |
| `config-audit` | Reads every PipeWire and WirePlumber drop-in and compares it with the running graph. Reports config traps that break audio later (loopbacks that never relink, missing targets, files that do not parse). |
| `whatis` | Names the real app behind a generic process name (browser web apps, Wine/Proton, AppImage, Electron, Flatpak, scripts) and flags apps that lost audio after a PipeWire restart. |
| `omarchy-audio-audit` | Measures realtime fitness: timer latency with and without CPU sleep states, xruns per buffer size, power settings that hurt audio. Writes a JSON file and an HTML report. Full run about 12 minutes, `--quick` about 4. |
| `omarchy-audio-watch` | Background monitor: every 30 s it logs CPU, NVMe, PipeWire xruns, and NVIDIA GPU metrics if present. `omarchy-audio-watch report out.html` turns the log into a page with charts. Runs as a user service once you start it. |
| `footprint` | `footprint NAME` snapshots CPU, memory, threads and the PipeWire graph; `footprint compare A B` shows the difference (for example before and after loading a DAW project). |

All six commands accept `-h` / `--help` (exit 0 without running) and reject unknown flags with usage on stderr (exit 2). Run without options, `audio-doctor` and `config-audit` only read and measure; `--fix` (both) relinks streams and `--tone` (`audio-doctor`) plays a quiet test tone.

## Install

`./install.sh` needs no sudo and never installs packages. It places:

- the six commands in `~/.local/bin` (copies; `./install.sh --link` makes symlinks to the checkout instead)
- `omarchy-audio-watch.service` in `~/.config/systemd/user/`, installed but **not started**
- the agent skill in `~/.claude/skills/audio-doctor/SKILL.md` (only used by Claude Code; harmless otherwise)
- the device modules from `modules/` in `~/.local/share/audio-doctor/modules/`
- a manifest of all of the above in `~/.local/share/audio-doctor/install-manifest`

It honours `XDG_CONFIG_HOME` and `XDG_DATA_HOME`. `--bindir DIR` puts the commands in DIR instead (device modules are told the bin dir via `XDG_BIN_HOME`). If a file it wants to place already exists and was not placed by it, or was placed by it and changed since, it leaves that file alone, says so and exits 1 (`--force` replaces it). A module whose files were not all placed by this run is not run at all. If a required tool is missing it still installs, prints the pacman package to add and exits 1.

It ends with `Done.` and exit 0 only when everything was placed (and, with `--start`, the service started). Otherwise it lists what failed or was left alone, says `Install INCOMPLETE` and exits 1; what it did place is in the manifest, so `./uninstall.sh` still removes it.

To start the background watch service, answer yes at the prompt, pass `--start`, or later run:

```bash
systemctl --user enable --now omarchy-audio-watch.service
```

### Dependencies

The installer checks these and prints the `pacman` command for anything missing. `./install.sh --check` runs only the check.

| Needed for | Commands | Arch package |
|---|---|---|
| everything (required) | `python3` | `python` |
| everything (required) | `pw-cli`, `pw-dump`, `pw-top`, `pw-metadata`, `pw-link`, `spa-json-dump` | `pipewire` |
| everything (required) | `pw-cat`, `pw-play`, `pw-record` | `pipewire-audio` |
| everything (required) | `wpctl` | `wireplumber` |
| everything (required) | `pactl` | `libpulse` |
| device detection (required) | `lsusb` | `usbutils` |
| the audit (required) | `cyclictest` | `rt-tests` |
| the audit (optional) | `rtla` | no Arch repo package; AUR, or build from kernel source `tools/tracing/rtla` |
| the audit (optional) | `turbostat` | `turbostat` |
| the audit (optional) | `stress-ng` | `stress-ng` |
| the audit (optional) | `lspci` | `pciutils` |
| CPU temp fallback (optional) | `sensors` | `lm_sensors` |
| `audio-doctor --tone` (optional) | `ffmpeg` | `ffmpeg` |

## Uninstall

```bash
./uninstall.sh
```

It stops and disables the watch service, runs `disable` for each module it installed (only when that `disable` is still the file it placed), then removes the files in the manifest (the copied commands, their Python bytecode, the unit, the skill, the modules). Files you edited after install are kept and listed. If a module's `disable` fails, that module's installed copy stays, the manifest is rewritten to what remains on disk and it exits 1; fix the cause and run `./uninstall.sh` again. It never deletes your results in `~/.local/state/omarchy-studio/` (audit reports, watch logs, footprints) or any report you saved elsewhere.

## What the kit changes on your system

By default, nothing beyond the installed files listed above. Installing does not start any service, change any setting, or restart PipeWire.

Actions that change runtime state only happen when you explicitly invoke them:

- `audio-doctor --fix` and `config-audit --fix` relink app streams whose target exists but is not linked.
- `audio-doctor --tone` plays a quiet 440 Hz tone (at -30 dBFS) into the default output.
- `omarchy-audio-audit` tests PipeWire buffer sizes one at a time during its sweep and restores the original value on every exit path. It plays a silent stream and adds CPU load (`stress-ng`) while it measures. It refuses the sweep while a DAW is connected.
- The watch service, once started, samples every 30 s at low priority and writes to `~/.local/state/omarchy-studio/watch/`.
- A device module that detects its device at install time places its config drop-ins. New PipeWire configuration takes effect at the next PipeWire start; nothing in the kit restarts PipeWire. `uninstall.sh` removes those pieces.

## The one sudo prompt

Only `omarchy-audio-audit` uses sudo, once per run, for its read-only root latency probes: `cyclictest`, `rtla` timerlat, `turbostat` and `lspci` (to read PCIe power states). The root helper only measures; it changes nothing.

- **Interactive terminal (default):** runs `sudo -v` once on your terminal so you can enter your password (or use PAM push / fingerprint), then launches the root helper without prompting again.
- **Unattended modes:** `--sudo ntfy` uses non-interactive PAM push approval; `--sudo keyring` reads the password from the desktop keyring via `secret-tool`.
- **No sudo:** `omarchy-audio-audit --no-root` skips the root probes on purpose. If sudo is cancelled or fails, the audit skips the root probes, notes it in the report, and still runs everything else.

No other command and neither install script uses sudo.

## With or without an RME ADI-2 Pro

Everything works on any PipeWire system. The RME ADI-2 Pro module adds hardware checks only when the device is present on USB.

- Without the device: every tool runs; RME checks are skipped and no RME errors appear.
- With the device: `audio-doctor` reads device state (mute, volume, output source, faults) and `omarchy-audio-audit` checks auto-standby. Both use the separate `adi2` CLI from [adi2-control](https://github.com/KewkLW/adi2-control) when installed on your `PATH`.
- The RME module in `modules/rme-adi2/` is enabled by `install.sh` when the device is plugged in at install time (run `./install.sh` again if you plug it in later). Its `studio-keepalive` helper uses a fail-safe read-only MIDI status pulse and never modifies `device.auto_standby`.

## Testing

```bash
tests/install-roundtrip.sh [cycles]
python3 -I tests/test_cli_safety.py
```

`tests/install-roundtrip.sh` installs into throwaway `HOME` directories under `/tmp`, verifies manifests, runs installed commands in safe no-audio modes, tests failure and interrupt paths, uninstalls cleanly, and proves your real home install is untouched. `tests/test_cli_safety.py` checks `--help`, unknown flags, RME gating, and generic hardware/watch behavior offline.

## License

MIT, see `LICENSE`.
