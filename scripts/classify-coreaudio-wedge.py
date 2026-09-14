#!/usr/bin/env python3
"""CoreAudio wedge classifier for Hermes Conduit CI (scripts/classify-coreaudio-wedge.py).

Decides whether a failed unit-lane invocation is the known GitHub-hosted
macOS CoreAudio infrastructure wedge - in which case the lane runner may
reset the simulator and retry ONLY the affected audio-sensitive classes -
or an ordinary product test failure, which must fail the lane.

Why this exists (evidence, run 34822043959 retried 8x over 5.5h):
  * A broken hosted audio host does not fail loudly. It floods the test
    process with `AURemoteIO.cpp:1135 failed: -10851` lines and HAL
    `skipping cycle due to overload` lines, and the starvation flips
    timing-sensitive assertions in the audio-sensitive classes listed in
    scripts/audio-sensitive-tests.json. The invocation exits 65 with
    ordinary assertion records, so the previous policy classified it as a
    product failure and a human re-ran the lane by hand.

The two-condition rule (BOTH required - fail closed):

  1. Strong host signature in the invocation log:
       - `AURemoteIO ... failed: -10851` occurrences >= min-auremoteio
         (default 150), AND
       - `skipping cycle due to overload` (HALC_ProxyIOContext) occurrences
         >= min-halc-overload (default 20).
     Observed distributions this is calibrated against (see docs/CI.md):
       healthy unit-1      aurioc ~8    overload ~0-2
       healthy unit-2      aurioc ~107  overload ~7     (ambient maximum)
       slow-timeout unit-1 aurioc ~48   overload ~4     (NOT the audio wedge)
       wedged unit-2       aurioc 184-186 (3 attempts)  overload 48
     A single AURemoteIO line - even a handful - is NORMAL on healthy hosts
     and must never classify an invocation as infrastructure.

  2. Every failed test class belongs to the audio-sensitive inventory
     (scripts/audio-sensitive-tests.json). One failure outside the
     inventory - or a wedge signature with NO identified failures - is a
     real failure. The inventory is evidence-based and deliberately narrow;
     the wedge starves async state machines host-wide, so a real regression
     anywhere else must stay a product failure.

Exit codes
----------
  0  infrastructure wedge; recovery is authorized (JSON also on stdout)
  1  not classified as a wedge: real product failure (fail closed)
  2  usage/IO error: the runner MUST treat this as "not a wedge"

The JSON document (also written to --out when given) always carries the raw
signal counts so incidents can be recalibrated and tracked over time.
Only Python 3 stdlib is used (runs on ubuntu and macOS runners).
"""

from __future__ import annotations

import argparse
import json
import os
import sys

DEFAULT_INVENTORY = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "audio-sensitive-tests.json")
DEFAULT_MIN_AUREMOTEIO = 150
DEFAULT_MIN_HALC_OVERLOAD = 20

# AURemoteIO activation failure with the exact error code observed under the
# wedge (-10851). Healthy hosts log a limited amount of ambient noise from
# AppState construction; the count gate, not the mere presence, is the signal.
AUREMOTEIO_MARK = "AURemoteIO"
AUREMOTEIO_CODE = "-10851"
# HALC (CoreAudio HAL client proxy) reporting its IO work loop is overloaded:
# the host-side "audio server is drowning" marker. Absent-to-rare on healthy
# hosts (<=7 per lane observed), burst-scale under the wedge (48 observed).
HALC_OVERLOAD_MARK = "skipping cycle due to overload"
# Corroborating (reported, not gated): CHHapticEngine errors. 11 on healthy
# hosts vs 20 under the wedge - not discriminative enough to gate on.
CHHAPTIC_MARK = "CHHapticEngine"


