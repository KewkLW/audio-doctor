#!/bin/bash
# test-roundtrip.sh [--require-present] [--evidence DIR]: proves the rme-adi2 module contract and the kit's RME gating.
# Exit 0 = every check passed, 1 = any failed.
#
# AUDIO HOLD: plays no audio. No tone, no buffer sweep, no keepalive on/off, nothing ever writes to the device (adi2 is
# only read through audio-doctor's dump and studio-keepalive status). omarchy-audio-audit is NOT executed: it opens a
# playback stream (pw-cat silence + buffer sweep). Its RME gating is tested by calling its gating code (rme_present,
# sweep_gate, rme_scrub, power_settings) with the stream path stubbed out, labelled "STUBBED" below.
#
#   L  live safety: sha256 of every live PipeWire/WirePlumber drop-in and the PipeWire/WirePlumber PIDs, taken before
#      everything and compared after everything; any difference fails. --evidence DIR writes live-before.sha,
#      live-after.sha and the full run output (run-<time>[-require-present].log) there. All placement goes into a
#      scratch XDG tree; the live config is only read.
#   A  module cases that need no device: absent detect, unresolvable unit (nothing half-filled), unwritable manifest,
#      existing identical / different destination files.
#   B  present lifecycle on the real unit: detect 0, enable twice into scratch dirs, status, status --json, generated
#      loopback file, the real kit tools showing their RME rows, disable twice, exact removal. Without the device:
#      SKIP by default (laptop / standby runs), FAIL with --require-present.
#   C  absent state: a stub lsusb first on PATH reports no 2a39:3fd2 (detect itself has no test hook). The real kit
#      tools run end to end twice each: audio-doctor (text and --json), config-audit (live config, and the scratch dir
#      holding the RME drop-ins, and one file mixing the RME loopbacks with an unrelated faulty stream, which must still
#      be reported), whatis --audio, omarchy-audio-watch (one real sample), audit/footprint (text and saved JSON),
#      studio-keepalive status. A stale rme_phones default whose nodes are gone is SIMULATED with pass-through
#      pactl/pw-dump stubs that hide the ADI-2 and module nodes. No RME row, BREAK, WARN or error; at most one neutral
#      line; exit 0. audio-doctor --tone is NOT executed (audio hold): its gates are checked in the source.
#
# Kit tools are run from this checkout (the repo two levels up), never the installed copies.
set -u
MOD=$(cd "$(dirname "$(realpath "$0")")" && pwd)
REPO=$(cd "$MOD/../.." && pwd)
REQUIRE_PRESENT=0 EVID=
while [ $# -gt 0 ]; do
  case "$1" in
    --require-present) REQUIRE_PRESENT=1 ;;
    --evidence) EVID=${2:?--evidence DIR}; shift ;;
    *) echo "usage: $0 [--require-present] [--evidence DIR]"; exit 1 ;;
  esac; shift
done
if [ -n "$EVID" ]; then  # the full run output is saved too: DIR/run-<time>.log
  mkdir -p "$EVID" || exit 1
  exec > >(tee "$EVID/run-$(date +%Y%m%d-%H%M%S)$([ $REQUIRE_PRESENT = 1 ] && echo -require-present).log") 2>&1
