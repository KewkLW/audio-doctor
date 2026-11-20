---
name: verify
description: Prove a change to audio-doctor works on the real system before committing or submitting it. Use before every commit or bounty submit in this repo, when asked to "verify", "QA", "smoke test" or "check it works", and for any change to the kit commands, install.sh / uninstall.sh, modules/ or tests/. Two tiers. The no-audio tier (syntax, shellcheck, the scratch HOME install roundtrip, every command run from the worktree in its safe modes) is always allowed. The audio tier is gated: only after the AUDIO HOLD is lifted and you are named the RME device holder.
---

# Verify an audio-doctor change

Prove it on the real system, from the worktree you changed, not from the installed copies. The kit
commands in `~/.local/bin` may be links into another checkout: always run the worktree's file by its
path (`$W/audio-doctor`, never `audio-doctor`) and show that path in your evidence.

Unit tests and a green gate are not QA. The no-audio tier below is the minimum for every change; the
audio tier is the proof for a change to measuring, routing or the RME module, and only when allowed.

## Hard rules (both tiers)

- Never restart PipeWire or pipewire-pulse while apps are open. Not to "reset" a test, not to load a
  drop-in. If a step seems to need it, stop and report. (A WirePlumber restart is the known fix for RME
  nodes without ports; that is a repair for the user, not a verify step.)
- Never raise any volume: not a sink, not a stream, not the device, not a DAW fader, not the RME's
  line or phones level. You may lower or keep. A signal too quiet to measure is a finding to report, not
  a reason to turn something up.
- Never send a write, erase or unknown vendor OUT request to the RME ADI-2. Reads only, and only as the
  named device holder. No firmware, flash, DSP or EEPROM tools.
- Never touch the live install or the live config: no edits, relinks or deletes in `~/.local/bin`,
  `~/.local/state/omarchy-studio`, or the live PipeWire / WirePlumber drop-ins. Install tests go into a
  scratch HOME.
- Never run a fixing mode as a check: no `--fix` on `audio-doctor` or `config-audit`.
- Kill only processes you started, by the PID you recorded. Never `pkill` by a pattern.
- One run is not a result. Repeat a measurement and report both runs before claiming it.

## 1. No-audio tier (always allowed, also under the AUDIO HOLD)

Plays nothing, opens no stream, needs no device, no sudo, no write to the real HOME. Needs `shellcheck`
installed (step 2 fails without it). It passes on a
machine without the RME: the block puts a stub `lsusb` that exits 1 first on PATH, so the RME module
reports absent (the same method as `tests/install-roundtrip.sh`). It also puts logging stubs for
everything that could play audio or reach the device (`pw-play`, `pw-cat`, `pw-record`, `pw-metadata`,
`adi2`, `sudo`, `stress-ng`) first on PATH; step 6 fails if any of them was called.

### Safe invocation per command

Several commands have no `--help` branch and treat an unknown argument as a real run. Use only these:

| Command (run as `$W/<path>`)   | Safe here                              | Never in this tier                              |
|--------------------------------|----------------------------------------|-------------------------------------------------|
| `audio-doctor`                 | `--audit`, `--audit --json`            | no arguments, `--help` (both meter live streams), `--tone`, `--fix` |
| `config-audit`                 | no arguments, `--json` (read only)     | `--fix`                                         |
| `whatis`                       | `--help`                               | (`--audio` / `--gui` read live processes: fine, not needed) |
| `omarchy-audio-audit`          | `--help` (exit 0), an unknown flag (exit 2) | any real run: it plays a silence stream and sweeps buffer sizes |
| `omarchy-audio-watch`          | no arguments (prints usage), scratch HOME | `run` (long sampler), `--help` (prints nothing) |
| `audit/footprint`              | no arguments (prints usage)            | `--help` (taken as a label: a 30 s snapshot)    |
| `install.sh`                   | `--help`, `--check` (deps only)        | a real install outside a scratch HOME           |
| `uninstall.sh`                 | `--help`                               | a real uninstall                                |
| `modules/rme-adi2/detect`      | as is (lsusb / sysfs read only)        |                                                 |
| `modules/rme-adi2/status`      | as is, `--json`                        |                                                 |
| `modules/rme-adi2/bin/studio-keepalive` | `status`, only with the stub lsusb | `on`, `off`; `status` with the device present (it queries the device) |

