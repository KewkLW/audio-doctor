#!/usr/bin/env bash
# tests/install-roundtrip.sh: install, use and uninstall the kit in a scratch HOME, N times
# (default 2), then prove the real user's install was not touched.
#
# Per cycle: seed user data (a state file and a saved report), install.sh --no-start, list every
# placed path, run each installed command from the scratch bin, install again (idempotent),
# uninstall.sh, and check that only the seeded user data is left. After the cycles: the failure
# paths (a foreign file in the way, an unwritable bin dir, a failing `systemctl enable` through a
# PATH shim) must give exit 1, never "Done". Module hooks: only ones install.sh placed in that run (at
# install) or recorded with a matching hash (at uninstall) are executed; a foreign module dir at install,
# a user-added module dir and a tampered hook at uninstall are never run (proved with marker files).
#
# Plays no audio and opens no stream: audio-doctor runs as `--audit` (config only) and
# omarchy-audio-audit, which starts a full measured run with a stream on any invocation, is only
# checked as installed, executable and parsing (Conductor ruling under the audio hold).
# It never calls the real systemctl with a write verb: the scratch unit dir is not on the user
# manager's path, so install.sh and uninstall.sh leave systemd alone; the --start test uses a shim.
set -u
REPO=$(cd "$(dirname "$(realpath "$0")")/.." && pwd)
CYCLES=${1:-2}
KIT=(audio-doctor config-audit whatis omarchy-audio-audit omarchy-audio-watch footprint)
UNIT=omarchy-audio-watch.service
FAIL=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }
tilde() { sed "s|$REAL_HOME|~|g"; }

REAL_HOME=$HOME
real_snapshot() {
  local n
  echo "# bin entries"
  for n in "${KIT[@]}"; do
    if [ -L "$REAL_HOME/.local/bin/$n" ]; then echo "$n -> $(readlink "$REAL_HOME/.local/bin/$n")"
    elif [ -e "$REAL_HOME/.local/bin/$n" ]; then echo "$n file $(sha256sum <"$REAL_HOME/.local/bin/$n" | cut -c1-16)"
    else echo "$n absent"; fi
  done
  echo "# unit"
  systemctl --user show -p LoadState,ActiveState,SubState,UnitFileState,FragmentPath,MainPID "$UNIT" 2>&1
  echo "# skill dir"
  if [ -d "$REAL_HOME/.claude/skills/audio-doctor" ]; then
    (cd "$REAL_HOME/.claude/skills/audio-doctor" && find . -printf '%y %p %s %T@\n' | sort)
  else echo "absent"; fi
}

BEFORE=$(real_snapshot)
echo "== real install, before"; echo "$BEFORE" | tilde

