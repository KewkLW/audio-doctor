# Example run: the no-audio tier on this branch

A recorded run of the no-audio block in `SKILL.md`, so a reader (and the reviewer) can see what a
passing run looks like and that every step really ran. Recorded on the branch that added the skill
(`b17-verify-pilot-verify-skill-for-audio`), from its worktree root, with the block extracted
unedited from `SKILL.md` exactly as its "The block" section says:

```bash
F=$(mktemp) && trap 'rm -f -- "$F"' EXIT
sed -n '/^# --- no-audio tier begin ---$/,/^# --- no-audio tier end ---$/p' .claude/skills/verify/SKILL.md >"$F"
head -3 "$F"    # the begin marker and the recursion guard
grep -nE 'SKILL\.md|\$F|\$0|BASH_SOURCE' "$F" && echo "STOP: the block refers to itself"   # no output: clean
systemd-run --user --scope -q -p TasksMax=2000 timeout 600 bash "$F" >run.txt 2>&1; echo "block exit $?"
```

Before the run the extracted file was read top to bottom (60 lines): it starts with the begin marker
and the recursion guard and nothing in it reads `SKILL.md` or starts itself. It ran once, under the
2000 task cap and the 10 minute timeout, and printed `block exit 0`.

The machine has an RME ADI-2 on USB; the block's stub `lsusb` (exits 1) makes the module see it as
absent, so this is also the run on a machine without the RME. The audio tier was not run: the AUDIO
HOLD is in force and no device holder note exists. No device access, no `adi2` call (it is a logging
stub; step 6 proves it was not called).

Scrubbing: the block itself writes the worktree as `<worktree>`, its scratch dir as `<scratch>` and
the home dir as `~`. One more substitution was made here: the path of the installed checkout that
step 3 prints is written as `<checkout>`.

## Block output

Expected non-zero exits: 5a `detect` exits 1 (stub lsusb: device absent), 4j exits 2 (unknown flag).
`config-audit` and `audio-doctor --audit` may exit 1 on a BREAK in the live config; here they
exited 0. 4e and 4g print `command exit N` first: that is the tool's own exit code, which the step
reports.

