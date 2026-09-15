#!/usr/bin/env python3
"""Split the planner's current unit-2 lane for one diagnostic CI experiment.

This intentionally does not change the production planner.  It consumes the
normal unit matrix and emits only two experimental jobs:

* unit-2-audio: classes whose names contain Audio, Voice, or CarPlay
* unit-2-rest: every other class from the original unit-2 lane

The original unit-2 watchdog and outer job ceiling are preserved for both
halves so the experiment changes workload composition, not timeout policy.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

AUDIO_TOKENS = ("Audio", "Voice", "CarPlay")


def parse_estimates(raw: str) -> dict[str, float]:
    estimates: dict[str, float] = {}
    for pair in raw.split(","):
        if not pair:
            continue
        if "=" not in pair:
            raise ValueError(f"malformed class estimate: {pair!r}")
        name, value = pair.split("=", 1)
        estimates[name] = float(value)
    return estimates


def split_lane(matrix: dict) -> tuple[dict, list[str], list[str]]:
    include = matrix.get("include")
    if not isinstance(include, list):
        raise ValueError("matrix must contain an 'include' list")

    matches = [entry for entry in include if entry.get("lane") == "unit-2"]
    if len(matches) != 1:
        raise ValueError(f"expected exactly one unit-2 lane, found {len(matches)}")

    original = matches[0]
    classes = [name for name in str(original.get("classes", "")).split(",") if name]
    if not classes:
        raise ValueError("unit-2 has no classes")

    estimates = parse_estimates(str(original.get("class_estimates", "")))
    missing = [name for name in classes if name not in estimates]
    if missing:
        raise ValueError(f"unit-2 classes missing estimates: {missing}")

    audio = [name for name in classes if any(token in name for token in AUDIO_TOKENS)]
    rest = [name for name in classes if name not in set(audio)]
    if not audio:
        raise ValueError("audio split selected zero unit-2 classes")
    if not rest:
        raise ValueError("rest split selected zero unit-2 classes")

    def entry(name: str, members: list[str]) -> dict:
        split = dict(original)
        split["lane"] = name
        split["classes"] = ",".join(members)
        split["class_estimates"] = ",".join(
            f"{member}={estimates[member]:.1f}" for member in members
        )
        split["predicted_s"] = round(sum(estimates[member] for member in members), 1)
        # Deliberately preserve timeout_s and job_timeout_min from the original
        # unit-2 lane.  This keeps timeout policy out of the experiment.
        return split

    return {"include": [entry("unit-2-audio", audio), entry("unit-2-rest", rest)]}, audio, rest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--summary", required=True, type=Path)
    args = parser.parse_args()

    with args.input.open(encoding="utf-8") as fh:
        matrix = json.load(fh)

    split, audio, rest = split_lane(matrix)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(split, indent=2) + "\n", encoding="utf-8")

    summary = [
        "## Unit-2 audio split experiment",
        "",
        "The normal planner generated `unit-2`; this diagnostic split only that lane.",
        "Both halves retain the original unit-2 watchdog and outer job ceiling.",
        "",
        f"- `unit-2-audio`: **{len(audio)}** classes matched `Audio`, `Voice`, or `CarPlay`.",
        f"- `unit-2-rest`: **{len(rest)}** remaining classes.",
        "",
        "<details><summary>Audio/Voice/CarPlay classes</summary>",
        "",
        *[f"- `{name}`" for name in audio],
        "",
        "</details>",
        "",
    ]
    args.summary.write_text("\n".join(summary), encoding="utf-8")

    print(
        f"split unit-2 into {len(audio)} audio/voice/CarPlay classes "
        f"and {len(rest)} remaining classes"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