for c in $(seq 1 "$CYCLES"); do
  S=$(mktemp -d /tmp/ad-roundtrip.XXXXXX)
  H=$S/home
  mkdir -p "$H/.local/state/omarchy-studio/watch" "$H/reports"
  echo "user log" >"$H/.local/state/omarchy-studio/watch/2026-01-01.jsonl"
  echo "<html>my report</html>" >"$H/reports/my-audit.html"
  SEED=$( (cd "$H" && find . -type f | sort) )
  E=(env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" XDG_STATE_HOME="$H/.local/state"
         PATH="$H/.local/bin:$PATH")
  echo; echo "== cycle $c: scratch HOME $H"

  out=$("${E[@]}" "$REPO/install.sh" --no-start 2>&1); rc=$?
  echo "$out" | sed 's/^/    | /'
  [ $rc = 0 ] && ok "install.sh exit 0" || bad "install.sh exit $rc"
  echo "$out" | grep -q '^Done\.' && ok "install says Done" || bad "install did not say Done"
  echo "$out" | grep -q 'systemctl not called, not started' && ok "unit installed, not started, systemd untouched" || bad "unit state line missing"

  M=$H/.local/share/audio-doctor/install-manifest
  POSTINST=$( (cd "$H" && find . \( -type f -o -type l \) | sort) )
  PLACED=$(echo "$POSTINST" | grep -vxF -f <(echo "$SEED"))
  echo "  placed (every file and link that is new after install.sh, before any command ran):"
  echo "$PLACED" | sed 's/^/    /'
  RECORDED=$( { awk -F'\t' '$1=="f" || $1=="l" {print $2}' "$M"; echo "$M"; } | sed "s|^$H|.|" | sort)
  [ "$PLACED" = "$RECORDED" ] && ok "every placed file is in the manifest and every manifest file was placed" \
    || { bad "placed files and manifest differ:"; diff <(echo "$RECORDED") <(echo "$PLACED") | sed 's/^/      /'; }
  n=0 missing=0
  while IFS=$'\t' read -r t p x; do n=$((n + 1)); [ -e "$p" ] || { missing=1; bad "manifest entry missing on disk: $p"; }; done <"$M"
  [ $missing = 0 ] && ok "all $n manifest entries exist"
  for k in "${KIT[@]}"; do [ -x "$H/.local/bin/$k" ] || bad "$k not executable in scratch bin"; done
  [ -f "$H/.config/systemd/user/$UNIT" ] && grep -q "ExecStart=$H/.local/bin/omarchy-audio-watch run" "$H/.config/systemd/user/$UNIT" \
    && ok "unit ExecStart points at the scratch bin" || bad "unit missing or ExecStart wrong"
  [ -f "$H/.claude/skills/audio-doctor/SKILL.md" ] && ok "skill placed" || bad "skill missing"

  echo "  running the installed commands from $H/.local/bin:"
  run() {  # run NAME EXPECT_REGEX ARGS...
    local name=$1 re=$2; shift 2
    local o r
    o=$("${E[@]}" timeout 60 "$H/.local/bin/$name" "$@" 2>&1); r=$?
    if [ $r = 0 ] && echo "$o" | grep -qE "$re"; then ok "$name $* -> exit 0: $(echo "$o" | grep -m1 -E "$re" | cut -c1-90)"
    else bad "$name $* -> exit $r"; echo "$o" | tail -5 | sed 's/^/      /'; fi
  }
  run whatis 'usage|whatis' --help
  run omarchy-audio-watch 'report|run'
  run footprint 'compare'
  run config-audit 'config audit: [0-9]+ drop-ins read'
  run audio-doctor 'config audit: [0-9]+ drop-ins read' --audit
  # omarchy-audio-audit: parse-only by Conductor ruling (criterion 3 exception). It has no --help or
  # dry mode: any run starts a measured run that opens a playback stream, which the audio hold forbids.
  # So it is checked as installed, executable and parsing as Python; it is not executed. The missing
  # --help is a GAP filed as its own bounty.
  if [ -x "$H/.local/bin/omarchy-audio-audit" ] && head -1 "$H/.local/bin/omarchy-audio-audit" | grep -q python3 \
     && "${E[@]}" python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$H/.local/bin/omarchy-audio-audit"; then
    ok "omarchy-audio-audit installed, executable, parses (not run: every run opens a playback stream; audio hold)"
  else bad "omarchy-audio-audit missing, not executable or does not parse"; fi

  # Bytecode next to the commands must all come from install.sh (it is in the manifest).
  stray_pyc=$(find "$H/.local/bin" -path '*/__pycache__/*' -type f | grep -vxF -f <(awk -F'\t' '$1=="f" {print $2}' "$M"))
  [ -z "$stray_pyc" ] && ok "every bytecode file in the bin dir after running the commands is one install.sh placed: $(cd "$H" && find .local/bin -path '*/__pycache__/*' -type f | tr '\n' ' ')" \
    || bad "Python wrote bytecode the manifest does not know: $stray_pyc"
  pyc_hash_ok=1
  while IFS=$'\t' read -r t p x; do
    case $p in */__pycache__/*) [ "$(sha256sum "$p" | cut -d' ' -f1)" = "$x" ] || { pyc_hash_ok=0; bad "Python rewrote $p after install"; } ;; esac
  done <"$M"
  [ $pyc_hash_ok = 1 ] && ok "installed bytecode unchanged after the commands ran (uninstall will match its hash)"

  # Files the commands themselves wrote while running (for example libpulse's ~/.config/pulse/cookie):
  # user data, not installed, so uninstall must keep them.
  RUNTIME=$( (cd "$H" && find . \( -type f -o -type l \) | sort) | grep -vxF -f <(echo "$POSTINST") )
  echo "  made by the commands at run time (not by install.sh): ${RUNTIME:-none}"
  EXPECT=$(printf '%s\n%s\n' "$SEED" "$RUNTIME" | grep -v '^$' | sort)

  out=$("${E[@]}" "$REPO/install.sh" --no-start 2>&1); rc=$?
  [ $rc = 0 ] && ok "second install.sh over the first: exit 0" || { bad "second install exit $rc"; echo "$out" | tail -8; }
  [ "$(grep -c '^b' "$M")" = 1 ] && [ "$(cut -f1,2 "$M" | sort | uniq -d)" = "" ] \
    && ok "manifest after the second install: one bin-dir line, no duplicate entries" || bad "manifest has duplicates: $(cut -f1,2 "$M" | sort | uniq -d)"

  out=$("${E[@]}" "$REPO/uninstall.sh" 2>&1); rc=$?
  echo "$out" | sed 's/^/    | /'
  [ $rc = 0 ] && ok "uninstall.sh exit 0" || bad "uninstall.sh exit $rc"

  LEFT=$( (cd "$H" && find . -mindepth 1 \( -type f -o -type l \) | sort) )
  if [ "$LEFT" = "$EXPECT" ]; then ok "only user data is left: $(echo $LEFT)"
  else bad "files left after uninstall differ from the user data:"; diff <(echo "$EXPECT") <(echo "$LEFT") | sed 's/^/      /'; fi
  stray=$(cd "$H" && find . -mindepth 1 -type d | while read -r d; do
            echo "$EXPECT" | grep -q "^$d/" || echo "$d"; done)
  [ -z "$stray" ] && ok "no empty directories left behind" || bad "directories left: $stray"
  rm -rf "$S"
done

echo; echo "== failure paths"
S=$(mktemp -d /tmp/ad-roundtrip.XXXXXX); H=$S/home; mkdir -p "$H/.local/bin"
E=(env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" PATH="$H/.local/bin:$PATH")
echo "mine" >"$H/.local/bin/whatis"
out=$("${E[@]}" "$REPO/install.sh" --no-start 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q 'Install INCOMPLETE' && ! echo "$out" | grep -q '^Done' \
  && ok "foreign file in the way: exit 1, INCOMPLETE" || bad "foreign file: exit $rc"
[ "$(cat "$H/.local/bin/whatis")" = mine ] && ok "foreign file untouched" || bad "foreign file was changed"
"${E[@]}" "$REPO/uninstall.sh" >/dev/null 2>&1
[ "$(cd "$H" && find . -mindepth 1 | sort | tr '\n' ' ')" = "./.local ./.local/bin ./.local/bin/whatis " ] \
  && ok "uninstall after a partial install leaves only the foreign file" || bad "partial uninstall left: $(cd "$H" && find . -mindepth 1)"
rm -rf "$S"

# Bytecode Python wrote at run time that install.sh did not (for example after a Python upgrade):
# uninstall.sh reports it and leaves it.
S=$(mktemp -d /tmp/ad-roundtrip.XXXXXX); H=$S/home; mkdir -p "$H"
E=(env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" PATH="$H/.local/bin:$PATH")
"${E[@]}" "$REPO/install.sh" --no-start >/dev/null 2>&1
echo "not ours" >"$H/.local/bin/__pycache__/whatiscpython-399.pyc"
out=$("${E[@]}" "$REPO/uninstall.sh" 2>&1); rc=$?
[ $rc = 0 ] && [ "$(cat "$H/.local/bin/__pycache__/whatiscpython-399.pyc")" = "not ours" ] \
  && echo "$out" | grep -q 'whatiscpython-399.pyc (written by Python at run time, not by install.sh)' \
  && [ "$(cd "$H" && find . -mindepth 1 -type f)" = "./.local/bin/__pycache__/whatiscpython-399.pyc" ] \
  && ok "bytecode not placed by install.sh: reported and left, everything else removed" || { bad "runtime bytecode: exit $rc"; echo "$out" | tail -8; }
rm -rf "$S"

S=$(mktemp -d /tmp/ad-roundtrip.XXXXXX); H=$S/home; mkdir -p "$H/.local/bin"; chmod 555 "$H/.local/bin"
E=(env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" PATH="$H/.local/bin:$PATH")
out=$("${E[@]}" "$REPO/install.sh" --no-start 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q '^FAILED:' && echo "$out" | grep -q 'copy failed\|temp file' \
  && ok "unwritable bin dir: exit 1, FAILED listed" || { bad "unwritable bin: exit $rc"; echo "$out" | tail -12; }
"${E[@]}" "$REPO/uninstall.sh" >/dev/null 2>&1; chmod 755 "$H/.local/bin"; rm -rf "$S"

# --start in a scratch HOME: the real user manager cannot see the unit (only the read-only
# `systemctl --user show -p UnitPath` is called), so it must fail rather than claim it started.
S=$(mktemp -d /tmp/ad-roundtrip.XXXXXX); H=$S/home; mkdir -p "$H"
E=(env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" PATH="$H/.local/bin:$PATH")
out=$("${E[@]}" "$REPO/install.sh" --start 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q 'FAILED: --start asked for' && ! echo "$out" | grep -q '^Done' \
  && ok "--start where systemd cannot see the unit: exit 1, reported" || { bad "--start unseen unit: exit $rc"; echo "$out" | tail -8; }
"${E[@]}" "$REPO/uninstall.sh" >/dev/null 2>&1
[ -z "$(find "$H" -mindepth 1)" ] && ok "uninstall after it leaves nothing" || bad "left after --start test: $(find "$H" -mindepth 1)"
rm -rf "$S"

# The shim stands in for systemctl: it claims the scratch unit dir is on the unit path and succeeds
# or fails `enable`, so the real user manager is never called.
mk_shim() {  # mk_shim DIR HOME ENABLE_RC
  {
    echo '#!/bin/sh'
    echo "echo \"\$*\" >>'$1/shim.log'"
    echo 'case "$*" in'
    echo "  *'-p UnitPath'*) echo '$2/.config/systemd/user' ;;"
    echo "  *'-p FragmentPath'*) echo '$2/.config/systemd/user/$UNIT' ;;"
    echo "  *enable*) [ $3 = 0 ] || { echo 'Failed to enable unit: shim says no' >&2; exit 1; } ;;"
    echo 'esac'
    echo 'exit 0'
  } >"$1/systemctl"
  chmod +x "$1/systemctl"
}
S=$(mktemp -d /tmp/ad-roundtrip.XXXXXX); H=$S/home; mkdir -p "$H" "$S/shim"; mk_shim "$S/shim" "$H" 0
E=(env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" PATH="$S/shim:$H/.local/bin:$PATH")
out=$("${E[@]}" "$REPO/install.sh" --start 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q 'enabled and started' && echo "$out" | grep -q '^Done' && grep -q 'enable --now' "$S/shim/shim.log" \
  && ok "--start with a working systemctl (shim): exit 0, enable --now called, Done" || { bad "--start happy path: exit $rc"; echo "$out" | tail -8; }
"${E[@]}" "$REPO/uninstall.sh" >/dev/null 2>&1; rm -rf "$S"

# --start whose systemctl enable fails (shim).
S=$(mktemp -d /tmp/ad-roundtrip.XXXXXX); H=$S/home; mkdir -p "$H" "$S/shim"; mk_shim "$S/shim" "$H" 1
E=(env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" PATH="$S/shim:$H/.local/bin:$PATH")
out=$("${E[@]}" "$REPO/install.sh" --start 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q 'FAILED to enable and start' && ! echo "$out" | grep -q '^Done' \
  && ok "--start with failing systemctl enable: exit 1, reported" || { bad "--start failure: exit $rc"; echo "$out" | tail -8; }
out=$("${E[@]}" "$REPO/uninstall.sh" 2>&1); rc=$?
[ $rc = 0 ] && grep -q 'disable --now' "$S/shim/shim.log" && ok "uninstall disabled the unit through the shim" || bad "uninstall with shim: exit $rc"
rm -rf "$S"

# Module hooks, with a copy of the checkout holding two fake modules: one whose device is
# "present" (detect exit 0) and one whose device is absent (detect exit 1).
S=$(mktemp -d /tmp/ad-roundtrip.XXXXXX); H=$S/home; SRC=$S/src; mkdir -p "$H" "$SRC"
(cd "$REPO" && git ls-files -z | xargs -0 cp --parents -t "$SRC"); rm -rf "$SRC/modules"
for m in present absent; do
  mkdir -p "$SRC/modules/$m"
  rc=0; [ $m = absent ] && rc=1
  printf '#!/bin/sh\nexit %s\n' "$rc" >"$SRC/modules/$m/detect"
  printf '#!/bin/sh\nmkdir -p "$XDG_CONFIG_HOME/fake-%s" && touch "$XDG_CONFIG_HOME/fake-%s/on" && echo "%s pieces placed, bin=${XDG_BIN_HOME:-unset}"\n' $m $m $m >"$SRC/modules/$m/enable"
  printf '#!/bin/sh\nrm -rf "$XDG_CONFIG_HOME/fake-%s"; echo "%s pieces removed, bin=${XDG_BIN_HOME:-unset}"\n' $m $m >"$SRC/modules/$m/disable"
  chmod +x "$SRC/modules/$m/"*
done
E=(env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" PATH="$H/.local/bin:$PATH")
out=$("${E[@]}" "$SRC/install.sh" --no-start --bindir "$H/mybin" 2>&1); rc=$?
echo "$out" | sed -n '/^Modules:/,/^$/p' | sed 's/^/    | /'
[ $rc = 0 ] && echo "$out" | grep -qF "present pieces placed, bin=$H/mybin" && [ -f "$H/.config/fake-present/on" ] && [ ! -e "$H/.config/fake-absent" ] \
  && [ -x "$H/.local/share/audio-doctor/modules/present/disable" ] \
  && echo "$out" | grep -q 'Nothing in this kit restarts PipeWire' \
  && ok "modules copied; detect && enable ran for the present one only; PipeWire restart note printed; hooks got XDG_BIN_HOME = the --bindir dir" \
  || bad "module install: exit $rc"
out=$("${E[@]}" "$SRC/uninstall.sh" 2>&1); rc=$?
echo "$out" | grep -A1 '^Module' | sed 's/^/    | /'
[ $rc = 0 ] && echo "$out" | grep -qF "present pieces removed, bin=$H/mybin" && [ ! -e "$H/.config/fake-present" ] && [ -z "$(find "$H" -mindepth 1)" ] \
  && ok "uninstall ran disable for each module with XDG_BIN_HOME = the install bin dir, and left nothing behind" || { bad "module uninstall: exit $rc"; find "$H" -mindepth 1; }
out=$("${E[@]}" "$SRC/install.sh" --no-start 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -qF "present pieces placed, bin=$H/.local/bin" \
  && ok "default install: hooks get XDG_BIN_HOME=\$HOME/.local/bin" || bad "default hook env: exit $rc"
out=$("${E[@]}" "$SRC/uninstall.sh" 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -qF "present pieces removed, bin=$H/.local/bin" && [ -z "$(find "$H" -mindepth 1)" ] \
  && ok "default uninstall: disable got the same XDG_BIN_HOME, nothing left" || { bad "default uninstall: exit $rc"; find "$H" -mindepth 1; }
rm -rf "$S"

# A module whose disable fails: uninstall must exit 1, keep that module's installed copy and the
# manifest, and a second uninstall (after the cause is fixed) must finish the job.
S=$(mktemp -d /tmp/ad-roundtrip.XXXXXX); H=$S/home; SRC=$S/src; mkdir -p "$H" "$SRC"
(cd "$REPO" && git ls-files -z | xargs -0 cp --parents -t "$SRC"); rm -rf "$SRC/modules"
mkdir -p "$SRC/modules/stuck"
printf '#!/bin/sh\nexit 0\n' >"$SRC/modules/stuck/detect"
printf '#!/bin/sh\nmkdir -p "$XDG_CONFIG_HOME/fake-stuck" && touch "$XDG_CONFIG_HOME/fake-stuck/on" && echo placed\n' >"$SRC/modules/stuck/enable"
printf '#!/bin/sh\n[ -e "%s/fixed" ] || { echo "cannot remove pieces: simulated fault"; exit 1; }\nrm -rf "$XDG_CONFIG_HOME/fake-stuck"; echo removed\n' "$S" >"$SRC/modules/stuck/disable"
chmod +x "$SRC/modules/stuck/"*
E=(env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" PATH="$H/.local/bin:$PATH")
out=$("${E[@]}" "$SRC/install.sh" --no-start 2>&1); rc=$?
[ $rc = 0 ] && [ -f "$H/.config/fake-stuck/on" ] && ok "failing-disable module: installed and enabled" || bad "stuck module install: exit $rc"
out=$("${E[@]}" "$SRC/uninstall.sh" 2>&1); rc=$?
echo "$out" | sed -n '/^Module/,/^  [^ ]/p;/^FAILED:/,$p' | sed 's/^/    | /'
M=$H/.local/share/audio-doctor/install-manifest
[ $rc = 1 ] && echo "$out" | grep -q 'module stuck: disable exit 1' && ! echo "$out" | grep -q "removed $H/.local/share/audio-doctor/modules/stuck/" \
  && [ -x "$H/.local/share/audio-doctor/modules/stuck/disable" ] && [ -f "$M" ] && [ -f "$H/.config/fake-stuck/on" ] \
  && [ ! -e "$H/.local/bin/whatis" ] \
  && ok "disable failed: exit 1, FAILED listed, module copy and manifest kept, its pieces untouched, the rest removed" \
  || { bad "failing disable: exit $rc"; echo "$out" | tail -12; }
touch "$S/fixed"
out=$("${E[@]}" "$SRC/uninstall.sh" 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q 'Module stuck: disable exit 0' && [ -z "$(find "$H" -mindepth 1)" ] \
  && ok "second uninstall after the fault is fixed: disable ran again, exit 0, nothing left" || { bad "retry uninstall: exit $rc"; echo "$out" | tail -8; find "$H" -mindepth 1; }
rm -rf "$S"

# Hooks the installer did not place are never executed. Each fake hook below touches a marker file
# when it runs, so "not executed" is proven by the marker being absent, not by output alone.
mk_src() {  # mk_src DIR: a copy of the checkout with no modules/
  mkdir -p "$1"; (cd "$REPO" && git ls-files -z | xargs -0 cp --parents -t "$1"); rm -rf "$1/modules"
}
mk_mod() {  # mk_mod MODDIR TAG MARKDIR: detect exit 0, every hook touches MARKDIR/TAG-<hook>
  mkdir -p "$1"
  for h in detect enable disable status; do printf '#!/bin/sh\ntouch "%s/%s-%s"\nexit 0\n' "$3" "$2" "$h" >"$1/$h"; done
  chmod +x "$1"/*
}

# (a) A foreign module dir already sits where install.sh would copy the module: its files are not
#     overwritten, the module is reported, and neither the foreign nor the copied hooks run.
S=$(mktemp -d /tmp/ad-roundtrip.XXXXXX); H=$S/home; SRC=$S/src; MK=$S/marks; mkdir -p "$H" "$MK"; mk_src "$SRC"
mk_mod "$SRC/modules/clash" ours "$MK"
MD=$H/.local/share/audio-doctor/modules
mk_mod "$MD/clash" foreign "$MK"
E=(env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" PATH="$H/.local/bin:$PATH")
out=$("${E[@]}" "$SRC/install.sh" --no-start 2>&1); rc=$?
echo "$out" | sed -n '/^Modules:/,/^$/p' | sed 's/^/    | /'
[ $rc = 1 ] && echo "$out" | grep -q 'clash: NOT run' && [ -z "$(ls -A "$MK")" ] && grep -q foreign-detect "$MD/clash/detect" \
  && ! grep -qP '^m\t' "$H/.local/share/audio-doctor/install-manifest" \
  && ok "foreign module dir at install: exit 1, reported, files untouched, no m line, no hook executed (marker dir empty)" \
  || { bad "foreign module at install: exit $rc, markers: $(ls "$MK")"; echo "$out" | tail -12; }
out=$("${E[@]}" "$SRC/uninstall.sh" 2>&1); rc=$?
[ $rc = 0 ] && [ -z "$(ls -A "$MK")" ] && [ -x "$MD/clash/disable" ] && grep -q foreign-disable "$MD/clash/disable" \
  && echo "$out" | grep -q "clash/ (module directory install.sh did not place" \
  && ok "uninstall after it: foreign module not executed, not removed, listed" || { bad "foreign module at uninstall: exit $rc, markers: $(ls "$MK")"; echo "$out" | tail -12; }
rm -rf "$S"

# (b) A module dir the user added after install: uninstall lists it and never runs its disable.
# (c) A hook install.sh placed, changed after install: uninstall does not run it, keeps the module and
#     the manifest, exits 1; install.sh again restores it and the next uninstall finishes.
S=$(mktemp -d /tmp/ad-roundtrip.XXXXXX); H=$S/home; SRC=$S/src; MK=$S/marks; mkdir -p "$H" "$MK"; mk_src "$SRC"
mk_mod "$SRC/modules/real" ours "$MK"
MD=$H/.local/share/audio-doctor/modules
E=(env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" PATH="$H/.local/bin:$PATH")
out=$("${E[@]}" "$SRC/install.sh" --no-start 2>&1); rc=$?
[ $rc = 0 ] && [ -e "$MK/ours-detect" ] && [ -e "$MK/ours-enable" ] && grep -qP "^m\t$MD/real\t" "$H/.local/share/audio-doctor/install-manifest" \
  && ok "own module: detect and enable ran from the copy this run placed, m line recorded" || { bad "own module install: exit $rc"; echo "$out" | tail -8; }
rm -f "$MK"/*
mk_mod "$MD/useradded" user "$MK"
printf '#!/bin/sh\ntouch "%s/tampered-disable"\nexit 0\n' "$MK" >"$MD/real/disable"
out=$("${E[@]}" "$SRC/uninstall.sh" 2>&1); rc=$?
echo "$out" | sed 's/^/    | /' | grep -E 'Module|useradded|FAILED|real' | head -12
M=$H/.local/share/audio-doctor/install-manifest
[ $rc = 1 ] && [ -z "$(ls -A "$MK")" ] && echo "$out" | grep -q 'real: disable NOT run' \
  && echo "$out" | grep -q 'useradded/ (module directory install.sh did not place' && [ -x "$MD/useradded/disable" ] \
  && [ -f "$M" ] && [ -f "$MD/real/detect" ] && [ ! -e "$H/.local/bin/whatis" ] \
  && ok "user-added module and tampered hook: neither executed (marker dir empty), module and manifest kept, exit 1, the rest removed" \
  || { bad "user-added/tampered at uninstall: exit $rc, markers: $(ls "$MK")"; echo "$out" | tail -12; }
out=$("${E[@]}" "$SRC/install.sh" --no-start 2>&1); rc=$?
rm -f "$MK"/*
out=$("${E[@]}" "$SRC/uninstall.sh" 2>&1); rc=$?
[ $rc = 0 ] && [ -e "$MK/ours-disable" ] && [ ! -e "$MK/user-disable" ] && [ ! -e "$MK/tampered-disable" ] \
  && [ "$(cd "$H" && find . -mindepth 1 -type f | sort | tr '\n' ' ')" = "$(cd "$H" && find ./.local/share/audio-doctor/modules/useradded -type f | sort | tr '\n' ' ')" ] \
  && ok "after install.sh restored the hook: its own disable ran, the user module still not run and is all that is left" \
  || { bad "retry after tamper: exit $rc, markers: $(ls "$MK")"; echo "$out" | tail -12; find "$H" -mindepth 1 -type f; }
rm -rf "$S"

AFTER=$(real_snapshot)
echo; echo "== real install, after"; echo "$AFTER" | tilde
if [ "$BEFORE" = "$AFTER" ]; then ok "real install identical before and after (bin links, unit state and PID, skill dir)"
else bad "real install changed:"; diff <(echo "$BEFORE") <(echo "$AFTER") | tilde; fi

echo; [ $FAIL = 0 ] && echo "RESULT: PASS ($CYCLES cycles)" || echo "RESULT: FAIL"
exit $FAIL
