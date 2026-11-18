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
# d = directory this installer created, m = a module directory whose files this installer placed
# (uninstall runs disable only for these, and only when the hook still has its recorded hash), b = the bin dir the commands went to (handed to module hooks
# at uninstall; only the latest run's b line is kept).
declare -A OLD=() OLDX=()
if [ -f "$MANIFEST" ]; then
  while IFS=$'\t' read -r t p x; do [ -n "${p:-}" ] && { OLD[$p]=$t; OLDX[$p]=${x:-}; }; done <"$MANIFEST"
fi
NEW=$(mktemp) || exit 1
trap 'rm -f "$NEW"' EXIT
rec() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"$NEW"; }
PLACED=() SKIPPED=() FAILED=()
declare -A PH=()   # sha256 of every file this run placed: module hooks run only when they match

mkd() {   # create a directory and every missing parent, recording each one created
  local d=$1
  [ -d "$d" ] && return 0
  mkd "$(dirname "$d")" || return 1
  mkdir "$d" || { FAILED+=("$d (mkdir failed)"); return 1; }
  rec d "$d"
}

still_ours() {   # 0 when DST is in the old manifest and still exactly what install.sh put there
  local dst=$1
  [ -n "${OLD[$dst]+x}" ] || return 1
  case ${OLD[$dst]} in
    f) [ -f "$dst" ] && [ ! -L "$dst" ] && [ "$(sha256sum "$dst" | cut -d' ' -f1)" = "${OLDX[$dst]}" ] ;;
    l) [ -L "$dst" ] && [ "$(readlink "$dst")" = "${OLDX[$dst]}" ] ;;
    *) return 1 ;;
  esac
}

may_write() {   # 0 when DST is free, unchanged from an earlier run of this installer, or --force
  local dst=$1
  [ -e "$dst" ] || [ -L "$dst" ] || return 0
  still_ours "$dst" && return 0
  [ $FORCE = 1 ] && return 0
  if [ -n "${OLD[$dst]+x}" ]; then SKIPPED+=("$dst (placed by an earlier install but changed since; --force replaces it)")
  else SKIPPED+=("$dst (exists, not placed by this installer; --force replaces it)"); fi
  return 1
}

