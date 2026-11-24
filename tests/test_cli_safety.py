#!/usr/bin/env python3
"""Offline safety and portability tests for the audio-doctor kit.

Runs with no audio, no device, no sudo, and no writes to the real HOME.
"""
import importlib.util
from importlib.machinery import SourceFileLoader
import json
import os
import subprocess as sp
import sys
import tempfile
import unittest
from unittest import mock

REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


def load_script(relpath, modname):
    path = os.path.join(REPO, relpath)
    loader = SourceFileLoader(modname, path)
    spec = importlib.util.spec_from_loader(modname, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class CliHelpAndSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ad-cli-test-")
        self.home = os.path.join(self.tmp, "home")
        self.guard = os.path.join(self.tmp, "guard")
        os.makedirs(self.home)
        os.makedirs(self.guard)
        self.called = os.path.join(self.guard, "called")
        open(self.called, "w").close()
        for tool in ("pw-play", "pw-cat", "pw-record", "pw-metadata", "pw-dump", "pw-top", "pactl", "adi2", "sudo", "stress-ng"):
            p = os.path.join(self.guard, tool)
            with open(p, "w") as f:
                f.write(f'#!/bin/sh\necho "{tool} $*" >>"{self.called}"\nexit 1\n')
            os.chmod(p, 0o755)
        self.env = os.environ.copy()
        self.env.update({
            "HOME": self.home,
            "XDG_CONFIG_HOME": os.path.join(self.home, ".config"),
            "XDG_DATA_HOME": os.path.join(self.home, ".local", "share"),
            "XDG_STATE_HOME": os.path.join(self.home, ".local", "state"),
            "PATH": f"{self.guard}:{os.environ.get('PATH', '')}",
        })

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_cmd(self, relpath, *args):
        return sp.run([os.path.join(REPO, relpath), *args], env=self.env, capture_output=True, text=True, timeout=15)

    def assert_guard_unused(self):
        with open(self.called) as f:
            called = f.read().strip()
        self.assertEqual(called, "", f"Guard stubs were executed:\n{called}")

    def test_help_flags_exit_0_without_side_effects(self):
        cases = [
            ("audio-doctor", "usage: audio-doctor"),
            ("config-audit", "usage: config-audit"),
            ("whatis", "whatis"),
            ("omarchy-audio-audit", "usage: omarchy-audio-audit"),
            ("omarchy-audio-watch", "omarchy-audio-watch"),
            ("audit/footprint", "usage: footprint"),
        ]
        for script, expected in cases:
            for flag in ("-h", "--help"):
                with self.subTest(script=script, flag=flag):
                    r = self.run_cmd(script, flag)
                    self.assertEqual(r.returncode, 0, f"{script} {flag} stderr={r.stderr}")
                    self.assertIn(expected, r.stdout)
                    self.assertEqual(r.stderr, "")
        self.assert_guard_unused()
        self.assertFalse(os.path.exists(os.path.join(self.home, ".local", "state")))

    def test_unknown_flags_exit_2_without_side_effects(self):
        cases = [
            ("audio-doctor", ("--no-such-flag",)),
            ("audio-doctor", ("--secs",)),
            ("audio-doctor", ("--secs", "0")),
            ("config-audit", ("--no-such-flag",)),
            ("whatis", ("--no-such-flag",)),
            ("omarchy-audio-audit", ("--no-such-flag",)),
            ("omarchy-audio-audit", ("--sudo", "bogus")),
            ("omarchy-audio-watch", ("--no-such-flag",)),
            ("omarchy-audio-watch", ("report",)),
            ("audit/footprint", ("--no-such-flag",)),
            ("audit/footprint", ("compare", "onlyone")),
            ("audit/footprint", ("bad/name",)),
        ]
        for script, args in cases:
            with self.subTest(script=script, args=args):
                r = self.run_cmd(script, *args)
                self.assertEqual(r.returncode, 2, f"{script} {args}: rc={r.returncode} stdout={r.stdout} stderr={r.stderr}")
                self.assertEqual(r.stdout, "")
                self.assertTrue(r.stderr.strip())
        self.assert_guard_unused()
        self.assertFalse(os.path.exists(os.path.join(self.home, ".local", "state")))


class AudioWatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.watch = load_script("omarchy-audio-watch", "test_audio_watch_mod")

    def test_pw_errs_tracks_generic_hardware_and_daws_and_gates_rme(self):
        sample = "\n".join([
            "S   ID  QUANT   RATE    WAIT    BUSY   W/Q   B/Q  ERR FORMAT           NAME",
            "R   40    128  48000  10.0us   5.0us  ???   0.00    0    S32LE 2 48000 alsa_output.usb-Focusrite_Scarlett-00.pro-output-0",
            "R   40    128  48000  10.0us   5.0us  0.01  0.01    3    S32LE 2 48000 alsa_output.usb-Focusrite_Scarlett-00.pro-output-0",
            "R   41    128  48000  10.0us   5.0us  0.01  0.01    7    F32LE 2 48000  + REAPER",
            "R   42    128  48000  10.0us   5.0us  0.01  0.01    9    S32LE 2 48000 alsa_output.usb-RME_ADI-2_Pro__x-00.pro-output-0",
            "R   43    128  48000  10.0us   5.0us  0.01  0.01    4    F32LE 2 48000  + rme_phones",
            "R   44    128  48000  10.0us   5.0us  ???   0.00    0    F32LE 2 48000  + Ardour",
        ])
        off = self.watch.pw_errs(rme=False, out=sample)
        self.assertEqual(off, {
            "alsa_output.usb-Focusrite_Scarlett-00.pro-output-0#40": 3,
            "REAPER#41": 7,
        })
        on = self.watch.pw_errs(rme=True, out=sample)
        self.assertIn("alsa_output.usb-RME_ADI-2_Pro__x-00.pro-output-0#42", on)
        self.assertEqual(on["alsa_output.usb-RME_ADI-2_Pro__x-00.pro-output-0#42"], 9)
        # Unmeasured Ardour row (W/Q == ???) must be skipped
        self.assertNotIn("Ardour#44", on)

    def test_report_html_is_generic_without_gpu(self):
        with tempfile.TemporaryDirectory(prefix="ad-watch-rep-") as d:
            old_dir, old_events = self.watch.DIR, self.watch.EVENTS
            try:
                self.watch.DIR = d
                self.watch.EVENTS = os.path.join(d, "events.jsonl")
                samples = [
                    {"ts": "2026-11-23T10:00:00", "activity": "idle", "gpu": None,
                     "cpu": {"temp": 48.0, "busy_pct": 5.0, "throttle_ms": 0, "avg_mhz": 3200},
                     "nvme": {}, "xruns": 0, "xid": [], "self_cpu_s": 0.01},
                    {"ts": "2026-11-23T10:00:30", "activity": "daw", "gpu": None,
                     "cpu": {"temp": 55.0, "busy_pct": 25.0, "throttle_ms": 0, "avg_mhz": 4100},
                     "nvme": {}, "xruns": 2, "xid": [], "self_cpu_s": 0.01},
                ]
                with open(os.path.join(d, "2026-11-23.jsonl"), "w") as f:
                    for s in samples:
                        f.write(json.dumps(s) + "\n")
                out = os.path.join(d, "report.html")
                self.watch.cmd_report(out, None)
                with open(out) as fh:
                    html = fh.read()
                self.assertIn("Audio watch report", html)
                self.assertIn("PipeWire xruns per sample", html)
                self.assertNotIn("4090", html)
                self.assertNotIn("tensor unlock", html)
                self.assertNotIn("RME/Bitwig", html)
                self.assertNotIn("GPU power", html)
            finally:
                self.watch.DIR, self.watch.EVENTS = old_dir, old_events


class PortabilityAndGatingTests(unittest.TestCase):
    def test_audio_doctor_hardware_handles_missing_proc_and_sysfs(self):
        ad = load_script("audio-doctor", "test_audio_doctor_mod")
        real_open = open

        def fake_open(path, *a, **kw):
            if path == "/proc/asound/cards" or str(path).endswith("/bInterfaceClass"):
                raise OSError("missing")
            return real_open(path, *a, **kw)

        with mock.patch("builtins.open", side_effect=fake_open), \
             mock.patch.object(os, "listdir", return_value=["1-1:1.0"]), \
             mock.patch.object(ad, "run", return_value=""):
            hw = ad.hardware()
        self.assertEqual(hw, {"alsa_cards": [], "usb_audio": [], "bt_connected": []})

    def test_config_audit_skips_duplicate_rme_nodes_when_absent(self):
        ca = load_script("config-audit", "test_config_audit_mod")
        f1 = "/tmp/fake1.conf"
        f2 = "/tmp/fake2.conf"
        fake_data = {"context.modules": [{"args": {"capture.props": {"node.name": "rme_phones"}}}]}
        with mock.patch.object(ca, "conf_files", return_value=[(("pipewire", "pipewire.conf.d", "a.conf"), f1),
                                                               (("pipewire", "pipewire.conf.d", "b.conf"), f2)]), \
             mock.patch.object(ca, "parse", return_value=(fake_data, None)), \
             mock.patch.object(ca, "live_graph", return_value=({}, {}, [], {})), \
             mock.patch.object(ca, "card_profiles", return_value={}):
            findings, _ = ca.audit(dump=[], fix=False, rme=False)
        self.assertFalse(any(f["check"] == "dupes" for f in findings), findings)
        self.assertTrue(any(f["check"] == "rme" and f["message"] == ca.RME_OFF for f in findings), findings)

    def test_keepalive_has_no_adi2_set(self):
        with open(os.path.join(REPO, "modules", "rme-adi2", "bin", "studio-keepalive")) as fh:
            ka = fh.read()
        self.assertNotRegex(ka, r"adi2\s+set")

    def test_audit_sudo_mode_and_pw_top_rme_gating(self):
        audit = load_script("omarchy-audio-audit", "test_audio_audit_mod")
        self.assertEqual(audit.resolve_sudo_mode(None, True), "prompt")
        self.assertEqual(audit.resolve_sudo_mode(None, False), "ntfy")
        self.assertEqual(audit.resolve_sudo_mode("keyring", True), "keyring")

        # Prompt mode runs sudo -v on TTY when uncached, then sudo -n for the helper
        fake_proc = mock.MagicMock()
        calls = []

        def fake_sp_run(cmd, **kw):
            calls.append(cmd)
            if cmd == ["sudo", "-n", "true"]:
                return sp.CompletedProcess(cmd, 1)
            return sp.CompletedProcess(cmd, 0)

        with mock.patch.object(audit.sp, "run", side_effect=fake_sp_run), \
             mock.patch.object(audit.sp, "Popen", return_value=fake_proc) as popen:
            h, err = audit.start_root_helper("/tmp/out", "", "prompt", lambda _: None)
        self.assertIsNone(err)
        self.assertIs(h, fake_proc)
        self.assertEqual(calls, [["sudo", "-n", "true"], ["sudo", "-v"]])
        self.assertEqual(popen.call_args[0][0][:2], ["sudo", "-n"])

        # pw_top hides lingering RME nodes when RME_ON is False
        sample = "\n".join([
            "S   ID  QUANT   RATE    WAIT    BUSY   W/Q   B/Q  ERR FORMAT           NAME",
            "R   40    128  48000  10.0us   5.0us  0.01  0.01    1    S32LE 2 48000 alsa_output.usb-Focusrite_Scarlett-00.pro-output-0",
            "R   41    128  48000  10.0us   5.0us  0.01  0.01    2    F32LE 2 48000  + rme_phones",
        ])
        audit.RME_ON = False
        with mock.patch.object(audit, "run", return_value=sp.CompletedProcess(["pw-top"], 0, sample, "")):
            rows = audit.pw_top()
        self.assertIn("alsa_output.usb-Focusrite_Scarlett-00.pro-output-0", rows)
        self.assertNotIn("rme_phones", rows)


if __name__ == "__main__":
    unittest.main()