def count_signals(invocation_log: str) -> dict:
    """One pass over the invocation log counting the audio-host markers.

    The log is xcodebuild's stdout for ONE invocation (the lane runner
    already persists it per attempt), so counts are per-invocation by
    construction."""
    auremoteio = 0
    halc_overload = 0
    chhaptic = 0
    with open(invocation_log, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if AUREMOTEIO_MARK in line and AUREMOTEIO_CODE in line:
                auremoteio += 1
            if HALC_OVERLOAD_MARK in line:
                halc_overload += 1
            if CHHAPTIC_MARK in line:
                chhaptic += 1
    return {
        "auremoteio_10851": auremoteio,
        "halc_overload": halc_overload,
        "chhaptic_engine": chhaptic,
    }


def load_inventory_classes(path: str) -> list:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    classes = doc.get("classes")
    if not isinstance(classes, list) or not all(isinstance(c, str) for c in classes):
        raise ValueError(f"inventory {path}: 'classes' must be a list of strings")
    return classes


def load_failed_classes(detail_path: str) -> list:
    """Distinct failed test classes from an extraction detail document, in a
    deterministic order. An unreadable/empty document yields no failures,
    which can never authorize recovery."""
    with open(detail_path, encoding="utf-8") as fh:
        doc = json.load(fh)
    failed = doc.get("failures")
    if not isinstance(failed, list):
        raise ValueError(f"detail {detail_path}: 'failures' must be a list")
    seen = set()
    ordered = []
    for failure in failed:
        cls = failure.get("class") if isinstance(failure, dict) else None
        if cls and cls not in seen:
            seen.add(cls)
            ordered.append(cls)
    return ordered


def classify(signals: dict, failed_classes: list, inventory: list,
             min_auremoteio: int, min_halc_overload: int) -> dict:
    inventory_set = set(inventory)
    audio_failures = [c for c in failed_classes if c in inventory_set]
    outside = [c for c in failed_classes if c not in inventory_set]
    signature = (signals["auremoteio_10851"] >= min_auremoteio
                 and signals["halc_overload"] >= min_halc_overload)
    # BOTH conditions. No identified failures -> never a wedge; any failure
    # outside the inventory -> never a wedge (a real regression must not be
    # rescuable, and the wedge can starve ordinary classes' async assertions
    # too - those stay honest product failures).
    wedge = bool(audio_failures) and not outside and signature
    return {
        "wedge": wedge,
        "signals": signals,
        "thresholds": {
            "min_auremoteio_10851": min_auremoteio,
            "min_halc_overload": min_halc_overload,
        },
        "signature_strong": signature,
        "failed_classes": failed_classes,
        "audio_sensitive_failures": audio_failures,
        "outside_inventory_failures": outside,
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--invocation-log", required=True,
                        help="xcodebuild stdout log of the failed invocation")
    parser.add_argument("--detail", required=True,
                        help="extraction detail.json carrying failures[]")
    parser.add_argument("--inventory", default=DEFAULT_INVENTORY,
                        help="audio-sensitive class inventory JSON")
    parser.add_argument("--min-auremoteio", type=int,
                        default=DEFAULT_MIN_AUREMOTEIO)
    parser.add_argument("--min-halc-overload", type=int,
                        default=DEFAULT_MIN_HALC_OVERLOAD)
    parser.add_argument("--out", default="",
                        help="also write the classification JSON here")
    args = parser.parse_args(argv)

    try:
        signals = count_signals(args.invocation_log)
        inventory = load_inventory_classes(args.inventory)
        failed_classes = load_failed_classes(args.detail)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"::warning::coreaudio-wedge classifier could not read its "
              f"inputs ({exc}) - failing closed as a product failure")
        return 2

    verdict = classify(signals, failed_classes, inventory,
                       args.min_auremoteio, args.min_halc_overload)
    text = json.dumps(verdict, indent=2, sort_keys=True)
    if args.out:
        try:
            with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(text + "\n")
        except OSError as exc:
            print(f"::warning::could not write {args.out}: {exc}")
    print(text)
    return 0 if verdict["wedge"] else 1


if __name__ == "__main__":
    sys.exit(main())
