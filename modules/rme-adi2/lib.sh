# Shared by detect / enable / disable / status. Sourced, not run.
# Module contract: every executable exits 0 or 1 and prints a reason; nothing here makes an install fail.
# File placement honours XDG_CONFIG_HOME, XDG_DATA_HOME and XDG_BIN_HOME, so it can run against a scratch dir.
#   RME_ADI2_SYSFS_USB   USB device directory to scan (default /sys/bus/usb/devices; tests point it elsewhere)
set -u

MOD_DIR=$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)
USB_ID=2a39:3fd2
CONF=${XDG_CONFIG_HOME:-$HOME/.config}
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
# Bin dir (contract amendments 1 and 2): ${XDG_BIN_HOME:-<parent of XDG_DATA_HOME>/bin}. The installer exports
# XDG_BIN_HOME; with neither set this is ~/.local/bin, and a scratch XDG_DATA_HOME alone never touches the live home.
BINDIR=${XDG_BIN_HOME:-$(dirname "$DATA")/bin}
MANIFEST=$DATA/audio-doctor/module-state/rme-adi2.placed
SYSFS_USB=${RME_ADI2_SYSFS_USB:-/sys/bus/usb/devices}
RESTART_NOTE="PipeWire/WirePlumber config takes effect at the next PipeWire start (login or reboot); nothing in the kit restarts PipeWire."

# piece name | kind (file, template, link) | source in the module | destination
pieces() {
  printf '%s|%s|%s|%s\n' \
    wireplumber-rule file     "$MOD_DIR/files/50-rme-adi2.conf"           "$CONF/wireplumber/wireplumber.conf.d/50-rme-adi2.conf" \
    stereo-loopbacks template "$MOD_DIR/files/50-rme-adi2-stereo.conf.in" "$CONF/pipewire/pipewire.conf.d/50-rme-adi2-stereo.conf" \
    studio-keepalive link     "$MOD_DIR/bin/studio-keepalive"             "$BINDIR/studio-keepalive"
}

# sysfs directory of the ADI-2 Pro on the bus, empty when absent
usb_dev() {
  local d
  for d in "$SYSFS_USB"/*; do
    [ -r "$d/idVendor" ] && [ -r "$d/idProduct" ] || continue
    [ "$(cat "$d/idVendor" 2>/dev/null):$(cat "$d/idProduct" 2>/dev/null)" = "$USB_ID" ] && { echo "$d"; return 0; }
  done
  return 1
}

# udev ID_SERIAL (RME_ADI-2_Pro__<serial>__<usb-id>): the middle of the unit's ALSA node names
id_serial() {
  local d s
  d=$(usb_dev) || return 1
  s=$(udevadm info -q property -p "$(realpath "$d")" 2>/dev/null | sed -n 's/^ID_SERIAL=//p' | head -1)
  [ -n "$s" ] || s=$(pw-dump 2>/dev/null | grep -o '"alsa_output\.usb-RME_ADI-2_Pro[^"]*\.pro-output-0"' | head -1 | sed 's/^"alsa_output\.usb-//; s/-00\.pro-output-0"$//')
  case "$s" in RME_ADI-2_Pro__*) echo "$s" ;; *) return 1 ;; esac
}

# what the piece should look like on disk: file content on stdout (file/template), or the link target
render() {
  local kind=$1 src=$2 s
  case "$kind" in
    file) cat "$src" ;;
    template) s=$(id_serial) || return 1
              s=$(sed "/^#@/d; /target\.object/s|RME_ADI-2_Pro__<serial>__<usb-id>|$s|" "$src") || return 1  # #@ lines: template notes only
              case "$s" in *'<serial>'*|*'<usb-id>'*) return 1 ;; esac  # never a half-filled file
              printf '%s\n' "$s" ;;
    link) echo "$src" ;;
  esac
}

sum_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# manifest lines: name<TAB>kind<TAB>dest<TAB>sha256 (file/template) or link target (link)
man_get() { [ -f "$MANIFEST" ] && awk -F'\t' -v n="$1" '$1 == n { print $3 "\t" $4 }' "$MANIFEST"; }
man_put() {
  mkdir -p "$(dirname "$MANIFEST")" || return 1
  { [ -f "$MANIFEST" ] && awk -F'\t' -v n="$1" '$1 != n' "$MANIFEST"; printf '%s\t%s\t%s\t%s\n' "$@"; } >"$MANIFEST.tmp" &&
    mv -f "$MANIFEST.tmp" "$MANIFEST"
}
man_del() {
  [ -f "$MANIFEST" ] || return 0
  awk -F'\t' -v n="$1" '$1 != n' "$MANIFEST" >"$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST" || return 1
  [ -s "$MANIFEST" ] || rm -f "$MANIFEST"
  return 0
}

# mkdir -p that records every directory it creates, so disable can remove them again (only if empty)
mkd() {
  local d=$1 x missing=()
  while [ ! -d "$d" ]; do missing+=("$d"); d=$(dirname "$d"); done
  mkdir -p "$1" || return 1
  for x in "${missing[@]}"; do man_put "dir:$x" dir "$x" - || return 1; done
}

# is the thing at dest exactly what enable placed (manifest record still matches)?
ours() {
  local name=$1 rec dest val
  rec=$(man_get "$name"); [ -n "$rec" ] || return 1
  dest=${rec%%$'\t'*} val=${rec#*$'\t'}
  if [ -L "$dest" ]; then [ "$(readlink "$dest")" = "$val" ]
  else [ -f "$dest" ] && [ "$(sum_of "$dest")" = "$val" ]; fi
}

# does an existing dest (not placed by this module) already hold exactly what enable would place?
identical() {
  local kind=$1 dest=$2 want=$3
  if [ "$kind" = link ]; then
    [ -L "$dest" ] && { [ "$(readlink "$dest")" = "$want" ] || [ "$(realpath "$dest" 2>/dev/null)" = "$(realpath "$want")" ]; }
  else
    [ -f "$dest" ] && [ ! -L "$dest" ] && [ "$(sum_of "$dest")" = "$(printf '%s\n' "$want" | sha256sum | cut -d' ' -f1)" ]
  fi
}

adi2_line() {
  if command -v adi2 >/dev/null 2>&1; then echo "adi2: installed ($(command -v adi2))"
  else echo "adi2: adi2 not installed (optional; device rows that need it are skipped)"; fi
}
