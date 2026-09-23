#!/usr/bin/env python3
"""Render the hosted smoke selection (scripts/plan-tests.py smoke output) as
Markdown for the GitHub step summary.

Kept as a script rather than inline YAML so the wording and the split between
hosted smoke coverage and Mac-gate-owned coverage are reviewable, and so the
summary can be asserted in the CI-tooling tests.
"""

from __future__ import annotations

import argparse
import json
import sys


def render(selection: dict) -> str:
    unit = list(selection.get("unit") or [])
    ui = list(selection.get("ui") or [])
    lines = [
        "### Hosted smoke gate",
        "",
        "This run exercises the curated smoke slice. The exhaustive unit/UI",
        "suites and the timing/performance/dormancy families are certified by",
        "the Mac local gate (`scripts/local-ci-gate.sh`) for a trusted head;",
        "they are deliberately not run here.",
        "",
        f"- unit smoke classes: **{len(unit)}** of {selection.get('inventory_unit')}",
        f"- UI smoke classes: **{len(ui)}** of {selection.get('inventory_ui')}",
        "- delegated to the Mac exhaustive gate: "
        f"{selection.get('delegated_unit')} unit + "
        f"{selection.get('delegated_ui')} UI classes",
        "",
        "unit: " + ", ".join(unit),
        "",
        "UI: " + ", ".join(ui),
        "",
    ]
    return "\n".join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selection", required=True,
                        help="JSON written by `plan-tests.py smoke --out`")
    args = parser.parse_args(argv)

    with open(args.selection, encoding="utf-8") as fh:
        selection = json.load(fh)
    if not selection.get("unit"):
        print("::error::smoke selection is empty - hosted CI would run no unit tests")
        return 1
    sys.stdout.write(render(selection))
    return 0


if __name__ == "__main__":
    sys.exit(main())