```text

== 1a bash -n (19 shell files): bash -c r=0; for f; do bash -n "$f" || r=1; done; exit $r _ audit/m2-bisect.sh audit/quiet-park audit/run-m2-quiet.sh audit/run-root-eval-rtla.sh audit/run-root-eval.sh audit/studio-keepalive bin-omarchy-studio-bitwig install.sh modules/rme-adi2/bin/studio-keepalive modules/rme-adi2/detect modules/rme-adi2/disable modules/rme-adi2/enable modules/rme-adi2/status modules/rme-adi2/test-roundtrip.sh tests/install-roundtrip.sh uninstall.sh yabridge-input/ab-click.sh yabridge-input/ab-keys.sh yabridge-input/bitwig-keytest.sh
   | 
   exit 0

== 1b python ast.parse (15 files): python3 -I -c import ast,sys
for f in sys.argv[1:]: ast.parse(open(f).read(), f) audio-doctor audit/boot-inventory audit/daw-ramp audit/footprint audit/m2-report audit/power-ab audit/quantum-sweep.py audit/quiet-report audit/studio-power-apply config-audit omarchy-audio-audit omarchy-audio-watch whatis yabridge-input/minihost.py yabridge-input/xtree.py
   | 
   exit 0

== 2 shellcheck -S error: shellcheck -S error -e SC1087 audit/m2-bisect.sh audit/quiet-park audit/run-m2-quiet.sh audit/run-root-eval-rtla.sh audit/run-root-eval.sh audit/studio-keepalive bin-omarchy-studio-bitwig install.sh modules/rme-adi2/bin/studio-keepalive modules/rme-adi2/detect modules/rme-adi2/disable modules/rme-adi2/enable modules/rme-adi2/status modules/rme-adi2/test-roundtrip.sh tests/install-roundtrip.sh uninstall.sh yabridge-input/ab-click.sh yabridge-input/ab-keys.sh yabridge-input/bitwig-keytest.sh
   | 
   exit 0

== 3 tests/install-roundtrip.sh (stub lsusb): bash tests/install-roundtrip.sh
   | == real install, before
   | # bin entries
   | audio-doctor -> <checkout>/audio-doctor
   | ...
   | 
   | RESULT: PASS (2 cycles)
   exit 0

== 4a install.sh --help: <worktree>/install.sh --help
   | install.sh [options]
   | 
   | Installs into the current user's home (honours HOME, XDG_CONFIG_HOME, XDG_DATA_HOME):
   | ...
   |   --check         only check dependencies (exit 1 when a required one is missing)
   |   -h, --help      this text
   exit 0

== 4b install.sh --check: <worktree>/install.sh --check
   | Dependencies:
   |   ok        python3
   |   ok        pw-cli
   | ...
   |   ok        turbostat
   |   ok        stress-ng
   exit 0

== 4c uninstall.sh --help: <worktree>/uninstall.sh --help
   | uninstall.sh: stop and remove the watch unit, run each module's disable, then remove every
   | file install.sh listed in $XDG_DATA_HOME/audio-doctor/install-manifest. Honours HOME and XDG_*.
   | Your results in ~/.local/state/omarchy-studio are never touched.
   exit 0

== 4d audio-doctor --audit: <worktree>/audio-doctor --audit
   | config audit: 7 drop-ins read
   |   ~/.config/pipewire/pipewire.conf.d/10-studio-rates.conf
   |   ~/.config/pipewire/pipewire.conf.d/50-rme-adi2-stereo.conf
   | ...
   |   ~/.config/wireplumber/wireplumber.conf.d/bluetooth-a2dp-autoconnect.conf
   |   [INFO ] rme       no RME ADI-2: module off
   exit 0

== 4e audio-doctor --audit --json: bash -c o=$("$@"); r=$?; echo "command exit $r"; printf "%s\n" "$o" | python3 -I -c "import json,sys; d=json.load(sys.stdin); print(len(d[\"files\"]), \"drop-ins,\", len(d[\"findings\"]), \"findings\")" || { echo "not the expected JSON"; exit 3; }; exit $r _ <worktree>/audio-doctor --audit --json
   | command exit 0
   | 7 drop-ins, 1 findings
   exit 0

== 4f config-audit: <worktree>/config-audit
   | config audit: 7 drop-ins read
   |   ~/.config/pipewire/pipewire.conf.d/10-studio-rates.conf
   |   ~/.config/pipewire/pipewire.conf.d/50-rme-adi2-stereo.conf
   | ...
   |   ~/.config/wireplumber/wireplumber.conf.d/bluetooth-a2dp-autoconnect.conf
   |   [INFO ] rme       no RME ADI-2: module off
   exit 0

== 4g config-audit --json: bash -c o=$("$@"); r=$?; echo "command exit $r"; printf "%s\n" "$o" | python3 -I -c "import json,sys; d=json.load(sys.stdin); print(len(d[\"files\"]), \"drop-ins,\", len(d[\"findings\"]), \"findings\")" || { echo "not the expected JSON"; exit 3; }; exit $r _ <worktree>/config-audit --json
   | command exit 0
   | 7 drop-ins, 1 findings
   exit 0

== 4h whatis --help: <worktree>/whatis --help
   | whatis: say which real app a process is, when its process name hides it.
   | 
   |   whatis PID|NAME     identify one pid, or every app matching NAME (comm, real name, window)
   | ...
   | .desktop / Steam manifest files. It never signals or touches a process or window.
   | audio-doctor imports this file (SourceFileLoader, since it has no .py suffix).
   exit 0

== 4i omarchy-audio-audit --help: <worktree>/omarchy-audio-audit --help
   | usage: omarchy-audio-audit [options]   (no options: full run, ~12 min, one sudo approval)
   |   -h, --help          print this and exit (no run)
   |   --quick             short probes (~4 min), for a smoke test
   | ...
   |   --rtla PATH         internal: rtla path for the root helper
   |   --user NAME         internal: the invoking user, for the root helper
   exit 0

== 4j omarchy-audio-audit --no-such-flag: <worktree>/omarchy-audio-audit --no-such-flag
   | omarchy-audio-audit: unknown argument: --no-such-flag
   | usage: omarchy-audio-audit [options]   (no options: full run, ~12 min, one sudo approval)
   |   -h, --help          print this and exit (no run)
   | ...
   |   --rtla PATH         internal: rtla path for the root helper
   |   --user NAME         internal: the invoking user, for the root helper
   exit 2

== 4k omarchy-audio-watch (usage): <worktree>/omarchy-audio-watch
   | omarchy-audio-watch: long-running, cheap monitor of the things that can hurt (or help) audio over time.
   | Start of W11 (omarchy-audio-watch). Samples every 30 s, xruns every other sample, into
   | ~/.local/state/omarchy-studio/watch/YYYY-MM-DD.jsonl. Toggles (GPU lock, NVMe cap) append markers to
   | ...
   | util, throttle reasons), CPU (package temp, throttle-time delta, busy %, avg MHz), every NVMe by serial (temp,
   | pm_qos tolerance), RME/Bitwig xrun increases, new kernel Xid lines, own CPU cost.
   exit 0

== 4l audit/footprint (usage): <worktree>/audit/footprint
   | footprint NAME [--secs 30] | footprint compare A B
   | System footprint snapshot for before/after comparisons (e.g. no DAW vs DAW loaded with tracks inactive).
   | Measures over a window: whole-machine CPU busy, per-process CPU (top 15), memory (used, available,
   | swap), process/thread counts, load average, package temperature, average core clock, PipeWire graph
   | (driver quantum, per-node busy/quantum, ERR). Saves ~/.local/state/omarchy-studio/footprint/NAME.json.
   exit 0

== 5a rme-adi2/detect (expect 1): <worktree>/modules/rme-adi2/detect
   | 
   exit 1

== 5b RME specific commands: skipped (detect reports the device absent; module status and studio-keepalive are not run)

== 6 guard stubs unused: sh -c ! [ -s "$1" ] || { cat "$1"; exit 1; } _ <scratch>/guard/called
   | 
   exit 0

== summary
  PASS 1a bash -n (19 shell files) (exit 0)
  PASS 1b python ast.parse (15 files) (exit 0)
  PASS 2 shellcheck -S error (exit 0)
  PASS 3 tests/install-roundtrip.sh (stub lsusb) (exit 0)
  PASS 4a install.sh --help (exit 0)
  PASS 4b install.sh --check (exit 0)
  PASS 4c uninstall.sh --help (exit 0)
  PASS 4d audio-doctor --audit (exit 0)
  PASS 4e audio-doctor --audit --json (exit 0)
  PASS 4f config-audit (exit 0)
  PASS 4g config-audit --json (exit 0)
  PASS 4h whatis --help (exit 0)
  PASS 4i omarchy-audio-audit --help (exit 0)
  PASS 4j omarchy-audio-audit --no-such-flag (exit 2)
  PASS 4k omarchy-audio-watch (usage) (exit 0)
  PASS 4l audit/footprint (usage) (exit 0)
  PASS 5a rme-adi2/detect (expect 1) (exit 1)
  PASS 6 guard stubs unused (exit 0)
NO-AUDIO TIER GREEN
```

