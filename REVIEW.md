# REVIEW.md: what a reviewer checks in an audio-doctor diff

These tools run on a stranger's Linux machine with a live PipeWire session,
apps open, and an RME ADI-2 Pro on USB or not. Each rule is checked against
the lines a diff adds or changes. A diff that breaks one is a reject.

## 1. Audio safety (hard lines)

These cover commands the code executes. A printed fix hint that names a
command for the user to run is advice, not a violation.

- Never restart, stop or kill `pipewire` or `pipewire-pulse` (`systemctl
  --user restart|stop`, `kill`, `pkill`): open apps lose their audio. New
  PipeWire config takes effect at the next PipeWire start; the tool says so.
  WirePlumber restarts are outside this rule.
- No volume raise: the code never runs `wpctl set-volume`, `pactl
  set-sink-volume`, `amixer set` or a device control write that can increase
  a level. Reading a volume is fine.
- Nothing plays audible signal (`pw-play`, `pw-cat --playback`, `aplay`,
  `paplay`, `speaker-test`, a tone or sweep, a DAW transport start) unless the
  tool's purpose is playback. A diagnostic, audit, install, watch or test path
  never plays sound. A stream of zeros that only keeps the graph running is
  allowed when the tool stops it by its own PID.
- USB access to the RME is read only. No write, erase or unknown vendor OUT
  control request (host to device, vendor type). Every vendor request a diff
  adds must be a known IN (read) request with a comment naming what it reads.

## 2. Device gating: a machine without the RME sees nothing about it

- Every RME specific row, count, WARN, FAIL or error is gated on
  `modules/rme-adi2/detect` reporting the device present (standby counts as
  absent). That covers `audio-doctor`, `audit/footprint`, `config-audit`,
  `omarchy-audio-audit` and any new tool.
- Leftovers are gated too: lingering RME named nodes (the module's loopbacks,
  its ALSA sinks) and RME config drop-ins on a machine where detect says
  absent are not listed, not counted in sweep or DAW totals and not reported
  as duplicates.
- A diff that adds RME output adds or extends a test that runs with detect
  reporting absent and asserts zero RME lines and an unchanged exit status.

## 3. Failure paths that change state (install, uninstall, modules)

- A failed stop, disable or delete must keep the state needed to retry.
  Check the exit status of `systemctl disable/stop`, `rm`, `mktemp` and
  manifest rewrites before removing the manifest lines, state file or marker
  a second run needs. Reject `cmd; rm state` and `cmd || true; rm state`.
- A failed step exits non zero and names what is left behind; it never
  prints success.

## 4. Tests must prove they ran

- A test asserts on real output or real device or session state (stdout,
  exit status, files written, `pw-dump`/`wpctl` readings), not on a script
  merely finishing. A test that would pass with the tool missing or a no op
  body is a reject.
- No weakening: a diff may not loosen an assertion, delete a check, widen a
  match, add `|| true`, skip a case, add sleeps, raise timeouts or retry a
  step to get green. A flaky test is fixed at its root cause; deleting or
  disabling it is a reject.

## 5. Privacy

- No home or vault paths, hostnames, IPs, device serials, keyring account
  names, session ids or real names in code, docs, tests or fixtures. Use `~`,
  `<host>` and placeholders.
