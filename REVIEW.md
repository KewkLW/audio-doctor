# REVIEW.md: what a reviewer checks in an audio-doctor diff

These tools run on a stranger's Linux machine with a live PipeWire session,
apps open and maybe an RME ADI-2 Pro on USB, maybe not. Each rule below can be
checked from the diff alone. A diff that breaks one is a reject, even when the
acceptance criteria are otherwise met.

## 1. Audio safety (hard lines)

- No restart of `pipewire` or `pipewire-pulse` (no `systemctl --user restart`,
  `stop`, `kill` or `pkill` of them) in any tool, installer or test. New
  PipeWire config takes effect at the next PipeWire start; the tool says so
  instead of forcing it. A WirePlumber restart is allowed only where the diff
  documents it as the fix for RME nodes without ports.
- No volume raise: no `wpctl set-volume`, `pactl set-sink-volume`, `amixer
  set` or device control write that can increase a level. Reading a volume is
  fine; lowering or muting must be what the tool is for.
- Nothing plays audio (`pw-play`, `aplay`, `paplay`, `speaker-test`, a tone,
  sweep or test stream, a DAW transport start) unless the tool's stated purpose
  is playback. Diagnostics meter existing signal, they never inject it.
- USB access to the RME is read only. No write, erase or unknown vendor OUT
  control request (host to device, vendor type) may appear. Every vendor
  request in the diff must be a known IN (read) request; a new request code
  needs a comment naming what it reads.

## 2. Device gating: a machine without the RME sees nothing about it

- Every RME specific row, count, WARN, FAIL or error is gated on
  `modules/rme-adi2/detect` reporting the device present (standby counts as
  absent). That covers `audio-doctor`, `audit/footprint`, `config-audit`,
  `omarchy-audio-audit` and anything new.
- Gating applies to leftovers too: lingering RME named nodes (loopbacks such
  as the phones or input nodes, ALSA sinks) and RME config drop-ins on a
  machine where detect says absent must not be listed, counted in totals or
  reported as duplicates.
- A diff that adds RME output must add or extend a test that runs with detect
  forced absent and asserts zero RME lines and exit status unaffected.

## 3. Install, uninstall and other state changing paths

- A failed stop, disable or delete must keep the state needed to retry. Check
  the exit status of `systemctl disable/stop`, `rm`, `mktemp` and manifest
  writes before removing the manifest, state file or marker that a second run
  would need. Look for `cmd; rm state` or `cmd || true; rm state` patterns.
- A failed step exits non zero and names what is left behind; it never
  reports success.
- Uninstall removes exactly what install recorded, nothing it did not create.
- No sudo in tests; at most one sudo per script, never retried in a loop.

## 4. Tests must prove they ran

- A test asserts on real output or real device or session state (command
  stdout, exit status, files written, `pw-dump`/`wpctl` readings), not on the
  fact that a script finished. A test that can pass with the tool missing or a
  no op body is a reject.
- No weakening: a diff may not loosen an assertion, delete a check, widen a
  match, add `|| true`, skip a case, add sleeps, raise timeouts or retry a step
  to get green. A flaky test is fixed at the root cause or deleted with the
  reason in the commit message.
- Tests run against the copy in the repo or worktree by path, never the
  installed command on PATH.

## 5. Privacy

- No home or vault paths, hostnames, IPs, device serials, keyring account
  names, session ids or real names in code, docs, tests or fixtures. Use `~`,
  `<host>` and placeholders.
