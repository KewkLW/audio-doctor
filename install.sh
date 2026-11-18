#!/usr/bin/env bash
# install.sh: install the audio-doctor diagnostics kit for the current user.
# No sudo, no package installs. Everything it places is listed in a manifest
# so uninstall.sh removes exactly that and nothing else.
set -u

usage() {
  cat <<'EOF'
install.sh [options]

Installs into the current user's home (honours HOME, XDG_CONFIG_HOME, XDG_DATA_HOME):
  commands   ~/.local/bin/{audio-doctor,config-audit,whatis,omarchy-audio-audit,omarchy-audio-watch,footprint}
  unit       $XDG_CONFIG_HOME/systemd/user/omarchy-audio-watch.service (installed, not started)
  skill      ~/.claude/skills/audio-doctor/SKILL.md
  modules    $XDG_DATA_HOME/audio-doctor/modules/ (each module: detect && enable)
  manifest   $XDG_DATA_HOME/audio-doctor/install-manifest

Options:
  --link          symlink the commands to this checkout instead of copying them
  --start         enable and start the watch unit after installing it
  --no-start      do not start the watch unit and do not ask (default when not on a terminal)
  --force         replace files that exist but were not placed by this installer
  --bindir DIR    put the commands in DIR instead of ~/.local/bin
  --check         only check dependencies (exit 1 when a required one is missing)
  -h, --help      this text
EOF
}

SRC=$(cd "$(dirname "$(realpath "$0")")" && pwd)
: "${HOME:?HOME is not set}"
CFG=${XDG_CONFIG_HOME:-$HOME/.config}
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
BIN=$HOME/.local/bin
UNIT_DIR=$CFG/systemd/user
UNIT_NAME=omarchy-audio-watch.service
SKILL_DIR=$HOME/.claude/skills/audio-doctor
KIT_DATA=$DATA/audio-doctor
MOD_DST=$KIT_DATA/modules
MANIFEST=$KIT_DATA/install-manifest
STATE=$HOME/.local/state/omarchy-studio

LINK=0 START=ask FORCE=0 CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case $1 in
    --link) LINK=1 ;;
    --start) START=yes ;;
    --no-start) START=no ;;
    --force) FORCE=1 ;;
    --bindir) shift; BIN=$(realpath -m -- "${1:?--bindir needs a directory}") ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install.sh: unknown option '$1' (see --help)" >&2; exit 2 ;;
  esac
  shift
done
if [ "$(id -u)" = 0 ]; then echo "install.sh: run it as your user, not as root (no sudo needed)" >&2; exit 2; fi

# Kit commands: source path in this repo -> installed name.
KIT=(
  "audio-doctor:audio-doctor"
  "config-audit:config-audit"
  "whatis:whatis"
  "omarchy-audio-audit:omarchy-audio-audit"
  "omarchy-audio-watch:omarchy-audio-watch"
  "audit/footprint:footprint"
)