# Each returns 1 when DST was not placed; a real failure goes to FAILED, a file we must not touch to SKIPPED.
put_file() {   # put_file SRC DST MODE
  local src=$1 dst=$2 mode=$3 tmp
  may_write "$dst" || return 1
  mkd "$(dirname "$dst")" || { FAILED+=("$dst (cannot create its directory)"); return 1; }
  tmp=$(mktemp "$(dirname "$dst")/.audio-doctor-install.XXXXXX") || { FAILED+=("$dst (cannot create a temp file)"); return 1; }
  cp "$src" "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$dst" || { rm -f "$tmp"; FAILED+=("$dst (copy failed)"); return 1; }
  PH[$dst]=$(sha256sum "$dst" | cut -d' ' -f1)
  rec f "$dst" "${PH[$dst]}"
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

# Bytecode for a copied Python command. audio-doctor loads whatis and config-audit by path, so Python
# would write bin/__pycache__/<name>cpython-3XX.pyc at run time, a file no manifest knows. Writing it
# here (same name and contents Python would use) puts it in the manifest; Python then reads it as is.
# A cache file that is already there and not ours is left alone (not an error: Python reuses it).
put_pyc() {   # put_pyc DST
  local dst=$1 pyc
  head -1 "$dst" | grep -q python3 || return 0
  pyc=$(python3 -I -c 'import importlib.util,sys; print(importlib.util.cache_from_source(sys.argv[1]))' "$dst" 2>/dev/null) || return 0
  if [ -e "$pyc" ] || [ -L "$pyc" ]; then still_ours "$pyc" || return 0; fi
  mkd "$(dirname "$pyc")" || { FAILED+=("$pyc (cannot create its directory)"); return 1; }
  python3 -I -c 'import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$dst" "$pyc" \
    || { rm -f "$pyc"; FAILED+=("$pyc (bytecode compile failed)"); return 1; }
  rec f "$pyc" "$(sha256sum "$pyc" | cut -d' ' -f1)"
  PLACED+=("$pyc")
}

declare -A CMD_OK=()   # commands this run placed (the unit is started only when its command is one of them)
for e in "${KIT[@]}"; do
  s=${e%%:*} n=${e#*:}
  if [ ! -f "$SRC/$s" ]; then FAILED+=("$BIN/$n (source $s not found in the checkout)"); continue; fi
  if [ $LINK = 1 ]; then put_link "$SRC/$s" "$BIN/$n" && CMD_OK[$n]=1   # linked: Python caches inside the checkout
  else put_file "$SRC/$s" "$BIN/$n" 0755 && CMD_OK[$n]=1 && put_pyc "$BIN/$n"; fi
done

# Watch unit: ExecStart points at the bin directory used above.
UNIT_PLACED=0
UNIT_TMP=$(mktemp) || exit 1
if sed "s|@BINDIR@|$BIN|g" "$SRC/omarchy-audio-watch.service" >"$UNIT_TMP"; then
  put_file "$UNIT_TMP" "$UNIT_DIR/$UNIT_NAME" 0644 && UNIT_PLACED=1
else
  FAILED+=("$UNIT_DIR/$UNIT_NAME (cannot read the unit template)")
fi
rm -f "$UNIT_TMP"

put_file "$SRC/SKILL.md" "$SKILL_DIR/SKILL.md" 0644

# Modules: copied as they are, then detect && enable for each. A module's hooks run only when this
# run placed every one of its files (none skipped as foreign, none failed): a hook that was already
# there and not ours is never executed. Each module this run placed fully gets an m line.
MODS=()
declare -A MODBAD=()
if [ -d "$SRC/modules" ]; then
  if [ -L "$MOD_DST" ] || { [ -e "$MOD_DST" ] && [ ! -d "$MOD_DST" ]; }; then
    SKIPPED+=("$MOD_DST (exists and is not a plain directory; modules not installed)")
    for m in "$SRC"/modules/*/; do [ -d "$m" ] && MODBAD[$(basename "$m")]="destination $MOD_DST is not a plain directory"; done
  else
    while IFS= read -r -d '' p; do
      rel=${p#"$SRC/modules/"}
      mod=; case $rel in */*) mod=${rel%%/*} ;; *) [ -d "$p" ] && mod=$rel ;; esac
      dst=$MOD_DST/$rel
      if [ -d "$p" ]; then
        if [ -L "$dst" ] || { [ -e "$dst" ] && [ ! -d "$dst" ]; }; then
          SKIPPED+=("$dst (exists and is not a plain directory, not placed by this installer)")
          [ -n "$mod" ] && MODBAD[$mod]="$dst is not a plain directory"
        else
          mkd "$dst" || { [ -n "$mod" ] && MODBAD[$mod]="cannot create $dst"; }
        fi
      elif [ -f "$p" ]; then
        put_file "$p" "$dst" "$(stat -c %a "$p")" || { [ -n "$mod" ] && MODBAD[$mod]="$dst was not placed"; }
      fi
    done < <(find "$SRC/modules" -mindepth 1 \( -name __pycache__ -prune \) -o -print0 | sort -z)
  fi
  for m in "$SRC"/modules/*/; do
    [ -d "$m" ] || continue
    name=$(basename "$m"); MODS+=("$name")
    [ -z "${MODBAD[$name]+x}" ] && rec m "$MOD_DST/$name" "$name"
  done
fi

rec b "$BIN"
# Write the manifest (deduplicated, directories kept from earlier runs).
mkd "$KIT_DATA" || { echo "install.sh: cannot create $KIT_DATA" >&2; exit 1; }
# Entries from an earlier run that this run did not rewrite stay, so uninstall still finds them.
MTMP=$(mktemp "$KIT_DATA/.install-manifest.XXXXXX") || MTMP=
if [ -z "$MTMP" ] || ! { { cat "$NEW"; [ -f "$MANIFEST" ] && awk -F'\t' 'NR==FNR { seen[$1 FS $2]=1; next } $1!="b" && !(($1 FS $2) in seen)' "$NEW" "$MANIFEST"; } \
       | sort -u >"$MTMP" && chmod 0644 "$MTMP" && mv -f "$MTMP" "$MANIFEST"; }; then
  [ -n "$MTMP" ] && rm -f "$MTMP"
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
echo "Manifest: $MANIFEST"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "Note: $BIN is not on your PATH; add it to run the commands by name." ;; esac
echo

echo "Modules:"
if [ ${#MODS[@]} -eq 0 ]; then echo "  none in this checkout"; fi
ENABLED=0
# Contract: every hook gets XDG_BIN_HOME = the bin dir the kit commands went to (also with --bindir).
HOOK_ENV=(XDG_BIN_HOME="$BIN")
hook_ours() {   # hook_ours PATH: 0 when this run placed PATH and it still has the hash recorded for it
  [ -n "${PH[$1]+x}" ] && [ -f "$1" ] && [ ! -L "$1" ] && [ -x "$1" ] \
    && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "${PH[$1]}" ]
}
for name in "${MODS[@]}"; do
  m=$MOD_DST/$name
  if [ -n "${MODBAD[$name]+x}" ]; then
    echo "  $name: NOT run: ${MODBAD[$name]} (see 'Not placed' above); its hooks are not ours to execute"
    continue
  fi
  if [ ! -f "$SRC/modules/$name/detect" ]; then echo "  $name: no detect, skipped"; continue; fi
  if ! hook_ours "$m/detect"; then echo "  $name: NOT run: $m/detect is not the file this run placed"; FAILED+=("$m/detect (changed after copy, not run)"); continue; fi
  out=$(env "${HOOK_ENV[@]}" timeout 30 "$m/detect" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then echo "  $name: device not present, not enabled${out:+ ($out)}"; continue; fi
  if [ ! -f "$SRC/modules/$name/enable" ]; then echo "  $name: detected, but it has no enable"; continue; fi
  if ! hook_ours "$m/enable"; then echo "  $name: NOT run: $m/enable is not the file this run placed"; FAILED+=("$m/enable (changed after copy, not run)"); continue; fi
  out=$(env "${HOOK_ENV[@]}" timeout 60 "$m/enable" 2>&1); rc=$?
  # Contract: a module never makes an install fail; a non-zero enable is a printed note.
  if [ $rc -eq 0 ]; then echo "  $name: detected, enabled"; ENABLED=1
  else echo "  $name: detected, enable exit $rc (note only: the kit installed; run '$m/status' to see what is in place)"; fi
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/    /'
done
if [ $ENABLED = 1 ]; then
  echo "  New PipeWire configuration takes effect at the next PipeWire start. Nothing in this kit restarts PipeWire."
fi
echo

echo "Watch service ($UNIT_NAME):"
if [ $UNIT_PLACED = 0 ]; then
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
  if [ $START = yes ] && [ -z "${CMD_OK[omarchy-audio-watch]+x}" ]; then
    echo "  FAILED: not started: $BIN/omarchy-audio-watch was not placed by this run (see above), so the unit would run a file this installer does not own"
    FAILED+=("--start: $BIN/omarchy-audio-watch not placed by this run, service not started")
  elif [ $START = yes ]; then
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
[ $DEPS_OK = 0 ] || FAILED+=("required tools missing (see Dependencies above); the kit is installed but will not work until they are")
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "FAILED:"
  for p in "${FAILED[@]}"; do echo "  $p"; done
fi
if [ ${#FAILED[@]} -gt 0 ] || [ ${#SKIPPED[@]} -gt 0 ]; then
  echo "Install INCOMPLETE: ${#FAILED[@]} failed (FAILED above), ${#SKIPPED[@]} left alone (Not placed above). Exit 1."
  echo "What was placed is in the manifest; $SRC/uninstall.sh removes it."
  exit 1
fi
echo "Done. Uninstall with: $SRC/uninstall.sh"
exit 0
