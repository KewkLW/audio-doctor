# audio-doctor

Find where audio stops, hop by hop, with measured levels. See `audio-doctor --help` and the skill at `~/.claude/skills/audio-doctor/SKILL.md` (copy in `SKILL.md`).

`whatis` (same repo) names the real app behind generic process names (chromium web apps, Wine/Proton, AppImage, Electron, Flatpak, scripts) and flags apps left stale by a PipeWire restart. `whatis --help`.

`config-audit` (same repo) lints every PipeWire/WirePlumber drop-in against the running graph for traps that break audio later: loopbacks that never relink after a device power cycle (`target.object` + `node.dont-reconnect`), `dont-fallback` without `linger`, missing targets and why, pro-audio targets with no profile rule, disk-vs-running drift, unparseable files. `config-audit --fix` (or `audio-doctor --fix`) relinks streams whose target is present but unlinked. audio-doctor folds its findings into every run.
