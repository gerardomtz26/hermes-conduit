"""Regression coverage for scripts/classify-coreaudio-wedge.py.

The classifier is the fail-closed gate between "real product test failure"
and "CoreAudio host wedge authorized for bounded recovery". These tests pin
the two-condition rule with synthetic logs: a strong host signature is
never sufficient on its own, and a single incidental AURemoteIO line is
never a wedge.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

from _util import SCRIPTS_DIR

SPEC = importlib.util.spec_from_file_location(
    "classify_coreaudio_wedge",
    os.path.join(SCRIPTS_DIR, "classify-coreaudio-wedge.py"))
classifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(classifier)

INVENTORY = os.path.join(SCRIPTS_DIR, "audio-sensitive-tests.json")

AUDIO_CLASS = "AppStateVoiceSuspensionTests"
OTHER_AUDIO_CLASS = "CarPlayVoiceCoordinatorTests"
PLAIN_CLASS = "AppStateChatResumeTests"


def wedge_log(path, auremoteio=200, halc=40, chhaptic=5):
    """Synthetic invocation log carrying a configurable wedge signature."""
    with open(path, "w", encoding="utf-8") as fh:
        for _ in range(auremoteio):
            fh.write("2026-09-14 00:00:00.000 Conduit[9:9] [aurioc]"
                     "            AURemoteIO.cpp:1135  failed: -10851"
                     " (enable 1, outf< 2 ch,      0 Hz>)\n")
        for _ in range(halc):
            fh.write("2026-09-14 00:00:00.000 Conduit[9:9] [AMCP]"
                     "          HALC_ProxyIOContext.cpp:1623"
                     "  HALC_ProxyIOContext::IOWorkLoop: skipping cycle"
                     " due to overload\n")
        for _ in range(chhaptic):
            fh.write("2026-09-14 00:00:00.000 Conduit[9:9] [hapi]"
                     "         CHHapticEngine.mm:1007  ERROR: Invalid audio"
                     " session ID: 0\n")
    return path


def detail_doc(path, failed_classes):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"schema_version": 1,
                   "failures": [{"class": c, "test": "testX()"}
                                for c in failed_classes]}, fh)
    return path


class ClassifierCliTests(unittest.TestCase):
    """End-to-end CLI verdicts. Exit 0 = wedge (recovery authorized),
    exit 1 = real product failure (fail closed), exit 2 = unusable inputs."""

    def _run(self, log, detail, extra=None):
        return subprocess.run(
            [sys.executable,
             os.path.join(SCRIPTS_DIR, "classify-coreaudio-wedge.py"),
             "--invocation-log", str(log), "--detail", str(detail)] + (extra or []),
            capture_output=True, text=True)

    def test_strong_signature_with_inventory_failures_classifies_wedge(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "attempt-1.log"))
            detail = detail_doc(os.path.join(tmp, "detail.json"),
                                [AUDIO_CLASS, OTHER_AUDIO_CLASS])
            proc = self._run(log, detail)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            verdict = json.loads(proc.stdout)
            self.assertTrue(verdict["wedge"])
            self.assertTrue(verdict["signature_strong"])
            self.assertEqual(verdict["audio_sensitive_failures"],
                             [AUDIO_CLASS, OTHER_AUDIO_CLASS])
            self.assertEqual(verdict["outside_inventory_failures"], [])

    def test_normal_assertion_failure_without_signature_is_real(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "attempt-1.log"),
                            auremoteio=0, halc=0, chhaptic=0)
            detail = detail_doc(os.path.join(tmp, "detail.json"), [AUDIO_CLASS])
            proc = self._run(log, detail)
            self.assertEqual(proc.returncode, 1)
            self.assertFalse(json.loads(proc.stdout)["wedge"])

    def test_single_incidental_auremoteio_line_is_not_a_wedge(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "attempt-1.log"),
                            auremoteio=1, halc=0, chhaptic=0)
            detail = detail_doc(os.path.join(tmp, "detail.json"), [AUDIO_CLASS])
            proc = self._run(log, detail)
            self.assertEqual(proc.returncode, 1)
            self.assertEqual(json.loads(proc.stdout)["signals"]["auremoteio_10851"], 1)

    def test_signature_without_inventory_failures_is_real(self):
        # A wedge that starves ordinary classes must NOT authorize recovery:
        # those failures stay honest product failures.
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "attempt-1.log"))
            detail = detail_doc(os.path.join(tmp, "detail.json"), [PLAIN_CLASS])
            proc = self._run(log, detail)
            self.assertEqual(proc.returncode, 1)
            verdict = json.loads(proc.stdout)
            self.assertFalse(verdict["wedge"])
            self.assertTrue(verdict["signature_strong"])
            self.assertEqual(verdict["outside_inventory_failures"], [PLAIN_CLASS])

    def test_one_failure_outside_inventory_voids_the_wedge(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "attempt-1.log"))
            detail = detail_doc(os.path.join(tmp, "detail.json"),
                                [AUDIO_CLASS, PLAIN_CLASS])
            proc = self._run(log, detail)
            self.assertEqual(proc.returncode, 1)
            verdict = json.loads(proc.stdout)
            self.assertFalse(verdict["wedge"])
            self.assertEqual(verdict["outside_inventory_failures"], [PLAIN_CLASS])
            # The unrelated failure stays visible for the lane report.
            self.assertIn(PLAIN_CLASS, verdict["failed_classes"])
            self.assertIn(AUDIO_CLASS, verdict["audio_sensitive_failures"])

    def test_signature_with_no_identified_failures_is_real(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "attempt-1.log"))
            detail = detail_doc(os.path.join(tmp, "detail.json"), [])
            proc = self._run(log, detail)
            self.assertEqual(proc.returncode, 1)

    def test_ambient_healthy_lane_volume_is_not_a_wedge(self):
        # Healthy unit-2 lanes emit ~107 ambient AURemoteIO lines and a
        # handful of HALC skips - below the joint signature on purpose.
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "attempt-1.log"),
                            auremoteio=107, halc=7, chhaptic=11)
            detail = detail_doc(os.path.join(tmp, "detail.json"), [AUDIO_CLASS])
            proc = self._run(log, detail)
            self.assertEqual(proc.returncode, 1)
            self.assertFalse(json.loads(proc.stdout)["signature_strong"])

    def test_threshold_flags_are_overridable(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "attempt-1.log"),
                            auremoteio=20, halc=5, chhaptic=0)
            detail = detail_doc(os.path.join(tmp, "detail.json"), [AUDIO_CLASS])
            lowered = self._run(log, detail,
                                ["--min-auremoteio", "10", "--min-halc-overload", "4"])
            self.assertEqual(lowered.returncode, 0, lowered.stdout)
            raised = self._run(log, detail,
                               ["--min-auremoteio", "500", "--min-halc-overload", "4"])
            self.assertEqual(raised.returncode, 1)

    def test_unreadable_inputs_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = self._run(os.path.join(tmp, "missing.log"),
                             os.path.join(tmp, "missing.json"))
            self.assertEqual(proc.returncode, 2)

    def test_out_document_matches_stdout_verdict(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "attempt-1.log"))
            detail = detail_doc(os.path.join(tmp, "detail.json"), [AUDIO_CLASS])
            out_path = os.path.join(tmp, "wedge.json")
            proc = self._run(log, detail, ["--out", out_path])
            self.assertEqual(proc.returncode, 0)
            with open(out_path, encoding="utf-8") as fh:
                doc = json.load(fh)
            self.assertTrue(doc["wedge"])
            self.assertEqual(doc["signals"]["auremoteio_10851"], 200)
            self.assertEqual(doc["signals"]["halc_overload"], 40)


class ClassifierUnitTests(unittest.TestCase):
    def test_counts_are_per_invocation_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "a.log"), auremoteio=3,
                            halc=1, chhaptic=2)
            signals = classifier.count_signals(log)
            self.assertEqual(signals, {"auremoteio_10851": 3,
                                       "halc_overload": 1,
                                       "chhaptic_engine": 2})

    def test_failed_classes_are_distinct_and_ordered(self):
        with tempfile.TemporaryDirectory() as tmp:
            detail = os.path.join(tmp, "detail.json")
            with open(detail, "w", encoding="utf-8") as fh:
                json.dump({"failures": [
                    {"class": AUDIO_CLASS, "test": "testB()"},
                    {"class": AUDIO_CLASS, "test": "testA()"},
                    {"class": PLAIN_CLASS, "test": "testC()"},
                ]}, fh)
            self.assertEqual(
                classifier.load_failed_classes(detail),
                [AUDIO_CLASS, PLAIN_CLASS])

    def test_real_inventory_loads_and_is_authoritative(self):
        classes = classifier.load_inventory_classes(INVENTORY)
        self.assertIn(AUDIO_CLASS, classes)
        self.assertIn(OTHER_AUDIO_CLASS, classes)


if __name__ == "__main__":
    unittest.main()
