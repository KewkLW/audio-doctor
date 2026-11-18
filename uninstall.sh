#!/usr/bin/env bash
# uninstall.sh: remove exactly what install.sh placed, as listed in its manifest.
# Never deletes ~/.local/state/omarchy-studio (your results) or anything not in the manifest.
set -u

case ${1:-} in
  -h|--help)
    echo "uninstall.sh: stop and remove the watch unit, run each module's disable, then remove every"
    echo "file install.sh listed in \$XDG_DATA_HOME/audio-doctor/install-manifest. Honours HOME and XDG_*."
    echo "Your results in ~/.local/state/omarchy-studio are never touched."
    exit 0 ;;
  "") ;;
  *) echo "uninstall.sh: unknown option '$1' (see --help)" >&2; exit 2 ;;
esac
: "${HOME:?HOME is not set}"
if [ "$(id -u)" = 0 ]; then echo "uninstall.sh: run it as your user, not as root" >&2; exit 2; fi
CFG=${XDG_CONFIG_HOME:-$HOME/.config}
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
UNIT_DIR=$CFG/systemd/user
UNIT_NAME=omarchy-audio-watch.service
KIT_DATA=$DATA/audio-doctor
MOD_DST=$KIT_DATA/modules
MANIFEST=$KIT_DATA/install-manifest
STATE=$HOME/.local/state/omarchy-studio

keep_data_note() {
  echo "Kept your data: $STATE (audit results, watch logs, footprints), if present."
  echo "Reports you saved elsewhere are not touched either. Delete them yourself if you want them gone."
}

if [ ! -f "$MANIFEST" ]; then
  echo "Nothing to remove: no install manifest at $MANIFEST"
  keep_data_note
  exit 0
fi

# 1. Watch unit: stop and disable it only when systemd's loaded unit is the very file we installed
#    (a scratch HOME must never stop the real user's service of the same name).
unit_file=$(awk -F'\t' -v u="$UNIT_DIR/$UNIT_NAME" '$1=="f" && $2==u {print $2}' "$MANIFEST")
SD=0
if [ -n "$unit_file" ]; then
  frag=$(systemctl --user show -p FragmentPath --value "$UNIT_NAME" 2>/dev/null) || frag=
  if [ -n "$frag" ] && [ "$frag" = "$unit_file" ]; then
    SD=1
    systemctl --user disable --now "$UNIT_NAME" 2>&1 | sed 's/^/  /'
    echo "Watch service: stopped and disabled"
  else
    echo "Watch service: systemd is not using $unit_file (scratch HOME or never loaded); systemctl not called"
  fi
fi

# 2. Modules: run disable from the installed copy, before the files go.
if [ -d "$MOD_DST" ]; then
  for m in "$MOD_DST"/*/; do
    [ -d "$m" ] || continue
    name=$(basename "$m")
    if [ -x "$m/disable" ]; then
      out=$(timeout 60 "$m/disable" 2>&1); rc=$?
      echo "Module $name: disable exit $rc"
      [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/  /'
    else
      echo "Module $name: no executable disable, nothing run"
    fi
  done
fi

# 3. Files and links, only when they are still what install.sh put there.
under_state() { case $1 in "$STATE"|"$STATE"/*) return 0 ;; esac; return 1; }
removed=0 kept=()
while IFS=$'\t' read -r t p x; do
  [ -n "${p:-}" ] || continue
  if under_state "$p"; then kept+=("$p (inside your data directory, never removed)"); continue; fi
  case $t in
    f)
      if [ -f "$p" ] && [ ! -L "$p" ]; then
        if [ "$(sha256sum "$p" | cut -d' ' -f1)" = "$x" ]; then rm -f "$p" && removed=$((removed + 1)) && echo "  removed $p"
        else kept+=("$p (changed since install)"); fi
      fi ;;
    l)
      if [ -L "$p" ]; then
        if [ "$(readlink "$p")" = "$x" ]; then rm -f "$p" && removed=$((removed + 1)) && echo "  removed $p"
        else kept+=("$p (now points somewhere else)"); fi
      fi ;;
  esac
done <"$MANIFEST"

# Bytecode Python leaves next to installed commands when one loads another by path (audio-doctor
# imports whatis and config-audit); file names look like whatiscpython-314.pyc.
while IFS=$'\t' read -r t p x; do
  case $t in f|l) ;; *) continue ;; esac
  pc=$(dirname "$p")/__pycache__
  [ -d "$pc" ] || continue
  b=$(basename "$p")
  for c in "$pc/$b"cpython-*.pyc "$pc/${b%.py}".cpython-*.pyc; do
    [ -f "$c" ] && rm -f "$c" && echo "  removed $c"
  done
  rmdir "$pc" 2>/dev/null && echo "  removed $pc/"
done <"$MANIFEST"

[ $SD = 1 ] && systemctl --user daemon-reload

# 4. The manifest, then the directories install.sh created, deepest first, only when empty.
dirs=$(awk -F'\t' '$1=="d" {print length($2) "\t" $2}' "$MANIFEST" | sort -rn | cut -f2-)
rm -f "$MANIFEST"
while IFS= read -r d; do
  [ -n "$d" ] && [ -d "$d" ] || continue
  under_state "$d" && continue
  if rmdir "$d" 2>/dev/null; then echo "  removed $d/"; else kept+=("$d/ (not empty)"); fi
done <<<"$dirs"

echo "Removed $removed installed files."
if [ ${#kept[@]} -gt 0 ]; then
  echo "Left in place:"
  for k in "${kept[@]}"; do echo "  $k"; done
fi
keep_data_note
exit 0
