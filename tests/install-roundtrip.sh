#!/usr/bin/env bash
# tests/install-roundtrip.sh: install, use and uninstall the kit in a scratch HOME, N times
# (default 2), then prove the real user's install was not touched.
#
# Per cycle: seed user data (a state file and a saved report), install.sh --no-start, list every
# placed path, run each installed command from the scratch bin, install again (idempotent),
# uninstall.sh, and check that only the seeded user data is left. After the cycles: the failure
# paths (a foreign file in the way, an unwritable bin dir, a failing `systemctl enable` through a
# PATH shim) must give exit 1, never "Done".
#
# Plays no audio and opens no stream: audio-doctor runs as `--audit` (config only) and
# omarchy-audio-audit, which starts a full measured run with any argument, is only parsed.
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
  if "${E[@]}" python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$H/.local/bin/omarchy-audio-audit" \
     && head -1 "$H/.local/bin/omarchy-audio-audit" | grep -q python3; then
    ok "omarchy-audio-audit parses (not run: any argument starts a measured run with a stream; audio hold)"
  else bad "omarchy-audio-audit does not parse"; fi

  # Files the commands themselves wrote while running (for example libpulse's ~/.config/pulse/cookie):
  # user data, not installed, so uninstall must keep them. Python bytecode next to the commands is the
  # exception: uninstall.sh removes it.
  RUNTIME=$( (cd "$H" && find . \( -type f -o -type l \) | sort) | grep -vxF -f <(echo "$POSTINST") | grep -v '^\./\.local/bin/__pycache__/' )
  echo "  made by the commands at run time (not by install.sh): ${RUNTIME:-none}"
  EXPECT=$(printf '%s\n%s\n' "$SEED" "$RUNTIME" | grep -v '^$' | sort)

  out=$("${E[@]}" "$REPO/install.sh" --no-start 2>&1); rc=$?
  [ $rc = 0 ] && ok "second install.sh over the first: exit 0" || { bad "second install exit $rc"; echo "$out" | tail -8; }

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
  printf '#!/bin/sh\nrm -rf "$XDG_CONFIG_HOME/fake-%s"; echo "%s pieces removed"\n' $m $m >"$SRC/modules/$m/disable"
  chmod +x "$SRC/modules/$m/"*
done
E=(env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" PATH="$H/.local/bin:$PATH")
out=$("${E[@]}" "$SRC/install.sh" --no-start --bindir "$H/mybin" 2>&1); rc=$?
echo "$out" | sed -n '/^Modules:/,/^$/p' | sed 's/^/    | /'
[ $rc = 0 ] && echo "$out" | grep -qF "present pieces placed, bin=$H/mybin" && [ -f "$H/.config/fake-present/on" ] && [ ! -e "$H/.config/fake-absent" ] \
  && [ -x "$H/.local/share/audio-doctor/modules/present/disable" ] \
  && echo "$out" | grep -q 'Nothing in this kit restarts PipeWire' \
  && ok "modules copied; detect && enable ran for the present one only; PipeWire restart note printed; --bindir reached the hook as XDG_BIN_HOME" \
  || bad "module install: exit $rc"
out=$("${E[@]}" "$SRC/uninstall.sh" 2>&1); rc=$?
echo "$out" | grep '^Module' | sed 's/^/    | /'
[ $rc = 0 ] && [ ! -e "$H/.config/fake-present" ] && [ -z "$(find "$H" -mindepth 1)" ] \
  && ok "uninstall ran disable for each module and left nothing behind" || { bad "module uninstall: exit $rc"; find "$H" -mindepth 1; }
rm -rf "$S"

AFTER=$(real_snapshot)
echo; echo "== real install, after"; echo "$AFTER" | tilde
if [ "$BEFORE" = "$AFTER" ]; then ok "real install identical before and after (bin links, unit state and PID, skill dir)"
else bad "real install changed:"; diff <(echo "$BEFORE") <(echo "$AFTER") | tilde; fi

echo; [ $FAIL = 0 ] && echo "RESULT: PASS ($CYCLES cycles)" || echo "RESULT: FAIL"
exit $FAIL