# ------------------------------------------------------------------ dependencies
check_deps() {
  local req=(python3:python pw-cli:pipewire pw-dump:pipewire pw-top:pipewire pw-metadata:pipewire
             pw-link:pipewire wpctl:wireplumber cyclictest:rt-tests)
  local opt=("rtla:no Arch repo package found; AUR, or build it from the kernel source tools/tracing/rtla"
             "turbostat:pacman package: turbostat"
             "stress-ng:pacman package: stress-ng")
  local e cmd pkg miss=() pkgs=()
  echo "Dependencies:"
  for e in "${req[@]}"; do
    cmd=${e%%:*} pkg=${e#*:}
    if command -v "$cmd" >/dev/null 2>&1; then echo "  ok        $cmd"
    else echo "  MISSING   $cmd  (required; pacman package: $pkg)"; miss+=("$cmd")
         case " ${pkgs[*]-} " in *" $pkg "*) ;; *) pkgs+=("$pkg") ;; esac
    fi
  done
  for e in "${opt[@]}"; do
    cmd=${e%%:*} pkg=${e#*:}
    if command -v "$cmd" >/dev/null 2>&1; then echo "  ok        $cmd"
    else echo "  missing   $cmd  (optional, used by omarchy-audio-audit; $pkg)"; fi
  done
  if [ ${#miss[@]} -gt 0 ]; then
    echo "  Required tools are missing. This installer never installs packages; to add them run:"
    echo "    sudo pacman -S --needed ${pkgs[*]}"
    return 1
  fi
  return 0
}

if [ $CHECK_ONLY = 1 ]; then check_deps; exit $?; fi

# ------------------------------------------------------------------ manifest
# Lines: TYPE<TAB>PATH<TAB>EXTRA. f = copied file (EXTRA = sha256), l = symlink (EXTRA = target),
# d = directory this installer created.
declare -A OLD=()
if [ -f "$MANIFEST" ]; then
  while IFS=$'\t' read -r t p x; do [ -n "${p:-}" ] && OLD[$p]=$t; done <"$MANIFEST"
fi
NEW=$(mktemp) || exit 1
trap 'rm -f "$NEW"' EXIT
rec() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"$NEW"; }
PLACED=() SKIPPED=() FAILED=()

mkd() {   # create a directory and every missing parent, recording each one created
  local d=$1
  [ -d "$d" ] && return 0
  mkd "$(dirname "$d")" || return 1
  mkdir "$d" || { FAILED+=("$d (mkdir failed)"); return 1; }
  rec d "$d"
}

may_write() {   # 0 when DST is free, ours from an earlier run, or --force
  local dst=$1
  [ -e "$dst" ] || [ -L "$dst" ] || return 0
  [ -n "${OLD[$dst]+x}" ] && return 0
  [ $FORCE = 1 ] && return 0
  SKIPPED+=("$dst (exists, not placed by this installer; --force replaces it)")
  return 1
}

# Each returns 1 when DST was not placed; a real failure goes to FAILED, a file we must not touch to SKIPPED.
put_file() {   # put_file SRC DST MODE
  local src=$1 dst=$2 mode=$3 tmp
  may_write "$dst" || return 1
  mkd "$(dirname "$dst")" || { FAILED+=("$dst (cannot create its directory)"); return 1; }
  tmp=$(mktemp "$(dirname "$dst")/.audio-doctor-install.XXXXXX") || { FAILED+=("$dst (cannot create a temp file)"); return 1; }
  cp "$src" "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$dst" || { rm -f "$tmp"; FAILED+=("$dst (copy failed)"); return 1; }
  rec f "$dst" "$(sha256sum "$dst" | cut -d' ' -f1)"
  PLACED+=("$dst")
}

put_link() {   # put_link TARGET DST
  local tgt=$1 dst=$2
  may_write "$dst" || return 1
  mkd "$(dirname "$dst")" || { FAILED+=("$dst (cannot create its directory)"); return 1; }
  rm -f "$dst" && ln -s "$tgt" "$dst" || { FAILED+=("$dst (link failed)"); return 1; }
  rec l "$dst" "$tgt"
  PLACED+=("$dst -> $tgt")
}

# The user systemd manager only reads unit files from its own search path. A scratch HOME is not on it,
# so systemctl is used only when the target unit directory is one the manager really reads.
sd_reads_unit_dir() {
  local up
  up=$(systemctl --user show -p UnitPath --value 2>/dev/null) || return 1
  case " $up " in *" $UNIT_DIR "*) return 0 ;; esac
  return 1
}

# ------------------------------------------------------------------ install
echo "audio-doctor kit: installing from $SRC"
check_deps; DEPS_OK=$?
echo