`config-audit` (and `audio-doctor --audit`) exit 1 when the live config has a BREAK finding. That is a
result about the machine, not a broken command: exit 0 or 1 with the normal report and no traceback is a
pass. Anything else (exit 2+, a traceback, no output) is a fail.

`modules/rme-adi2/test-roundtrip.sh` is not in this tier: it runs `audio-doctor`'s live metering, and with
the device on USB it reads the ADI-2. Run it only in the audio tier, as the device holder.

### The block

Run it from the root of the worktree you changed. It prints every command, its first output lines and
`exit N`, then a summary. Paste that output (with your worktree path written as `<worktree>`) into the
evidence.

```bash
# --- no-audio tier begin ---
W=$(git rev-parse --show-toplevel) || exit 1
S=$(mktemp -d /tmp/verify-noaudio.XXXXXX) || exit 1
mkdir -p "$S/home" "$S/nousb" "$S/guard"; : >"$S/guard/called"
printf '#!/bin/sh\nexit 1\n' >"$S/nousb/lsusb"; chmod +x "$S/nousb/lsusb"   # RME absent
for t in pw-play pw-cat pw-record pw-metadata adi2 sudo stress-ng; do
  printf '#!/bin/sh\necho "%s $*" >>"%s/guard/called"\nexit 1\n' "$t" "$S" >"$S/guard/$t"; chmod +x "$S/guard/$t"
done
G=(env PATH="$S/guard:$S/nousb:$PATH")
GH=("${G[@]}" HOME="$S/home" XDG_CONFIG_HOME="$S/home/.config" XDG_STATE_HOME="$S/home/.local/state" XDG_DATA_HOME="$S/home/.local/share")
RES=()
step() {  # step "N label" OK_CODES cmd...  (OK_CODES like 0 or 0,1)
  local label=$1 okc=$2 o r a show=() lead=1; shift 2
  for a in "$@"; do  # print the command without the env assignments (they hold local paths)
    if [ $lead = 1 ] && { [ "$a" = env ] || [[ $a == [A-Z_]*=* ]]; }; then continue; fi; lead=0; show+=("$a"); done
  echo; echo "== $label: ${show[*]}" | sed "s|$W|<worktree>|g; s|$S|<scratch>|g; s|$HOME|~|g"
  o=$("$@" 2>&1); r=$?
  { echo "$o" | head -3; [ "$(echo "$o" | wc -l)" -gt 5 ] && echo "..."; echo "$o" | tail -n +4 | tail -2; } \
    | sed "s|$W|<worktree>|g; s|$S|<scratch>|g; s|$HOME|~|g; s/^/   | /"
  echo "   exit $r"
  case ",$okc," in *",$r,"*) RES+=("PASS $label (exit $r)") ;; *) RES+=("FAIL $label (exit $r)") ;; esac
}
mapfile -t SH < <(cd "$W" && git ls-files | while read -r f; do [ -f "$f" ] && head -1 "$f" | grep -qE '^#!.*(bash|/sh)' && echo "$f"; done)
mapfile -t PY < <(cd "$W" && git ls-files | while read -r f; do [ -f "$f" ] && { [[ $f == *.py ]] || head -1 "$f" | grep -qE '^#!.*python'; } && echo "$f"; done)
cd "$W" || exit 1
# 1 syntax
step "1a bash -n (${#SH[@]} shell files)" 0 bash -c 'r=0; for f; do bash -n "$f" || r=1; done; exit $r' _ "${SH[@]}"
step "1b python ast.parse (${#PY[@]} files)" 0 python3 -I -c 'import ast,sys
for f in sys.argv[1:]: ast.parse(open(f).read(), f)' "${PY[@]}"
# 2 shellcheck at error level (SC1087 excluded, as the merge gate does)
step "2 shellcheck -S error" 0 shellcheck -S error -e SC1087 "${SH[@]}"
# 3 install, use and uninstall in a scratch HOME, RME absent
step "3 tests/install-roundtrip.sh (stub lsusb)" 0 "${G[@]}" bash tests/install-roundtrip.sh
# 4 every kit command from the worktree, safe modes only
step "4a install.sh --help"            0   "${GH[@]}" "$W/install.sh" --help
step "4b install.sh --check"           0   "${GH[@]}" "$W/install.sh" --check
step "4c uninstall.sh --help"          0   "${GH[@]}" "$W/uninstall.sh" --help
step "4d audio-doctor --audit"         0,1 "${G[@]}" "$W/audio-doctor" --audit
step "4e audio-doctor --audit --json"  0   "${G[@]}" sh -c '"$1" --audit --json | python3 -I -c "import json,sys; d=json.load(sys.stdin); print(len(d[\"files\"]), \"drop-ins,\", len(d[\"findings\"]), \"findings\")"' _ "$W/audio-doctor"
step "4f config-audit"                 0,1 "${G[@]}" "$W/config-audit"
step "4g config-audit --json"          0   "${G[@]}" sh -c '"$1" --json | python3 -I -c "import json,sys; d=json.load(sys.stdin); print(len(d[\"files\"]), \"drop-ins,\", len(d[\"findings\"]), \"findings\")"' _ "$W/config-audit"
step "4h whatis --help"                0   "${GH[@]}" "$W/whatis" --help
step "4i omarchy-audio-audit --help"   0   "${GH[@]}" "$W/omarchy-audio-audit" --help
step "4j omarchy-audio-audit --no-such-flag" 2 "${GH[@]}" "$W/omarchy-audio-audit" --no-such-flag
step "4k omarchy-audio-watch (usage)"  0   "${GH[@]}" "$W/omarchy-audio-watch"
step "4l audit/footprint (usage)"      0   "${GH[@]}" "$W/audit/footprint"
# 5 RME module with the device absent: detect says absent, nothing is placed, keepalive is neutral
step "5a rme-adi2/detect (expect 1)"   1   "${GH[@]}" "$W/modules/rme-adi2/detect"
step "5b rme-adi2/status"              0   "${GH[@]}" "$W/modules/rme-adi2/status"
step "5c rme-adi2/status --json"       0   "${GH[@]}" "$W/modules/rme-adi2/status" --json
step "5d studio-keepalive status"      0   "${GH[@]}" "$W/modules/rme-adi2/bin/studio-keepalive" status
# 6 nothing that plays audio or reaches the device was called
step "6 guard stubs unused"            0   sh -c '! [ -s "$1" ] || { cat "$1"; exit 1; }' _ "$S/guard/called"
echo; echo "== summary"; printf '  %s\n' "${RES[@]}"
printf '%s\n' "${RES[@]}" | grep -q '^FAIL' && echo "NO-AUDIO TIER RED" || echo "NO-AUDIO TIER GREEN"
rm -rf -- "$S"
# --- no-audio tier end ---
```