`block exit 0`.

## Guard and failure paths

The recursion guard and the JSON wrapper `J` from the block (taken from the extracted file), checked
with stand-in commands:

```text
$ VERIFY_NOAUDIO_RUNNING=1 bash <extracted block>
no-audio block: already running (recursion guard), refusing
exit 2
$ JSON wrapper around a command that prints valid JSON then exits 5
command exit 5
0 drop-ins, 0 findings
exit 5
$ JSON wrapper around a command that exits 0 with non-JSON output
command exit 0
Traceback (most recent call last):
json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)
not the expected JSON
exit 3
```

A nested run refuses with exit 2. A JSON step reports the command's own exit code (5 here, so the
step fails), and output that is not the expected JSON is exit 3. The block exits `"$RC"`: 1 when any
step is `FAIL`, 0 only when all pass.

Note on 4d and 4f: with the device absent, `audio-doctor --audit` and `config-audit` still print one
`[INFO ] rme ... no RME ADI-2: module off` line. That is the tools' behaviour on master (this branch
changes no tool), not something the skill adds; it is filed with the orchestrator as a gap against
REVIEW.md section 2.

## RME absent: install roundtrip with the stub lsusb

`PATH="<stubdir>:$PATH" bash tests/install-roundtrip.sh` (stub `lsusb` exits 1), exit 0. Its
absent-device lines (two install cycles, then the uninstall), grepped from the full log:

```text
|   rme-adi2: device not present, not enabled
module rme-adi2: device absent; its status reports 0 piece(s) placed
ok    module rme-adi2 absent: no module pieces placed, no module manifest
|   rme-adi2: device not present, not enabled
module rme-adi2: device absent; its status reports 0 piece(s) placed
ok    module rme-adi2 absent: no module pieces placed, no module manifest
|   absent: device not present, not enabled
RESULT: PASS (2 cycles)
```

## Privacy grep

Run on both committed files after the run output above was pasted in. The private value list (user
name, home and mount paths, vault name, hostname, tailnet name, keyring tool and account, mail domain,
git author name; 10 values) is kept outside the repo, so it appears here as `<private-patterns>`.

```text
$ grep -n -i -F -f <private-patterns> SKILL.md EXAMPLE-RUN.md
exit 1
$ grep -nE '(^|[[:space:]"'"'"'=(])/(hom[e]|mn[t]|Users|roo[t])/' SKILL.md EXAMPLE-RUN.md   # absolute home or mount paths
exit 1
$ grep -nE '[0-9]{1,3}(\.[0-9]{1,3}){3}' SKILL.md EXAMPLE-RUN.md   # IPv4
exit 1
$ grep -nE '\.ts\.ne[t]|\.loca[l]([[:space:]]|$)' SKILL.md EXAMPLE-RUN.md   # host names
exit 1
$ grep -nE '\b[0-9A-Fa-f]{12,}\b' SKILL.md EXAMPLE-RUN.md   # serial-like hex
exit 1
```

Every grep exits 1: no hits.