for e in "${KIT[@]}"; do
  s=${e%%:*} n=${e#*:}
  if [ ! -f "$SRC/$s" ]; then FAILED+=("$BIN/$n (source $s not found in the checkout)"); continue; fi
  if [ $LINK = 1 ]; then put_link "$SRC/$s" "$BIN/$n"; else put_file "$SRC/$s" "$BIN/$n" 0755; fi
done

# Watch unit: ExecStart points at the bin directory used above.
UNIT_TMP=$(mktemp) || exit 1
if sed "s|@BINDIR@|$BIN|g" "$SRC/omarchy-audio-watch.service" >"$UNIT_TMP"; then
  put_file "$UNIT_TMP" "$UNIT_DIR/$UNIT_NAME" 0644
else
  FAILED+=("$UNIT_DIR/$UNIT_NAME (cannot read the unit template)")
fi
rm -f "$UNIT_TMP"

put_file "$SRC/SKILL.md" "$SKILL_DIR/SKILL.md" 0644

# Modules: copied as they are, then detect && enable for each.
MODS=()
if [ -d "$SRC/modules" ]; then
  while IFS= read -r -d '' p; do
    rel=${p#"$SRC/modules/"}
    if [ -d "$p" ]; then mkd "$MOD_DST/$rel"
    elif [ -f "$p" ]; then put_file "$p" "$MOD_DST/$rel" "$(stat -c %a "$p")"
    fi
  done < <(find "$SRC/modules" -mindepth 1 \( -name __pycache__ -prune \) -o -print0 | sort -z)
  for m in "$SRC"/modules/*/; do [ -d "$m" ] && MODS+=("$(basename "$m")"); done
fi

# Write the manifest (deduplicated, directories kept from earlier runs).
mkd "$KIT_DATA" || { echo "install.sh: cannot create $KIT_DATA" >&2; exit 1; }
# Entries from an earlier run that this run did not rewrite stay, so uninstall still finds them.
if ! { { cat "$NEW"; [ -f "$MANIFEST" ] && awk -F'\t' 'NR==FNR { seen[$2]=1; next } !($2 in seen)' "$NEW" "$MANIFEST"; } \
       | sort -u >"$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"; }; then
  rm -f "$MANIFEST.tmp"
  echo "install.sh: FAILED to write the manifest $MANIFEST; uninstall.sh cannot find what was placed:" >&2
  for p in "${PLACED[@]}"; do echo "  $p" >&2; done
  exit 1
fi

echo "Placed:"
for p in "${PLACED[@]}"; do echo "  $p"; done
if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo "Not placed (left alone):"
  for p in "${SKIPPED[@]}"; do echo "  $p"; done
fi
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "FAILED:"
  for p in "${FAILED[@]}"; do echo "  $p"; done
fi
echo "Manifest: $MANIFEST"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "Note: $BIN is not on your PATH; add it to run the commands by name." ;; esac
echo

echo "Modules:"
if [ ${#MODS[@]} -eq 0 ]; then echo "  none in this checkout"; fi
ENABLED=0
for name in "${MODS[@]}"; do
  m=$MOD_DST/$name
  if [ ! -x "$m/detect" ]; then echo "  $name: no executable detect, skipped"; continue; fi
  out=$(timeout 30 "$m/detect" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then echo "  $name: device not present, not enabled${out:+ ($out)}"; continue; fi
  if [ ! -x "$m/enable" ]; then echo "  $name: detected, but it has no executable enable"; continue; fi
  out=$(timeout 60 "$m/enable" 2>&1); rc=$?
  echo "  $name: detected, enable exit $rc"
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/    /'
  [ $rc -eq 0 ] && ENABLED=1
done
if [ $ENABLED = 1 ]; then
  echo "  New PipeWire configuration takes effect at the next PipeWire start. Nothing in this kit restarts PipeWire."
fi
echo

echo "Watch service ($UNIT_NAME):"
if ! grep -qF $'f\t'"$UNIT_DIR/$UNIT_NAME"$'\t' "$MANIFEST"; then
  echo "  not placed (see above); systemd left alone"
elif sd_reads_unit_dir; then
  systemctl --user daemon-reload || FAILED+=("systemctl --user daemon-reload failed")
  if [ $START = ask ]; then
    START=no
    if [ -t 0 ] && [ -t 1 ]; then
      read -r -p "  Start the watch now and at every login? [y/N] " a
      case $a in [yY]*) START=yes ;; esac
    fi
  fi
  if [ $START = yes ]; then
    if systemctl --user enable --now "$UNIT_NAME"; then echo "  enabled and started"
    else echo "  FAILED to enable and start it (see the systemctl message above)"; FAILED+=("systemctl --user enable --now $UNIT_NAME failed"); fi
  else
    echo "  installed, not started. Start it with: systemctl --user enable --now $UNIT_NAME"
  fi
else
  echo "  installed to $UNIT_DIR, which your user systemd does not read (custom HOME or XDG_CONFIG_HOME):"
  echo "  systemctl not called, not started"
  if [ $START = yes ]; then
    echo "  FAILED: --start asked for, but this systemd cannot see the unit"
    FAILED+=("--start: $UNIT_DIR is not on the user systemd unit path, service not started")
  fi
fi
echo

echo "Your data (results, logs) goes to $STATE; uninstall.sh never deletes it."
[ $DEPS_OK = 0 ] || echo "Some required tools are missing: see Dependencies above."
if [ ${#FAILED[@]} -gt 0 ] || [ ${#SKIPPED[@]} -gt 0 ]; then
  echo "Install INCOMPLETE: ${#FAILED[@]} failed, ${#SKIPPED[@]} left alone (listed above). Exit 1."
  echo "What was placed is in the manifest; $SRC/uninstall.sh removes it."
  exit 1
fi
echo "Done. Uninstall with: $SRC/uninstall.sh"
exit 0