When a step fails, rerun that one command by hand from the worktree and read the full output. Step 3
takes about half a minute and prints its full log; on a failure read its `FAIL` lines. Do not edit the
block to make a step pass; fix the change, or report the step as a finding.

If your change adds a command or a flag, add its safe invocation to the table and a step to the block in
the same change.

### Then the merge gate

```bash
/path/to/verify-gate.sh     # the board's gate, if your setup has one; expect VERIFY GREEN
```

It repeats steps 1 to 3 the way the board does on every submit. Green there is required, not sufficient.

## 2. Audio tier (GATED: do not run under the AUDIO HOLD)

Run nothing in this section until both are true, and say which board note says so in your evidence:

1. The orchestrator (Conductor) has lifted the AUDIO HOLD.
2. A board note from the orchestrator names you the RME device holder (only when the RME is detected;
   with no RME, the hold alone gates this tier). The ADI-2 is one shared device with one holder at a
   time. When your hardware session ends, post a progress note that you released it.

Every RME step below runs only when `$W/modules/rme-adi2/detect` exits 0. When it exits 1 (no ADI-2 on
USB, off, or in standby), skip every RME step, say so in the evidence, and verify on whatever output the
machine has.

### Before

- Note what is playing and which apps hold audio (`$W/whatis --audio`). Do not stop or reconnect any
  of them. If a DAW holds the RME's MIDI port, the keepalive cannot run: report it and stop.