fi
LIVE_CONF=${XDG_CONFIG_HOME:-$HOME/.config}
T=$(mktemp -d "${TMPDIR:-/tmp}/rme-adi2-test.XXXXXX")
WPID=
cleanup() { [ -n "$WPID" ] && kill "$WPID" 2>/dev/null; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
fails=0; passes=0
ok()   { passes=$((passes + 1)); echo "PASS  $*"; }
bad()  { fails=$((fails + 1)); echo "FAIL  $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

# unit identity, only to mask it in the output (ID_SERIAL = RME_ADI-2_Pro__<serial>__<usb-id>)
SER= UID_=
if idser=$(. "$MOD/lib.sh"; id_serial 2>/dev/null); then
  SER=$(sed 's/^RME_ADI-2_Pro__\([^_]*\)__.*/\1/' <<<"$idser"); UID_=$(sed 's/^.*__//' <<<"$idser")
fi
mask() {
  sed -E "s|$T|<scratch>|g; s|$HOME|~|g; ${SER:+s/$SER/<serial>/g;} ${UID_:+s/$UID_/<usb-id>/g;} s/(RME_ADI-2_Pro__)[^_ .\"<]+/\1<serial>/g; s/^/      /"
}

# ---- L: live state before anything runs
live_sums() { find "$LIVE_CONF/pipewire/pipewire.conf.d" "$LIVE_CONF/wireplumber/wireplumber.conf.d" -maxdepth 1 -type f \
                -exec sha256sum {} + 2>/dev/null | sort -k2 | sed "s|$HOME|~|"; }
pids() { for u in pipewire pipewire-pulse wireplumber; do echo "$u $(systemctl --user show -p MainPID --value $u 2>/dev/null)"; done; }
LIVE_BEFORE=$(live_sums); PIDS_BEFORE=$(pids)
echo "== L: live drop-ins before"; echo "${LIVE_BEFORE:-(none)}" | sed 's/^/      /'; echo "$PIDS_BEFORE" | sed 's/^/      /'
if [ -n "$EVID" ]; then mkdir -p "$EVID" && echo "$LIVE_BEFORE" >"$EVID/live-before.sha"; fi

export XDG_CONFIG_HOME=$T/config XDG_DATA_HOME=$T/data XDG_BIN_HOME=$T/bin XDG_STATE_HOME=$T/state
mkdir -p "$T/config" "$T/data" "$T/bin" "$T/state" "$T/home"
WP=$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d/50-rme-adi2.conf
LB=$XDG_CONFIG_HOME/pipewire/pipewire.conf.d/50-rme-adi2-stereo.conf
KA=$XDG_BIN_HOME/studio-keepalive
# config/pulse is pactl's own cookie (written when a kit tool calls pactl with the scratch XDG_CONFIG_HOME), not the module's
tree() { (cd "$T" && find config data bin -path config/pulse -prune -o -printf '%y %p\n' | sort); }
fresh() { rm -rf "$T/config" "$T/data" "$T/bin"; mkdir -p "$T/config" "$T/data" "$T/bin"; }
# kit tools see the live graph and the live config dir (read only) unless a test points XDG_CONFIG_HOME at scratch
live() { env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME "$@"; }

# stub dirs: absent (lsusb lists nothing for 2a39:3fd2), present-but-unresolvable (lsusb says present, udevadm and
# pw-dump know no ADI-2 unit)
mkdir -p "$T/stub-absent" "$T/stub-unresolved"
printf '#!/bin/sh\nexit 1\n' >"$T/stub-absent/lsusb"
printf '#!/bin/sh\necho "Bus 001 Device 009: ID 2a39:3fd2 RME ADI-2 Pro"\nexit 0\n' >"$T/stub-unresolved/lsusb"
printf '#!/bin/sh\nexit 0\n' >"$T/stub-unresolved/udevadm"
printf '#!/bin/sh\necho "[]"\n' >"$T/stub-unresolved/pw-dump"
chmod +x "$T"/stub-*/*
ABSENT_PATH=$T/stub-absent:$PATH
# stale default (SIMULATED): pactl and pw-dump pass through to the real tools (read only) but hide every ADI-2 node and
# every module loopback node (rme_phones, rme_in, ...), and pactl names rme_phones as the default sink: the module is
# off, its loopback default lingers in the settings, its nodes are gone
mkdir -p "$T/stub-stale"
for tool in pactl pw-dump; do
  real=$(command -v $tool) || continue
  cat >"$T/stub-stale/$tool" <<STUB
#!/usr/bin/env python3
import json, re, subprocess, sys
RME = re.compile(r'RME_ADI|"rme_(phones|in)(\\.out|\\.cap)?"|\\brme_(phones|in)(\\.out|\\.cap)?\\b')
args = sys.argv[1:]
if "$tool" == "pactl" and args == ["get-default-sink"]:
    print("rme_phones"); sys.exit(0)
r = subprocess.run(["$real"] + args, capture_output=True, text=True)
try:
    data = json.loads(r.stdout)
except ValueError:
    sys.stdout.write(r.stdout); sys.stderr.write(r.stderr); sys.exit(r.returncode)
if isinstance(data, list):
    data = [o for o in data if not (isinstance(o, dict) and o.get("type") != "PipeWire:Interface:Metadata" and RME.search(json.dumps(o)))]
print(json.dumps(data)); sys.exit(r.returncode)
STUB
done
chmod +x "$T"/stub-stale/*
STALE_PATH=$T/stub-stale:$ABSENT_PATH

# one real omarchy-audio-watch sample (its sampler loop, scratch HOME), stopped by the PID started here.
# prints the sample's JSON line
watch_sample() {
  local h=$T/home-watch-$1 f i
  rm -rf "$h"; mkdir -p "$h"
  env HOME="$h" PATH="$2" "$REPO/omarchy-audio-watch" run --interval 60 >"$h/out.log" 2>&1 & WPID=$!
  for i in $(seq 1 60); do
    f=$(ls "$h"/.local/state/omarchy-studio/watch/2*.jsonl 2>/dev/null | head -1)
    [ -n "$f" ] && [ -s "$f" ] && break
    kill -0 "$WPID" 2>/dev/null || break
    sleep 0.5
  done
  kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; WPID=
  if grep -q Traceback "$h/out.log"; then cat "$h/out.log"; return 1; fi
  [ -n "$f" ] && head -1 "$f"
}
# python check on a JSON document in $1 with the expression in $2 (d = the document)
jcheck() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); $2" "$1"; }
jrc() { [ "$1" = 0 ] && jcheck "$2" "$3"; }
# the watch sample also holds NVMe serials: show only the audio fields
wshow() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print("      sample:", {k: d.get(k) for k in ("ts","activity","xruns","xrun_rme_nodes")})' "$1" 2>/dev/null; }

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

echo "== B: present lifecycle (real unit, real kit tools)"
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
  echo "      generated <scratch>/config/pipewire/pipewire.conf.d/50-rme-adi2-stereo.conf (serial and usb id masked):"
  mask <"$LB"
  out=$("$MOD/enable"); rc=$?
  check "B3 enable twice exits 0" [ $rc = 0 ]
  check "B3 enable twice: all 3 already placed, nothing new" [ "$(grep -c 'already placed by this module' <<<"$out")" = 3 ]
  out=$("$MOD/status"); echo "$out" | mask
  check "B4 status: device present" grep -q 'device: present' <<<"$out"
  check "B4 status: 3 placed" [ "$(grep -c ': placed ' <<<"$out")" = 3 ]
  out=$("$MOD/status" --json)
  check "B4 status --json: 3 placed" jcheck "$out" 'assert [p["state"] for p in d["pieces"]]==["placed"]*3'
  out=$("$KA" status); rc=$?; echo "$out" | mask
  check "B5 linked studio-keepalive status (read only) exits 0" [ $rc = 0 ]
  check "B5 linked studio-keepalive status sees the unit" grep -qE 'ADI-2 on USB|adi2 not installed' <<<"$out"
  # the real kit tools, present: RME rows on. audio-doctor plain = graph read + level meter, no tone.
  out=$(live "$REPO/audio-doctor" 2>&1); rc=$?; echo "$out" | mask
  check "B6 audio-doctor: exit 0" [ $rc = 0 ]
  check "B6 audio-doctor: no module-off line" bash -c '! grep -q "module off" <<<"$1"' _ "$out"
  check "B6 audio-doctor: an ADI-2 sink row is printed" grep -q 'ADI-2' <<<"$(sed -n '/^sinks (measured)/,/^app streams/p' <<<"$out")"
  if command -v adi2 >/dev/null; then
    check "B6 audio-doctor: RME ADI-2 device row (read-only adi2 dump)" grep -q '^RME ADI-2: mode ' <<<"$out"
  fi
  out=$(live "$REPO/audio-doctor" --json 2>&1); rc=$?
  check "B6 audio-doctor --json: exit 0, rme_module on, ADI-2 sinks metered" jrc $rc "$out" '
assert d["rme_module"]=="on"
assert any("RME_ADI-2" in n or "ADI-2" in str(v.get("desc")) for n, v in d["sinks"].items()), list(d["sinks"])'
  # config-audit against the scratch config dir that holds the enabled drop-ins
  out=$(PATH=$PATH XDG_CONFIG_HOME=$T/config "$REPO/config-audit" 2>&1); rc=$?; echo "$out" | mask
  check "B7 config-audit (scratch drop-ins, module on): exit 0, reads the placed drop-ins, no module-off line" \
    bash -c '[ "$1" = 0 ] && grep -qF "$3/config/pipewire/pipewire.conf.d/50-rme-adi2-stereo.conf" <<<"$2" && ! grep -q "module off" <<<"$2"' _ $rc "$out" "$T"
  # the same scratch config dir with the module off (stub lsusb): the whole RME check set is skipped, one neutral line
  out=$(PATH=$ABSENT_PATH XDG_CONFIG_HOME=$T/config "$REPO/config-audit" 2>&1); rc=$?; echo "$out" | mask
  check "B7 config-audit (scratch RME drop-ins, module off): exit 0, 0 WARN/BREAK, exactly one neutral line" \
    bash -c '[ "$1" = 0 ] && ! grep -qE "\[(WARN|BREAK)" <<<"$2" && [ "$(grep -c "no RME ADI-2: module off" <<<"$2")" = 1 ]' _ $rc "$out"
  out=$(watch_sample present "$PATH"); rc=$?; wshow "$out"
  check "B8 omarchy-audio-watch one real sample: RME xrun rows counted" jrc $rc "$out" 'assert d["xrun_rme_nodes"] > 0, d.get("xrun_rme_nodes")'
  out=$(live "$REPO/whatis" --audio 2>&1); rc=$?
  check "B9 whatis --audio: exit 0" [ $rc = 0 ]
  check "B10 omarchy-audio-audit (STUBBED: not executed, audio hold): present gate routes as usual" env HOME="$T/home" python3 - "$REPO" <<'EOF'
import importlib.machinery, importlib.util, os, sys
ld = importlib.machinery.SourceFileLoader("oa", os.path.join(sys.argv[1], "omarchy-audio-audit"))
oa = importlib.util.module_from_spec(importlib.util.spec_from_loader("oa", ld)); ld.exec_module(oa)
assert oa.rme_present()
hw = "alsa_output.usb-RME_ADI-2_Pro__x-00.pro-output-0"
assert oa.sweep_gate({"default_sink": hw, "hardware_sink": hw, "waits_for": None}, True) == (None, None)
c = {"default_sink": "rme_phones", "hardware_sink": hw, "waits_for": hw}
assert oa.rme_scrub(c, True) == c
oa.RME_ON = True
dump = oa.pw_dump()
rows = oa.power_settings(dump, oa.interface_chain(dump))
assert any(r["name"] == "RME ADI-2 auto-standby" for r in rows), "no RME auto-standby row while on"
EOF
  out=$("$MOD/disable"); rc=$?; echo "$out" | mask
  check "B11 disable exits 0" [ $rc = 0 ]
  out=$("$MOD/disable"); rc=$?
  check "B11 disable twice exits 0" [ $rc = 0 ]
  check "B11 disable twice: nothing left to remove" grep -q 'nothing placed by this module' <<<"$out"
  after=$(tree)
  check "B11 disable removed exactly what enable placed (tree identical to before enable)" [ "$after" = "$before" ]
  [ "$after" = "$before" ] || diff <(echo "$before") <(echo "$after") | mask
elif [ $REQUIRE_PRESENT = 1 ]; then
  bad "B present lifecycle: --require-present and the ADI-2 is not on USB (wake it with its button)"
else
  echo "SKIP  B present lifecycle: ADI-2 not on USB. This run does NOT prove the present state; --require-present makes it a failure."
fi

echo "== C: absent state (stub lsusb first on PATH: no 2a39:3fd2), real tools end to end, each twice"
# put the RME drop-ins into the scratch config dir (copies of what enable places) for the config-audit module-off run
fresh; mkdir -p "$(dirname "$WP")" "$(dirname "$LB")"
cp "$MOD/files/50-rme-adi2.conf" "$WP"
sed '/^#@/d; s|RME_ADI-2_Pro__<serial>__<usb-id>|RME_ADI-2_Pro__0000__0000|' "$MOD/files/50-rme-adi2-stereo.conf.in" >"$LB"
# a second scratch config dir: ONE file holding the RME loopbacks and an unrelated loopback with a known fault
# (node.dont-reconnect): while the module is off only the RME streams are skipped, the unrelated one is still checked
MIX=$T/config-mixed/pipewire/pipewire.conf.d/60-mixed.conf; mkdir -p "$(dirname "$MIX")"
{ sed '/^#@/d; s|RME_ADI-2_Pro__<serial>__<usb-id>|RME_ADI-2_Pro__0000__0000|; $d' "$MOD/files/50-rme-adi2-stereo.conf.in"
  cat <<'CONF'
  { name = libpipewire-module-loopback
    args = {
      capture.props = { node.name = "other_sink" media.class = "Audio/Sink" }
      playback.props = { node.name = "other_out" target.object = "alsa_output.pci-0000_00_00.0.analog-stereo" node.dont-reconnect = true }
    }
  }
]
CONF
} >"$MIX"
# stdin: tool text output. True when no line names the RME / ADI-2 other than the one neutral line
nor() { ! grep -iE 'rme|adi-?2' | grep -v 'no RME ADI-2: module off' | grep -v 'rme-adi2.*\.conf$' | grep -q .; }
nobad() { ! grep -qE 'Traceback|\[(BREAK|WARN)'; }
for i in 1 2; do
  out=$(live env PATH="$ABSENT_PATH" "$REPO/audio-doctor" 2>&1); rc=$?; [ $i = 1 ] && echo "$out" | mask
  check "C$i audio-doctor: exit 0" [ $rc = 0 ]
  check "C$i audio-doctor: no RME row, finding or error (only the neutral line)" nor <<<"$out"
  check "C$i audio-doctor: exactly one neutral line" [ "$(grep -c 'no RME ADI-2: module off' <<<"$out")" = 1 ]
  check "C$i audio-doctor: no traceback" bash -c '! grep -q Traceback <<<"$1"' _ "$out"
  out=$(live env PATH="$ABSENT_PATH" "$REPO/audio-doctor" --json 2>&1); rc=$?
  check "C$i audio-doctor --json: exit 0, module off, no ADI-2 sink/stream/hardware/finding" jrc $rc "$out" '
assert d["rme_module"]=="off" and d["rme"] is None
rme = lambda x: "RME_ADI-2" in str(x) or "ADI-2" in str(x)
assert not [n for n, v in d["sinks"].items() if rme(n) or rme(v.get("desc")) or any(rme(h) for h in v.get("feeds_hardware") or [])], d["sinks"]
assert not [s for s in d["streams"] if rme(s.get("sink")) or any(rme(x) for x in s.get("linked_to") or [])], d["streams"]
assert not [u for u in d["hardware"]["usb_audio"] if rme(u)]
assert not [f for f in d["findings"] if f["severity"] in ("BREAK","WARN") or rme(f["message"]) or rme(f.get("fix"))], d["findings"]
# the whole document: no ADI-2 name anywhere (only the rme/rme_module keys)
import re; doc = json.dumps({k: v for k, v in d.items() if k not in ("rme", "rme_module")})
assert not re.search(r"(?i)rme_adi|adi-?2|\brme_", doc), re.findall(r"(?i).{30}(?:rme_adi|adi-?2|\brme_).{30}", doc)'
  out=$(live env PATH="$ABSENT_PATH" "$REPO/config-audit" 2>&1); rc=$?; [ $i = 1 ] && echo "$out" | mask
  check "C$i config-audit (live config, read only): exit 0" [ $rc = 0 ]
  check "C$i config-audit (live config): no RME BREAK/WARN, at most one neutral line" \
    bash -c '! grep -iE "rme|adi-?2" <<<"$1" | grep -qE "\[(BREAK|WARN)" && [ "$(grep -c "module off" <<<"$1")" -le 1 ] && ! grep -q Traceback <<<"$1"' _ "$out"
  out=$(env PATH="$ABSENT_PATH" XDG_CONFIG_HOME=$T/config "$REPO/config-audit" 2>&1); rc=$?
  check "C$i config-audit (scratch dir holding the RME drop-ins): exit 0, 0 WARN/BREAK, exactly one neutral line" \
    bash -c '[ "$1" = 0 ] && ! grep -qE "\[(WARN|BREAK)" <<<"$2" && [ "$(grep -c "no RME ADI-2: module off" <<<"$2")" = 1 ]' _ $rc "$out"
  out=$(env PATH="$ABSENT_PATH" XDG_CONFIG_HOME=$T/config-mixed "$REPO/config-audit" 2>&1); rc=$?; out=${out//$T/<scratch>}  # the scratch path itself holds "rme"
  [ $i = 1 ] && echo "$out" | mask
  check "C$i config-audit (one file: RME loopback + an unrelated stream): the unrelated stream is still checked, the RME one is not" \
    bash -c '[ "$1" = 0 ] && grep -qE "\[WARN.*other_out.*dont-reconnect" <<<"$2" && ! grep -iE "rme|adi-?2" <<<"$2" | grep -qE "\[(WARN|BREAK)" && [ "$(grep -c "no RME ADI-2: module off" <<<"$2")" = 1 ]' _ $rc "$out"
  check "C$i module node names count as RME while off (a lingering rme_phones default whose nodes are gone)" env PATH="$ABSENT_PATH" python3 - "$REPO" <<'PYEOF'
import importlib.machinery, importlib.util, os, re, sys
def load(f, n):
    ld = importlib.machinery.SourceFileLoader(n, os.path.join(sys.argv[1], f))
    m = importlib.util.module_from_spec(importlib.util.spec_from_loader(n, ld)); ld.exec_module(m); return m
ca = load("config-audit", "ca")
assert ca.RME_NODES == {"rme_phones", "rme_phones.out", "rme_in", "rme_in.cap"}, ca.RME_NODES
assert all(ca.is_rme(n) for n in ca.RME_NODES) and not ca.is_rme("alsa_output.pci-0.hdmi") and not ca.is_rme(None)
# --tone is NOT executed (audio hold): its two gates (start, result) are checked in the source
ad = open(os.path.join(sys.argv[1], "audio-doctor")).read()
assert "not (not rme_on and confaudit.is_rme(def_sink))" in ad and "if TONE and def_sink and not rme_target(def_sink)" in ad
assert "def rme_target(n): return n in rme_off or (not rme_on and confaudit.is_rme(n))" in ad
assert "if TONE and not rme_target(def_sink):" in ad
PYEOF
  out=$(live env PATH="$STALE_PATH" "$REPO/audio-doctor" 2>&1); rc=$?; [ $i = 1 ] && echo "$out" | mask
  check "C$i audio-doctor, stale rme_phones default with its nodes gone (SIMULATED: pactl/pw-dump stubs): exit 0, no BREAK/WARN, no RME row, one neutral line" \
    bash -c '[ "$1" = 0 ] && ! grep -qE "Traceback|\[(BREAK|WARN)" <<<"$2" && ! grep -q rme_phones <<<"$2" && [ "$(grep -c "no RME ADI-2: module off" <<<"$2")" = 1 ]' _ $rc "$out"
  check "C$i audio-doctor (stale default) has no RME row" nor <<<"$out"
  out=$(live env PATH="$STALE_PATH" "$REPO/audio-doctor" --json 2>&1); rc=$?
  check "C$i audio-doctor --json, stale rme_phones default: exit 0, default_sink null, no BREAK/WARN, rme_phones nowhere" jrc $rc "$out" '
assert d["rme_module"] == "off" and d["default_sink"] is None, d["default_sink"]
assert not [f for f in d["findings"] if f["severity"] in ("BREAK", "WARN")], d["findings"]
assert "rme_phones" not in json.dumps(d), "rme_phones named"'
  out=$(live env PATH="$ABSENT_PATH" "$REPO/whatis" --audio 2>&1); rc=$?
  check "C$i whatis --audio: exit 0, no RME error" bash -c '[ "$1" = 0 ] && ! grep -qiE "traceback|(rme|adi).*(error|fail)" <<<"$2"' _ $rc "$out"
  out=$(watch_sample absent-$i "$ABSENT_PATH"); rc=$?; wshow "$out"
  check "C$i omarchy-audio-watch one real sample: no traceback, 0 RME xrun rows" jrc $rc "$out" 'assert d["xrun_rme_nodes"] == 0, d.get("xrun_rme_nodes")'
  out=$(env HOME="$T/home" PATH="$ABSENT_PATH" "$REPO/audit/footprint" kit-test-$i --secs 2 2>&1); rc=$?
  [ $i = 1 ] && echo "$out" | mask
  check "C$i audit/footprint: exit 0, no RME node metered or listed, exactly one neutral line" \
    bash -c '[ "$1" = 0 ] && ! grep -q Traceback <<<"$2" && [ "$(grep -c "no RME ADI-2: module off" <<<"$2")" = 1 ]' _ $rc "$out"
  check "C$i audit/footprint: no RME row in its text" nor <<<"$out"
  check "C$i audit/footprint: saved JSON has module off and no ADI-2 / module node" python3 -c '
import json, re, sys; d = json.load(open(sys.argv[1]))
assert d["rme_module"] == "off", d["rme_module"]
bad = [n for n in d["pipewire_running_nodes"] if re.search(r"RME_ADI|(^|[ +])rme_(phones|in)", n)]
assert not bad, bad' "$T/home/.local/state/omarchy-studio/footprint/kit-test-$i.json"
  out=$(env PATH="$ABSENT_PATH" "$REPO/audit/studio-keepalive" status 2>&1); rc=$?
  check "C$i studio-keepalive status: exit 0, one neutral line ($out)" bash -c '[ "$1" = 0 ] && [ "$(wc -l <<<"$2")" = 1 ]' _ $rc "$out"
  check "C$i omarchy-audio-audit (STUBBED: not executed, audio hold): absent gating, direct ALSA default included" env HOME="$T/home" PATH="$ABSENT_PATH" python3 - "$REPO" <<'EOF'
import importlib.machinery, importlib.util, os, re, sys
src = os.path.join(sys.argv[1], "omarchy-audio-audit")
ld = importlib.machinery.SourceFileLoader("oa", src)
oa = importlib.util.module_from_spec(importlib.util.spec_from_loader("oa", ld)); ld.exec_module(oa)
assert not oa.rme_present()
hw = "alsa_output.usb-RME_ADI-2_Pro__x-00.pro-output-0"
cases = [{"default_sink": hw, "hardware_sink": None, "waits_for": None},  # direct ALSA RME default, gone from the graph
         {"default_sink": "rme_phones", "hardware_sink": None, "waits_for": None},  # module loopback default, nodes gone
         {"default_sink": hw, "hardware_sink": hw, "waits_for": None},    # direct default the chain still names as hw
         {"default_sink": "rme_phones", "hardware_sink": None, "waits_for": hw}]  # loopback waiting for the ADI-2
for c in cases:
    b, n = oa.sweep_gate(c, False)
    assert b and n is None and not re.search(r"ADI|RME|module off|routing", b), (c, b, n)
    sc = oa.rme_scrub(c, False)
    assert not any("RME" in str(v) for v in sc.values()), sc
# a non-RME chain is untouched, and a missing non-RME hardware output is still a routing note
assert oa.sweep_gate({"default_sink": "x", "hardware_sink": "alsa_output.pci-0.hdmi"}, False) == (None, None)
assert "routing broken" in (oa.sweep_gate({"default_sink": "x", "hardware_sink": None, "waits_for": None}, False)[1] or "")
oa.RME_ON = False
dump = oa.pw_dump()
rows = oa.power_settings(dump, oa.rme_scrub(oa.interface_chain(dump), False))
assert not any(r["name"] == "RME ADI-2 auto-standby" for r in rows), "RME auto-standby row present while off"
text = open(src).read()
assert len(re.findall(r"print\(RME_OFF", text)) == 1, "RME_OFF printed more than once"
assert not re.search(r"(emit|print|notes\.append)\([^)]*module off", text), "a second module-off line"
assert "ka = RME_ON and" in text
EOF
done

# ---- L: live state after everything
LIVE_AFTER=$(live_sums); PIDS_AFTER=$(pids)
echo "== L: live drop-ins after"; echo "${LIVE_AFTER:-(none)}" | sed 's/^/      /'; echo "$PIDS_AFTER" | sed 's/^/      /'
if [ -n "$EVID" ]; then echo "$LIVE_AFTER" >"$EVID/live-after.sha"; fi
check "L1 live drop-ins: identical sha256 before and after" [ "$LIVE_BEFORE" = "$LIVE_AFTER" ]
check "L2 no PipeWire/WirePlumber restart (same MainPIDs)" [ "$PIDS_BEFORE" = "$PIDS_AFTER" ]

echo "== $passes passed, $fails failed"
[ $fails = 0 ] && exit 0 || exit 1
