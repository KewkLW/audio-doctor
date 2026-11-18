# audio-doctor

A small diagnostics kit for PipeWire audio on Arch based systems (built on Omarchy). It finds where sound stops, lints your PipeWire and WirePlumber config, and measures how fit the machine is for realtime audio.

## The tools

| Command | What it does |
|---|---|
| `audio-doctor` | Walks the audio chain (services, hardware, routing, real signal levels, device, stale apps) and prints a `VERDICT:` line naming the first broken hop. Takes about 3 seconds. Start here for any "no sound" problem. |
| `config-audit` | Reads every PipeWire and WirePlumber drop-in and compares it with the running graph. Reports config traps that break audio later (loopbacks that never relink, missing targets, files that do not parse). |
| `whatis` | Names the real app behind a generic process name (browser web apps, Wine/Proton, AppImage, Electron, Flatpak, scripts) and flags apps that lost audio after a PipeWire restart. `whatis --help`. |
| `omarchy-audio-audit` | Measures realtime fitness: timer latency with and without CPU sleep states, xruns per buffer size, power settings that hurt audio. Writes a JSON file and an HTML report. Full run about 12 minutes, `--quick` about 4. |
| `omarchy-audio-watch` | Background monitor: every 30 s it logs GPU, CPU, NVMe and xrun counts. `omarchy-audio-watch report out.html` turns the log into a page with charts. Runs as a user service once you start it. |
| `footprint` | `footprint NAME` snapshots CPU, memory, threads and the PipeWire graph; `footprint compare A B` shows the difference (for example before and after loading a DAW project). |

Usage: `whatis --help`; `omarchy-audio-watch` and `footprint` with no arguments. `audio-doctor` and `config-audit` run straight away with any arguments (both are read only); their options are at the top of each script. Do not pass `--help` to `omarchy-audio-audit` or `footprint`: the audit starts a full run with any arguments, and `footprint --help` takes a 30 s snapshot named `--help`. Read the top of those scripts for their options.

## Install

```
git clone <this repo> audio-doctor
cd audio-doctor
./install.sh
```

No sudo, and it never installs packages. It places:

- the six commands in `~/.local/bin` (copies; `./install.sh --link` makes symlinks to the checkout instead)
- `omarchy-audio-watch.service` in `~/.config/systemd/user/`, installed but **not started**
- the agent skill in `~/.claude/skills/audio-doctor/SKILL.md` (only used by Claude Code; harmless otherwise)
- the device modules from `modules/` in `~/.local/share/audio-doctor/modules/`
- a manifest of all of the above in `~/.local/share/audio-doctor/install-manifest`

It honours `XDG_CONFIG_HOME` and `XDG_DATA_HOME`. If a file it wants to place already exists and was not placed by it, it leaves that file alone and says so (`--force` replaces it).

To start the watch service, answer yes at the prompt, pass `--start`, or later run:

```
systemctl --user enable --now omarchy-audio-watch.service
```

### Dependencies

The installer checks these and prints the package to install for anything missing. `./install.sh --check` runs only the check.

| Needed for | Commands | Arch package |
|---|---|---|
| everything (required) | `python3` | `python` |
| everything (required) | `pw-cli`, `pw-dump`, `pw-top`, `pw-metadata`, `pw-link` | `pipewire` |
| everything (required) | `wpctl` | `wireplumber` |
| the audit (required) | `cyclictest` | `rt-tests` |
| the audit (optional) | `rtla` | no Arch repo package found; AUR, or build it from the kernel source `tools/tracing/rtla` |
| the audit (optional) | `turbostat` | `turbostat` |
| the audit (optional) | `stress-ng` | `stress-ng` |

## Uninstall

```
./uninstall.sh
```

It stops and disables the watch service, runs each module's `disable`, then removes exactly the files in the manifest. A file you edited after install is kept and listed. It never deletes your results in `~/.local/state/omarchy-studio/` (audit reports, watch logs, footprints) or any report you saved elsewhere; it prints where they are so you can delete them yourself.

## What the kit changes on your system

By default, nothing beyond the files listed above. Installing does not start any service, change any setting, or restart PipeWire.

Things that change something, and only when you ask for them:

- `audio-doctor --fix` and `config-audit --fix` relink app streams whose target exists but is not linked.
- `audio-doctor --tone` plays a quiet 440 Hz tone (at -30 dBFS) into the default output.
- `omarchy-audio-audit` forces PipeWire buffer sizes one at a time during its sweep and restores the original value on every exit path. It plays a silent stream and adds CPU load (`stress-ng`) while it measures. It refuses the sweep while a DAW is connected.
- The watch service, once started, samples every 30 s at low priority and writes to `~/.local/state/omarchy-studio/watch/`.
- A device module that detects its device at install time puts its pieces in place (for example PipeWire config). New PipeWire configuration takes effect at the next PipeWire start; nothing in the kit restarts PipeWire. `uninstall.sh` removes those pieces.

## The one sudo prompt

Only `omarchy-audio-audit` uses sudo, once per run, for its root latency probes: `cyclictest`, `rtla` timerlat, `turbostat` and `lspci` (to read PCIe power states). The root helper only measures; it changes nothing.

How the approval arrives: the audit runs `sudo -S` and does not show a terminal password prompt. It expects sudo to be approved some other way, such as a push approval set up in PAM, or it reads the password from the desktop keyring with `--sudo keyring`. On a stock machine with neither, sudo fails quietly and the audit skips the root probes and says so in its report; everything else in the audit still runs. `omarchy-audio-audit --no-root` skips them on purpose. No other command and neither install script uses sudo.

## With or without an RME ADI-2 Pro

Everything works on any PipeWire system. The RME ADI-2 Pro adds rows, it is never required.

- Without the device: every tool runs; the RME specific checks are simply absent.
- With the device: `audio-doctor` also reads the device state (mute, volume, output source, faults) and `omarchy-audio-audit` checks the device's auto standby setting. Both need the separate `adi2` command on your PATH; this kit does not install it.
- The RME module in `modules/rme-adi2/` is enabled by `install.sh` only when the device is plugged in at install time. Plugging it in later does not enable it; run `./install.sh` again. Each tool decides its RME checks at run time, so they appear whenever the device is present.