- Take the before state: `$W/audio-doctor --json`, `$W/config-audit --json`, the default sink and its
  volume (`wpctl get-volume @DEFAULT_AUDIO_SINK@`), the PipeWire and pipewire-pulse PIDs, and the sha256
  of the live drop-ins. You must find the same values after.
- RME detected and you are the holder: `studio-keepalive status`, then `studio-keepalive on` so the
  device stays awake for the run, then `status` again to confirm it is active. Treat it as on, off and
  status only; it is the module's tool, not a device setting for you to change. Check the RME with
  `adi2` reads only.

### Signal: a loopback in the graph, as its own client

Never play a test signal into the user's default sink or into an app's stream, and never move an
existing stream. Make your own path:

- Start a `pw-loopback` with its own unique node names (for example `verify_probe` and
  `verify_probe.out`), its capture side a sink no other app uses and its playback side targeting the
  output under test (with the RME: the module's loopback node `rme_phones`, which leads to the ADI-2's
  ALSA sink). Record its PID.
- Play the test signal into `verify_probe` only, at a fixed low level (about -30 dBFS, like
  `audio-doctor --tone`), with your own `pw-play` / `pw-cat` process; record its PID. Never change a
  sink, stream or device volume to make it louder.
- Measure at the hops you changed: `$W/audio-doctor` meters the app stream, sink, loopback and hardware
  sink and names the first broken hop. With your loopback running it shows it as a client like any other.
- Repeat the measurement at least twice, with the same signal and level, and report every run. A result
  that does not repeat is not a result.
- Stop your player and your loopback by their recorded PIDs. Confirm in `pw-dump` / `audio-doctor`
  that `verify_probe` is gone.

`omarchy-audio-audit` itself (buffer sweep, silence stream) is part of this tier, never of the
no-audio one. It refuses the sweep while a JACK client (a DAW) is connected and restores the clock
settings it found; still run it only with nothing else playing and the user's consent on the board.

### After

- RME: `studio-keepalive off`, then `status` to confirm it is no longer active.
- Take the after state and compare it with the before state: same default sink, same volumes, same
  PipeWire and pipewire-pulse PIDs (no restart), same drop-in hashes, no `verify_probe` node left. Any
  difference is a finding to report, not something to fix quietly.
- Post the progress note that you released the device.

## Evidence for `bounty submit --evidence`

- The branch and commit you verified, and that the commands ran from the worktree by path (written as
  `<worktree>/audio-doctor`, never a real home path).
- The no-audio block's output: every step with its `exit N`, the summary, and `NO-AUDIO TIER GREEN`.
  Name the steps that were expected to be non-zero (detect exits 1 with the stub, the unknown flag exits 2,
  config-audit exits 1 on a BREAK in the live config) and why.
- The merge gate's last line (`VERIFY GREEN`).
- The audio tier: either "not run: AUDIO HOLD in force" (or "not the device holder"), or the board note
  that allowed it, both measurement runs with their numbers, and the before / after comparison.
- What you did not verify, and why.

No private data in the evidence or in committed files: no home or vault paths, hostnames, IPs, device
serials, keyring account names, session ids or real names. Use `~`, `<worktree>`, `<host>` and
placeholders. Raw logs that still hold such values stay outside the repo.
