"""Runner for the gate-lock shell tests.

The assertions live in scripts/tests/test_gate_lock.sh; this wrapper makes
them part of the standard unittest discovery run (the same shape as
test_lane_runner.py). Skipped where there is no bash.
"""

import os
import shutil
import subprocess
import unittest

from _util import SCRIPTS_DIR

SCRIPT = os.path.join(SCRIPTS_DIR, "tests", "test_gate_lock.sh")


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"),
                     "bash is required to exercise the lock module")
class GateLockScriptTests(unittest.TestCase):
    def test_gate_lock_semantics(self):
        proc = subprocess.run(["bash", SCRIPT], capture_output=True,
                              text=True, timeout=120)
        if proc.returncode != 0:
            self.fail("gate-lock test suite failed:\n"
                      + proc.stdout[-4000:] + proc.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
