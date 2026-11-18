#!/bin/bash
# test-roundtrip.sh: proves the rme-adi2 module contract and the kit's RME gating. Exit 0 = every check passed, 1 = any failed.
# Plays no audio (no tone, no buffer sweep, no keepalive on/off) and never writes to the device: studio-keepalive
# is only asked for `status`. All placement goes into a scratch XDG tree; the live home is only read.
#
#   A  module cases that need no device: absent detect, unresolvable unit (nothing half-filled), unwritable manifest,
#      existing identical / different destination files.
#   B  present lifecycle (needs the ADI-2 on USB; SKIP otherwise, FAIL with --require-present): detect, enable twice,
#      status, status --json, generated loopback file, kit tools show RME rows, disable twice, exact removal.
#   C  absent state: a stub lsusb first on PATH reports no 2a39:3fd2 (detect itself has no test hook). Every kit tool's
#      gated path runs twice: no RME BREAK/WARN/error, at most one neutral line, exit 0.
#
# Kit tools are run from this checkout (the repo two levels up), never the installed copies.
set -u
MOD=$(cd "$(dirname "$(realpath "$0")")" && pwd)
REPO=$(cd "$MOD/../.." && pwd)
REQUIRE_PRESENT=0; [ "${1:-}" = --require-present ] && REQUIRE_PRESENT=1
T=$(mktemp -d "${TMPDIR:-/tmp}/rme-adi2-test.XXXXXX")
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
fails=0; passes=0
ok()   { passes=$((passes + 1)); echo "PASS  $*"; }
bad()  { fails=$((fails + 1)); echo "FAIL  $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

export XDG_CONFIG_HOME=$T/config XDG_DATA_HOME=$T/data XDG_BIN_HOME=$T/bin XDG_STATE_HOME=$T/state
mkdir -p "$T/config" "$T/data" "$T/bin" "$T/state" "$T/home"
WP=$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d/50-rme-adi2.conf
LB=$XDG_CONFIG_HOME/pipewire/pipewire.conf.d/50-rme-adi2-stereo.conf
KA=$XDG_BIN_HOME/studio-keepalive
# evidence output: no scratch paths, home, unit serial or usb id
mask() { sed -E "s|$T|<scratch>|g; s|$HOME|~|g; s/RME_ADI-2_Pro__[^\"]*-00\./RME_ADI-2_Pro__<serial>__<usb-id>-00./g; s/^/      /"; }
tree() { (cd "$T" && find config data bin -printf '%y %p\n' | sort); }
fresh() { rm -rf "$T/config" "$T/data" "$T/bin"; mkdir -p "$T/config" "$T/data" "$T/bin"; }

# stub dirs: absent (lsusb lists nothing for 2a39:3fd2), present-but-unresolvable (lsusb says present, udevadm and
# pw-dump know no ADI-2 unit)
mkdir -p "$T/stub-absent" "$T/stub-unresolved"
printf '#!/bin/sh\nexit 1\n' >"$T/stub-absent/lsusb"
printf '#!/bin/sh\necho "Bus 001 Device 009: ID 2a39:3fd2 RME ADI-2 Pro"\nexit 0\n' >"$T/stub-unresolved/lsusb"
printf '#!/bin/sh\nexit 0\n' >"$T/stub-unresolved/udevadm"
printf '#!/bin/sh\necho "[]"\n' >"$T/stub-unresolved/pw-dump"
chmod +x "$T"/stub-*/*
ABSENT_PATH=$T/stub-absent:$PATH

echo "== A: module cases (no device needed)"
out=$(PATH=$ABSENT_PATH "$MOD/detect"); rc=$?
check "A1 detect absent exits 1" [ $rc = 1 ]
check "A1 detect absent prints nothing" [ -z "$out" ]
out=$(PATH=$ABSENT_PATH "$MOD/status"); rc=$?
check "A2 status absent exits 0" [ $rc = 0 ]
check "A2 status lists 3 missing pieces" [ "$(grep -c ': missing ' <<<"$out")" = 3 ]
check "A2 status --json parses" bash -c "PATH='$ABSENT_PATH' '$MOD/status' --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d[\"pieces\"])==3'"

before=$(tree)
out=$(PATH=$T/stub-unresolved:$PATH "$MOD/enable"); rc=$?
check "A3 unresolvable unit: enable exits 1" [ $rc = 1 ]
check "A3 unresolvable unit: no loopback file written" bash -c "[ ! -e '$LB' ] && [ ! -e '$LB.rme-adi2.tmp' ]"
check "A3 unresolvable unit: reason printed" grep -q 'cannot resolve' <<<"$out"
PATH=$T/stub-unresolved:$PATH "$MOD/disable" >/dev/null; rc=$?
check "A3 disable after partial enable exits 0" [ $rc = 0 ]
check "A3 disable restores the tree exactly" [ "$(tree)" = "$before" ]

fresh; mkdir -p "$XDG_DATA_HOME/audio-doctor/module-state"; chmod 555 "$XDG_DATA_HOME/audio-doctor/module-state"
out=$("$MOD/enable" 2>&1); rc=$?
check "A4 unwritable manifest: enable exits 1" [ $rc = 1 ]
check "A4 unwritable manifest: no piece left on disk unrecorded" bash -c "[ ! -e '$WP' ] && [ ! -e '$LB' ] && [ ! -L '$KA' ]"
chmod 755 "$XDG_DATA_HOME/audio-doctor/module-state"; fresh

ln -s "$MOD/bin/studio-keepalive" "$KA"                              # identical, not placed by the module
mkdir -p "$(dirname "$WP")"; echo "# someone else's rule" >"$WP"      # different content
sum_wp=$(sha256sum <"$WP")
out=$(PATH=$T/stub-unresolved:$PATH "$MOD/enable"); rc=$?
check "A5 existing different file: enable exits 1" [ $rc = 1 ]
check "A5 existing different file: reason printed" grep -q 'wireplumber-rule: NOT placed: .*different content' <<<"$out"
check "A5 existing identical link: already present, identical, not managed" grep -q 'studio-keepalive: already present, identical, not managed' <<<"$out"
out=$(PATH=$T/stub-unresolved:$PATH "$MOD/status")
check "A5 status reports both as not the module's" bash -c "grep -q 'studio-keepalive: present-identical-not-managed' <<<\"\$1\" && grep -q 'wireplumber-rule: present-not-ours' <<<\"\$1\"" _ "$out"
"$MOD/disable" >/dev/null
check "A5 disable leaves the different file" [ "$(sha256sum <"$WP")" = "$sum_wp" ]
check "A5 disable leaves the identical unmanaged link" [ "$(readlink "$KA")" = "$MOD/bin/studio-keepalive" ]
fresh

echo "== B: present lifecycle"
if "$MOD/detect" >/dev/null; then
  ok "B1 detect exits 0: $("$MOD/detect")"
  before=$(tree)
  out=$("$MOD/enable"); rc=$?; echo "$out" | mask
  check "B2 enable exits 0" [ $rc = 0 ]
  check "B2 restart note printed" grep -q 'nothing in the kit restarts PipeWire' <<<"$out"
  check "B2 wireplumber rule placed" cmp -s "$WP" "$MOD/files/50-rme-adi2.conf"
  check "B2 loopback file placed" [ -f "$LB" ]
  check "B2 keepalive linked" [ "$(readlink "$KA")" = "$MOD/bin/studio-keepalive" ]
  check "B2 loopback file has no placeholder" bash -c "! grep -q '<serial>\|<usb-id>\|^#@' '$LB'"
  check "B2 loopback targets this unit" bash -c "[ \$(grep -c 'target.object = \"alsa_\(output\|input\)\.usb-RME_ADI-2_Pro__' '$LB') = 2 ]"
  check "B2 loopbacks keep dont-fallback + linger" bash -c "[ \$(grep -c 'node.dont-fallback = true' '$LB') = 2 ] && [ \$(grep -c 'node.linger = true' '$LB') = 2 ]"
  echo "      generated $LB (serial masked):"; mask <"$LB" | grep -n 'target.object\|dont-fallback\|linger' | sed 's/^/      /'
  out=$("$MOD/enable"); rc=$?
  check "B3 enable twice exits 0" [ $rc = 0 ]
  check "B3 enable twice: all 3 already placed, nothing new" [ "$(grep -c 'already placed by this module' <<<"$out")" = 3 ]
  out=$("$MOD/status"); echo "$out" | mask
  check "B4 status: device present" grep -q 'device: present' <<<"$out"
  check "B4 status: 3 placed" [ "$(grep -c ': placed ' <<<"$out")" = 3 ]
  check "B4 status --json: 3 placed" bash -c "'$MOD/status' --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert [p[\"state\"] for p in d[\"pieces\"]]==[\"placed\"]*3'"
  out=$("$KA" status); rc=$?
  check "B5 linked studio-keepalive status (read only) exits 0" [ $rc = 0 ]
  check "B5 linked studio-keepalive status sees the unit ($(head -1 <<<"$out"))" grep -qE 'ADI-2 on USB|adi2 not installed' <<<"$out"
  # kit tools in the present state: RME rows on (audio-doctor plain = graph read and level meter, no tone)
  out=$(env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME "$REPO/audio-doctor" --json); rc=$?
  check "B6 audio-doctor present: exit 0, rme_module on" bash -c "[ $rc = 0 ] && python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d[\"rme_module\"]==\"on\"' \"\$1\"" _ "$out"
  if command -v adi2 >/dev/null; then
    check "B6 audio-doctor present: RME device row read (adi2 dump)" python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["rme"] and "basic_mode" in d["rme"]' "$out"
  fi
  check "B6 config-audit present: RME streams audited (scratch drop-ins)" python3 - "$REPO" <<'EOF'
import importlib.machinery, importlib.util, os, sys
ld = importlib.machinery.SourceFileLoader("ca", os.path.join(sys.argv[1], "config-audit"))
ca = importlib.util.module_from_spec(importlib.util.spec_from_loader("ca", ld)); ld.exec_module(ca)
assert ca.rme_present()
f, files = ca.audit(rme=True)
assert any("50-rme-adi2-stereo.conf" in x for x in files), files
assert not any(x["message"] == ca.RME_OFF for x in f)
EOF
  check "B6 omarchy-audio-audit present: sweep gate routes as usual (stream not opened)" python3 - "$REPO" <<'EOF'
import importlib.machinery, importlib.util, os, sys
ld = importlib.machinery.SourceFileLoader("oa", os.path.join(sys.argv[1], "omarchy-audio-audit"))
oa = importlib.util.module_from_spec(importlib.util.spec_from_loader("oa", ld)); ld.exec_module(oa)
assert oa.rme_present()
assert oa.sweep_gate({"hardware_sink": "alsa_output.x"}, True) == (None, None)
b, n = oa.sweep_gate({"hardware_sink": None, "waits_for": "alsa_output.usb-RME_ADI-2_Pro__x-00.pro-output-0"}, True)
assert n and "routing broken" in n
EOF
  check "B6 omarchy-audio-watch present: RME xrun rows counted" env HOME="$T/home" python3 - "$REPO" <<'EOF'
import importlib.machinery, importlib.util, os, sys
ld = importlib.machinery.SourceFileLoader("ow", os.path.join(sys.argv[1], "omarchy-audio-watch"))
ow = importlib.util.module_from_spec(importlib.util.spec_from_loader("ow", ld)); ld.exec_module(ow)
assert ow.rme_present()
rows = ow.pw_errs()
assert any("RME_ADI" in k for k in rows), rows
EOF
  # config-audit with the module off against the scratch dir that holds the RME drop-ins: zero WARN rows
  check "B7 config-audit audit(rme=False) on the RME drop-ins: 0 WARN/BREAK, one neutral row" python3 - "$REPO" <<'EOF'
import importlib.machinery, importlib.util, os, sys
ld = importlib.machinery.SourceFileLoader("ca", os.path.join(sys.argv[1], "config-audit"))
ca = importlib.util.module_from_spec(importlib.util.spec_from_loader("ca", ld)); ld.exec_module(ca)
f, files = ca.audit(rme=False)
assert any("50-rme-adi2-stereo.conf" in x for x in files), files
bad = [x for x in f if x["severity"] in ("WARN", "BREAK") and ("rme" in x["message"].lower() or "rme-adi2" in x["file"])]
assert not bad, bad
assert sum(x["message"] == ca.RME_OFF for x in f) == 1
EOF
  out=$("$MOD/disable"); rc=$?; echo "$out" | mask
  check "B8 disable exits 0" [ $rc = 0 ]
  out=$("$MOD/disable"); rc=$?
  check "B8 disable twice exits 0" [ $rc = 0 ]
  check "B8 disable twice: nothing left to remove" grep -q 'nothing placed by this module' <<<"$out"
  check "B8 disable removed exactly what enable placed (tree identical to before enable)" [ "$(tree)" = "$before" ]
elif [ $REQUIRE_PRESENT = 1 ]; then
  bad "B present lifecycle: ADI-2 not on USB (wake it with its button)"
else
  echo "SKIP  B present lifecycle: ADI-2 not on USB (run with the device awake; --require-present makes this a failure)"
fi

echo "== C: absent state (stub lsusb on PATH: no 2a39:3fd2), each tool twice"
# kit tools read the live graph and live config (read only); their state writes go to the scratch HOME where they have one
# stdin: tool output. True when no line about the RME (other than the neutral one) is a BREAK, WARN or error
normebad() { ! grep -iE 'rme|adi-?2' | grep -v 'no RME ADI-2: module off' | grep -qE 'BREAK|WARN|ERROR|Traceback|error'; }
noerr() { ! grep -qE 'Traceback|Error'; }
for i in 1 2; do
  out=$(env -u XDG_CONFIG_HOME -u XDG_DATA_HOME PATH="$ABSENT_PATH" "$REPO/audio-doctor" 2>&1); rc=$?
  check "C$i audio-doctor: exit 0" [ $rc = 0 ]
  check "C$i audio-doctor: no RME BREAK/WARN/error" normebad <<<"$out"
  check "C$i audio-doctor: at most one neutral line" [ "$(grep -c 'module off' <<<"$out")" -le 1 ]
  out=$(env -u XDG_CONFIG_HOME -u XDG_DATA_HOME PATH="$ABSENT_PATH" "$REPO/audio-doctor" --json 2>&1); rc=$?
  check "C$i audio-doctor --json: module off, no RME finding" python3 -c '
import json,sys; d=json.loads(sys.argv[1]); assert d["rme_module"]=="off" and d["rme"] is None
bad=[f for f in d["findings"] if f["severity"] in ("BREAK","WARN") and ("rme" in f["message"].lower() or "adi-2" in f["message"].lower())]
assert not bad, bad
# streams into ADI-2 sinks: their findings carry the app label, not "RME", so match on the stream tag
rme_sinks = {n for n, v in d["sinks"].items() if "RME_ADI-2" in n or any("RME_ADI-2" in h for h in (v.get("feeds_hardware") or []))}
into = [s for s in d["streams"] if s.get("sink") in rme_sinks]
tags = [s["label"] + " [" + s["media"][:40] + "]" for s in into]
hit = [f for f in d["findings"] if any(f["message"].startswith(t) for t in tags)]
assert not hit, hit
print(f"      ({len(rme_sinks)} lingering ADI-2 sinks, {len(into)} streams into them: no finding for any of them)")' "$out"
  check "C$i audio-doctor: lingering ADI-2 sinks are in the skipped (module off) set" python3 - "$REPO" <<'EOF'
import importlib.machinery, importlib.util, os, sys
ld = importlib.machinery.SourceFileLoader("ad", os.path.join(sys.argv[1], "audio-doctor"))
ad = importlib.util.module_from_spec(importlib.util.spec_from_loader("ad", ld)); ld.exec_module(ad)
hw = "alsa_output.usb-RME_ADI-2_Pro__x-00.pro-output-0"
sinks = {"rme_phones": {"mute": True}, hw: {}, "alsa_output.pci-0000.hdmi": {}}
by_name = {"rme_phones.out": {"props": {"target.object": hw}}}
assert ad.rme_sinks(sinks, by_name) == {"rme_phones", hw}
EOF
  out=$(env -u XDG_CONFIG_HOME -u XDG_DATA_HOME PATH="$ABSENT_PATH" "$REPO/config-audit" 2>&1); rc=$?
  check "C$i config-audit: exit 0" [ $rc = 0 ]
  check "C$i config-audit: no RME BREAK/WARN/error" normebad <<<"$out"
  check "C$i config-audit: at most one neutral line" [ "$(grep -c 'module off' <<<"$out")" -le 1 ]
  out=$(PATH="$ABSENT_PATH" "$REPO/whatis" --audio 2>&1); rc=$?
  check "C$i whatis --audio: exit 0" [ $rc = 0 ]
  check "C$i whatis --audio: no RME error" normebad <<<"$out"
  out=$(env HOME="$T/home" PATH="$ABSENT_PATH" "$REPO/audit/footprint" rme-test-$i --secs 2 2>&1); rc=$?
  check "C$i audit/footprint: exit 0" [ $rc = 0 ]
  check "C$i audit/footprint: no RME error, no traceback" bash -c '! grep -qE "Traceback|RME.*(BREAK|WARN|rror)"' <<<"$out"
  out=$(PATH="$ABSENT_PATH" "$REPO/audit/studio-keepalive" status 2>&1); rc=$?
  check "C$i studio-keepalive status: exit 0" [ $rc = 0 ]
  check "C$i studio-keepalive status: one neutral line ($out)" [ "$(wc -l <<<"$out")" = 1 ]
  check "C$i omarchy-audio-watch: RME xrun rows dropped (pw_errs sample)" env HOME="$T/home" PATH="$ABSENT_PATH" python3 - "$REPO" <<'EOF'
import importlib.machinery, importlib.util, os, sys
ld = importlib.machinery.SourceFileLoader("ow", os.path.join(sys.argv[1], "omarchy-audio-watch"))
ow = importlib.util.module_from_spec(importlib.util.spec_from_loader("ow", ld)); ld.exec_module(ow)
assert not ow.rme_present()
rows = ow.pw_errs()
assert not any("RME_ADI" in k for k in rows), rows
EOF
  # omarchy-audio-audit opens a playback stream (buffer sweep): its RME gating is checked with the stream path not
  # run: detect result, the sweep gate (no extra line), power rows, keepalive off, and the single RME_OFF print.
  check "C$i omarchy-audio-audit: gated path (stream not opened): off, one line, no RME rows" env HOME="$T/home" PATH="$ABSENT_PATH" python3 - "$REPO" <<'EOF'
import importlib.machinery, importlib.util, os, re, sys
src = os.path.join(sys.argv[1], "omarchy-audio-audit")
ld = importlib.machinery.SourceFileLoader("oa", src)
oa = importlib.util.module_from_spec(importlib.util.spec_from_loader("oa", ld)); ld.exec_module(oa)
assert not oa.rme_present()
b, n = oa.sweep_gate({"hardware_sink": None, "waits_for": "alsa_output.usb-RME_ADI-2_Pro__x-00.pro-output-0"}, False)
assert b and n is None and not re.search(r"ADI|RME|module off", b), (b, n)
oa.RME_ON = False
dump = oa.pw_dump()
rows = oa.power_settings(dump, oa.interface_chain(dump))
# the RME module row is the auto-standby one; generic interface rows (USB power, controller) follow whatever the
# default interface is and are not module rows
assert not any(r["name"] == "RME ADI-2 auto-standby" for r in rows), "RME auto-standby row present while off"
text = open(src).read()
assert len(re.findall(r"print\(RME_OFF", text)) == 1, "RME_OFF printed more than once"
assert not re.search(r"(emit|print|notes\.append)\([^)]*module off", text), "a second module-off line"
assert "ka = RME_ON and" in text
EOF
done

echo "== $passes passed, $fails failed"
[ $fails = 0 ] && exit 0 || exit 1
