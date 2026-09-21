"""Runner for the local-gate shell integration suite.

The assertions live in scripts/tests/test_local_ci_gate.sh; this wrapper makes
them part of the standard unittest discovery run. The suite drives the real
scripts/local-ci-gate.sh against stub xcodegen/xcodebuild/xcrun binaries in a
throwaway repository, so it needs no Xcode and no macOS - it runs on the Linux
CI job too.

Measured cost: a few seconds (the stubs exit instantly), so unlike the
lane-runner state-machine suite it does NOT need the
CONDUIT_CI_SKIP_BASH_WRAPPER_TESTS opt-out.
"""

import os
import shutil
import subprocess
import unittest

from _util import SCRIPTS_DIR

SCRIPT = os.path.join(SCRIPTS_DIR, "tests", "test_local_ci_gate.sh")


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"),
                     "bash is required to exercise the gate script")
@unittest.skipUnless(shutil.which("git"), "git is required by the gate")
class LocalGateScriptTests(unittest.TestCase):
    def test_local_gate_integration_suite(self):
        proc = subprocess.run(["bash", SCRIPT], capture_output=True,
                              text=True, timeout=600)
        if proc.returncode != 0:
            self.fail("local-gate integration suite failed:\n"
                      + proc.stdout[-6000:] + proc.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
