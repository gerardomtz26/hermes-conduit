#!/usr/bin/env python3
"""CI Gate: the single stable branch-protection verdict for Hermes Conduit.

The hosted jobs are a broad smoke gate (docs/CI.md): they must never be
required individually, so this job aggregates them into one stable status
context ("CI Gate").

Policy:
  plan        must be success
  build       must be success
  unit-smoke  must be success
  ui-smoke    must be success OR skipped (skipped is legitimate when the
              curated selection contains no UI classes)
  self-test   must be success (the CI-tooling regression suites - planner,
              lane-runner state machine, destination lookup, gate/contract
              tests - run as their own job so the expensive bash state-machine
              suite never delays or outlives planning)

Anything else - failure, cancelled, skipped upstream of a failure - fails the
gate.

This verdict covers the HOSTED smoke gate only. A release additionally needs
the Mac local exhaustive gate (scripts/local-ci-gate.sh) on the exact head;
that result is never produced by, and cannot be substituted by, this job.
"""

from __future__ import annotations

import argparse
import sys

REQUIRED_SUCCESS = ("plan", "build", "unit-smoke", "self-test")
UI_ALLOWED = ("success", "skipped")


def verdict(plan: str, build: str, unit_smoke: str, ui_smoke: str,
            self_test: str) -> tuple:
    """Return (passed, reason). Reason lists every violated expectation."""
    results = {"plan": plan, "build": build, "unit-smoke": unit_smoke,
               "ui-smoke": ui_smoke, "self-test": self_test}
    failures = []
    for name in REQUIRED_SUCCESS:
        if results[name] != "success":
            failures.append(f"{name} must be 'success', got {results[name]!r}")
    if results["ui-smoke"] not in UI_ALLOWED:
        failures.append(
            "ui-smoke must be 'success' or 'skipped', got "
            f"{results['ui-smoke']!r}")
    return (not failures), "; ".join(failures)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--unit-smoke", required=True, dest="unit_smoke")
    parser.add_argument("--ui-smoke", required=True, dest="ui_smoke")
    parser.add_argument("--self-test", required=True)
    args = parser.parse_args(argv)

    passed, reason = verdict(args.plan, args.build, args.unit_smoke,
                             args.ui_smoke, args.self_test)
    if passed:
        print("CI Gate: PASS (plan/build/unit-smoke/self-test succeeded; "
              f"ui-smoke {args.ui_smoke!r})")
        return 0
    print(f"CI Gate: FAIL - {reason}")
    print("::error::CI Gate failed: " + reason)
    return 1


if __name__ == "__main__":
    sys.exit(main())
