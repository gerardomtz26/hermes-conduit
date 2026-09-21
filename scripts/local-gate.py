#!/usr/bin/env python3
"""Local exhaustive gate helpers for Hermes Conduit (see docs/CI.md).

`scripts/local-ci-gate.sh` owns the orchestration (worktree isolation, build
once, phase sequencing). This script owns everything that is *data*: it
projects the planner's plan into the exact invocation parameters the existing
lane runner wants, and it assembles the machine-readable gate result from the
artifacts the lane runner already writes.

Nothing here re-implements test discovery, batching, watchdog policy, or
xcresult parsing - those stay owned by plan-tests.py, ci-test-lane.sh and
extract-test-timings.py. This file only *projects* their outputs and *reads*
their results, so the gate cannot drift from the policy they enforce.

Subcommands
-----------
lanes          Project plan.json into lane-runner parameters for the gate's
               single unit lane and single UI lane.
repeat-spec    Project plan.json into per-class repeat tasks (explicit repeat
               policy for timing/performance-sensitive classes).
meta           Write the run's identity document (ref, resolved SHA, Xcode,
               simulator, expected counts, flags).
simulator      Pick the simulator/device the run actually used out of
               `xcrun simctl list devices available -j`.
phase          Write one non-lane phase's status document.
summarize      Assemble gate-result.json + summary.md, and exit 0 only when
               the whole gate passed.

Exit codes: 0 ok, 1 verdict FAIL, 2 usage error, 3 malformed artifact.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys

SCHEMA_VERSION = 1

# Attempt-status tokens emitted by ci-test-lane.sh (record_attempt /
# record_batch_attempt). The gate must classify on the runner's own tokens
# rather than re-deriving a verdict from logs.
ASSERTION_FAILURE_STATUSES = ("test-failures",)
# Environment/classification failures: the invocation did not produce a
# usable "this test asserted" verdict. ci-test-lane.sh only ever records
# `infra-error` for a nonzero exit with a KNOWN zero failing-test count;
# `unclassified`/`incomplete` mean the result could not be read at all.
INFRASTRUCTURE_STATUSES = ("infra-error", "unclassified", "incomplete")
TIMEOUT_STATUSES = ("timeout",)
NOT_EXECUTED_STATUSES = ("not_run", "not_diagnosed")
# Modes that mean "this was a second attempt at work a previous attempt
# already ran" (the runner's bounded recovery, never a policy of its own).
RETRY_MODES = ("batch-retry", "class-retry")

REPEAT_BATCH_TIMEOUT_CAP_DEFAULT = 900

HEX40 = re.compile(r"^[0-9a-f]{40}$")


def warn(msg: str) -> None:
    print("local-gate: warning: {0}".format(msg), file=sys.stderr)


def fail(msg: str) -> None:
    print("local-gate: error: {0}".format(msg), file=sys.stderr)


def load_json(path: str):
    """Best-effort read. Returns None for anything unusable - every caller
    treats a missing artifact as "not certifiable", never as "fine"."""
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def write_json(path: str, doc) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(doc, indent=2, sort_keys=True) + "\n")


def write_env(path: str, mapping) -> None:
    """Write a shell-sourceable KEY=value file.

    Values are shell-quoted with shlex.quote, so a class name can never
    become code in the gate shell even though the names ultimately come from
    the repository's own sources.
    """
    directory = os.path.dirname(os.path.abspath(path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        for key in sorted(mapping):
            fh.write("{0}={1}\n".format(key, shlex.quote(str(mapping[key]))))


def _csv(values) -> str:
    return ",".join(values)


def _single_lane(plan: dict, key: str) -> dict:
    """The gate runs the whole suite as exactly ONE lane per kind. The plan
    is generated with --min-lanes/--max-lanes forced to 1, so anything else
    is a policy violation and must fail closed."""
    lanes = plan.get(key)
    if not isinstance(lanes, list):
        return {}
    if len(lanes) != 1:
        return {}
    return lanes[0] if isinstance(lanes[0], dict) else {}


# ---------------------------------------------------------------------------
# lanes
# ---------------------------------------------------------------------------

def cmd_lanes(args) -> int:
    plan = load_json(args.plan)
    if not isinstance(plan, dict):
        fail("plan not readable: {0}".format(args.plan))
        return 3

    unit = _single_lane(plan, "unit_lanes")
    if not unit or not unit.get("classes") or not unit.get("batches"):
        fail("plan must carry exactly one unit lane with a batch layout "
             "(generate it with --min-lanes 1 --max-lanes 1)")
        return 3
    ui = _single_lane(plan, "ui_lanes")

    unit_classes = list(unit.get("classes") or [])
    ui_classes = list(ui.get("classes") or [])
    env = {
        "GATE_UNIT_PRESENT": 1,
        "GATE_UNIT_LANE": unit.get("lane") or "unit-1",
        "GATE_UNIT_TARGET": unit.get("target") or "ConduitTests",
        "GATE_UNIT_CLASSES": _csv(unit_classes),
        "GATE_UNIT_CLASS_COUNT": len(unit_classes),
        "GATE_UNIT_BATCH_COUNT": int(unit.get("batch_count") or len(unit["batches"])),
        "GATE_UNIT_BATCHES_JSON": json.dumps(unit["batches"], separators=(",", ":")),
        "GATE_UNIT_PREDICTED": unit.get("predicted_s") or 0,
        "GATE_UNIT_TIMEOUT": int(unit.get("timeout_s") or 0),
        "GATE_UI_PRESENT": 1 if ui_classes else 0,
    }
    if ui_classes:
        env.update({
            "GATE_UI_LANE": ui.get("lane") or "ui-1",
            "GATE_UI_TARGET": ui.get("target") or "ConduitUITests",
            "GATE_UI_CLASSES": _csv(ui_classes),
            "GATE_UI_CLASS_COUNT": len(ui_classes),
            "GATE_UI_CLASS_TIMEOUTS": ui.get("class_timeouts") or "",
            "GATE_UI_CLASS_ESTIMATES": ui.get("class_estimates") or "",
            "GATE_UI_PREDICTED": ui.get("predicted_s") or 0,
            "GATE_UI_TIMEOUT": int(ui.get("timeout_s") or 0),
        })
    # The audit copy sits next to the shell-sourceable file under a stable
    # name (lanes.env -> lanes.json), because the summarizer reads it back by
    # that name to check completeness against what was planned.
    write_env(args.out, env)
    write_json(os.path.splitext(args.out)[0] + ".json", {
        "schema_version": SCHEMA_VERSION,
        "unit": {
            "lane": env["GATE_UNIT_LANE"],
            "target": env["GATE_UNIT_TARGET"],
            "classes": unit_classes,
            "batches": unit["batches"],
            "batch_count": env["GATE_UNIT_BATCH_COUNT"],
            "predicted_s": env["GATE_UNIT_PREDICTED"],
            "timeout_s": env["GATE_UNIT_TIMEOUT"],
        },
        "ui": ({
            "lane": env["GATE_UI_LANE"],
            "target": env["GATE_UI_TARGET"],
            "classes": ui_classes,
            "class_timeouts": env["GATE_UI_CLASS_TIMEOUTS"],
            "predicted_s": env["GATE_UI_PREDICTED"],
            "timeout_s": env["GATE_UI_TIMEOUT"],
        } if ui_classes else None),
    })
    print("gate lanes: {0} unit classes in {1} batches, {2} UI classes".format(
        len(unit_classes), env["GATE_UNIT_BATCH_COUNT"], len(ui_classes)))
    return 0


# ---------------------------------------------------------------------------
# repeat-spec
# ---------------------------------------------------------------------------

def cmd_repeat_spec(args) -> int:
    """Project the repeat policy into per-class single-class lane tasks.

    The repeat policy is a GATE concept (see docs/CI.md): a class that has
    historically failed in ways that depend on scheduling is executed K
    times unconditionally and must pass every time. Repetition is therefore
    NOT the lane runner's retry (the gate calls it with --iterations 1, so
    Xcode never re-runs a failing test), and the watchdog ceiling is the
    planner's own batch budget for that class, capped by --timeout-cap so a
    single hung iteration cannot burn an unbounded wall clock.
    """
    plan = load_json(args.plan)
    if not isinstance(plan, dict):
        fail("plan not readable: {0}".format(args.plan))
        return 3
    unit = _single_lane(plan, "unit_lanes")
    if not unit or not unit.get("batches"):
        fail("plan must carry exactly one unit lane with a batch layout")
        return 3

    batches = unit["batches"]
    classes = [c for c in (args.classes or "").split(",") if c]
    tasks = []
    missing = []
    for name in classes:
        found = None
        for batch in batches:
            if name in (batch.get("classes") or []):
                found = batch
                break
        if found is None:
            missing.append(name)
            continue
        budget = int(found.get("timeout_s") or 0)
        capped = min(budget, args.timeout_cap) if args.timeout_cap > 0 else budget
        tasks.append({
            "class": name,
            "target": unit.get("target") or "ConduitTests",
            "predicted_s": found.get("predicted_s") or 0,
            "timeout_s": capped,
            "planner_batch_timeout_s": budget,
            "timeout_capped": capped != budget,
        })
    if missing:
        # Fail closed: a repeat class that no longer exists in the plan means
        # the repeat policy silently stopped covering what it promises to
        # cover - that is a gate defect, not something to warn past.
        fail("repeat classes not present in the plan's unit lane: {0}".format(
            _csv(missing)))
        return 3

    write_json(args.out, {
        "schema_version": SCHEMA_VERSION,
        "timeout_cap_s": args.timeout_cap,
        "iterations": args.iterations,
        "tasks": tasks,
    })
    # TSV the shell reads line by line (same idiom as the runner's own
    # batch-plan.txt): class, batches-json, predicted_s, timeout_s.
    tsv = os.path.splitext(args.out)[0] + ".tsv"
    with open(tsv, "w", encoding="utf-8", newline="\n") as fh:
        for task in tasks:
            batches_json = json.dumps(
                [{"classes": [task["class"]],
                  "predicted_s": task["predicted_s"],
                  "timeout_s": task["timeout_s"]}],
                separators=(",", ":"))
            fh.write("{0}\t{1}\t{2}\t{3}\n".format(
                task["class"], batches_json, task["predicted_s"],
                task["timeout_s"]))
    print("repeat policy: {0} class(es) x {1} iterations".format(
        len(tasks), args.iterations))
    return 0


# ---------------------------------------------------------------------------
# meta / phase / simulator
# ---------------------------------------------------------------------------

def cmd_meta(args) -> int:
    doc = {
        "schema_version": SCHEMA_VERSION,
        "requested_ref": args.ref,
        "tested_sha": args.sha,
        "xcode_version": args.xcode,
        "simulator": {
            "name": args.simulator,
            "runtime": args.runtime or "",
            "udid": args.simulator_udid or "",
        },
        "started_at": args.started_at or "",
        "finished_at": args.finished_at or "",
        "wall_s": args.wall_s,
        "allowed_recovered_infrastructure": bool(args.allow_recovered_infrastructure),
        "static_checks_enabled": not args.skip_static,
        "expected": {
            "unit_classes": args.unit_classes,
            "unit_batches": args.unit_batches,
            "ui_classes": args.ui_classes,
            "repeat_classes": [c for c in (args.repeat_classes or "").split(",") if c],
            "repeat_iterations": args.repeat_iterations,
        },
    }
    write_json(args.out, doc)
    return 0


def cmd_phase(args) -> int:
    checks = []
    for raw in args.check or []:
        # name:status:duration_s[:note] - note may contain colons, so it is
        # re-joined rather than split again.
        parts = raw.split(":", 3)
        if len(parts) < 3:
            fail("--check must be name:status:seconds[:note], got {0!r}".format(raw))
            return 2
        checks.append({
            "name": parts[0],
            "status": parts[1],
            "duration_s": _int_or_zero(parts[2]),
            "note": parts[3] if len(parts) > 3 else "",
        })
    details = {}
    for raw in args.detail or []:
        if "=" not in raw:
            fail("--detail must be KEY=VALUE, got {0!r}".format(raw))
            return 2
        key, value = raw.split("=", 1)
        details[key] = value
    doc = {
        "schema_version": SCHEMA_VERSION,
        "phase": args.phase,
        "status": args.status,
        "duration_s": args.duration,
        "exit_code": args.exit_code if args.exit_code is not None else 0,
        "note": args.note or "",
        "details": details,
        "checks": checks,
    }
    write_json(args.out, doc)
    return 0


def _int_or_zero(value) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def cmd_simulator(args) -> int:
    """Report the device xcodebuild will actually target: the newest iOS
    runtime that carries a device with the pinned name (matching
    ci-lib.sh's resolution order), so the gate's result names a real
    simulator/runtime instead of the requested string."""
    doc = load_json(args.devices)
    devices = None
    if isinstance(doc, dict):
        devices = doc.get("devices")
    out = {"name": args.name, "runtime": "", "udid": args.udid or ""}
    if isinstance(devices, dict):
        best = None
        for runtime_key, entries in devices.items():
            if "SimRuntime.iOS" not in str(runtime_key):
                continue
            version = _runtime_version(str(runtime_key))
            if version is None:
                continue
            for entry in entries or []:
                if not isinstance(entry, dict) or entry.get("name") != args.name:
                    continue
                if best is None or version > best[0]:
                    best = (version, entry.get("udid") or "", version)
        if best is not None:
            out["runtime"] = "iOS {0}".format(
                ".".join(str(p) for p in best[2]))
            if not out["udid"]:
                out["udid"] = best[1]
    write_json(args.out, out)
    return 0


def _runtime_version(runtime_key: str):
    """'com.apple.CoreSimulator.SimRuntime.iOS-26-0' -> (26, 0). Numeric
    tuples so iOS-26-10 outranks iOS-26-9 (a string compare would not)."""
    marker = ".iOS-"
    idx = runtime_key.find(marker)
    if idx < 0:
        return None
    tail = runtime_key[idx + len(marker):]
    if not tail:
        return None
    parts = tail.split("-")
    try:
        return tuple(int(p) for p in parts)
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# summarize
# ---------------------------------------------------------------------------

def _phase_status(container, name):
    """Read one phase status document. Returns (status, doc); a missing or
    unreadable phase document is 'missing', never 'pass'."""
    if not container:
        return "missing", {}
    doc = load_json(os.path.join(container, name, "phase.json"))
    if not isinstance(doc, dict) or not doc.get("status"):
        return "missing", {}
    return str(doc["status"]), doc


def _work_items(attempts, batches):
    """Fold the runner's attempt chain into WORK ITEMS (the unit of retry).

    A unit lane retries a BATCH and a UI lane retries a CLASS, so a work item
    is identified by the batch number or the class name - NOT by the mode
    string, because attempt 2 arrives under a `-retry` mode. Grouping this
    way is what lets the gate see "this item failed an assertion and later
    passed" and "this item hit the environment and later passed".

    Returns (order, items): `order` preserves first-seen order, `items` maps
    the work-item key to {name, batch, statuses[]}.
    """
    batch_classes = {}
    for batch in batches if isinstance(batches, list) else []:
        if isinstance(batch, dict):
            batch_classes[str(batch.get("batch"))] = list(batch.get("classes") or [])

    order = []
    items = {}

    def touch(key, name=None, batch=None):
        if key not in items:
            items[key] = {"name": name or "", "batch": batch, "statuses": []}
            order.append(key)
        entry = items[key]
        if name and not entry["name"]:
            entry["name"] = name
        if batch is not None and entry["batch"] is None:
            entry["batch"] = batch
        return entry

    for item in attempts if isinstance(attempts, list) else []:
        if not isinstance(item, dict):
            continue
        mode = str(item.get("mode") or "")
        n = _int_or_zero(item.get("n"))
        cls = str(item.get("class") or "all")
        status = str(item.get("status") or "")
        if mode.startswith("batch"):
            key = ("batch", str(n))
            name = _csv(batch_classes.get(str(n)) or []) or "batch-{0}".format(n)
            touch(key, name=name, batch=n)["statuses"].append(status)
        elif mode.startswith("class") or mode == "skipped":
            touch(("class", cls), name=cls)["statuses"].append(status)
        else:
            touch((mode, str(n)), name=cls)["statuses"].append(status)

    # Batch chains carry the per-attempt failing-test counts, which the
    # attempt list does not; they also cover a batch whose bookkeeping line
    # survived without an attempt record. Both are the runner's own output,
    # so they are merged rather than preferred one over the other.
    for batch in batches if isinstance(batches, list) else []:
        if not isinstance(batch, dict):
            continue
        n = _int_or_zero(batch.get("batch"))
        key = ("batch", str(n))
        name = _csv(batch_classes.get(str(n)) or batch.get("classes") or []) \
            or "batch-{0}".format(n)
        chain = [a for a in (batch.get("attempts") or []) if isinstance(a, dict)]
        for attempt in chain:
            entry = touch(key, name=name, batch=n)
            status = str(attempt.get("status") or "")
            if status and status not in entry["statuses"]:
                entry["statuses"].append(status)
    return order, items


def _classify_attempts(attempts, batches):
    """Split lane evidence into assertion failures, infrastructure events,
    timeouts and never-executed work, using the runner's own status tokens.

    Each infrastructure/timeout event is tagged `recovered` when a later
    attempt on the same work item passed: that distinction is what keeps a
    recovered wedge from being confused with a persistent one, and
    `assertion_retried_until_green` marks the invariant the gate refuses to
    accept in any mode - the same work item recorded `test-failures` and then
    `passed`, i.e. a genuine assertion was re-run until it agreed (a flake),
    which is not validation.
    """
    order, items = _work_items(attempts, batches)
    assertion = []
    infrastructure = []
    timeouts = []
    not_executed = []
    retried_until_green = []

    for key in order:
        entry = items[key]
        statuses = entry["statuses"]
        if not statuses:
            continue
        final = statuses[-1]
        common = {"name": entry["name"], "key": list(key)}
        if entry["batch"] is not None:
            common["batch"] = entry["batch"]
        saw_assertion = any(s in ASSERTION_FAILURE_STATUSES for s in statuses)
        saw_infra = any(s in INFRASTRUCTURE_STATUSES for s in statuses)
        saw_timeout = any(s in TIMEOUT_STATUSES for s in statuses)
        recovered = final == "passed"

        if saw_assertion:
            assertion.append(dict(common, kind="assertion",
                                  status="test-failures",
                                  recovered=recovered, statuses=statuses))
            if recovered:
                retried_until_green.append(dict(common, statuses=statuses))
        if saw_infra:
            infrastructure.append(dict(common, kind="infrastructure",
                                       status=final if final in INFRASTRUCTURE_STATUSES
                                       else INFRASTRUCTURE_STATUSES[0],
                                       recovered=recovered, statuses=statuses))
        if saw_timeout:
            timeouts.append(dict(common, kind="timeout",
                                 status=final if final in TIMEOUT_STATUSES else "timeout",
                                 recovered=recovered, statuses=statuses))
        if final in NOT_EXECUTED_STATUSES:
            not_executed.append(dict(common, kind="not_executed", status=final,
                                     recovered=False, statuses=statuses))

    retries = []
    for item in attempts if isinstance(attempts, list) else []:
        if isinstance(item, dict) and str(item.get("mode")) in RETRY_MODES:
            retries.append({"mode": str(item.get("mode")),
                            "name": str(item.get("class") or "all"),
                            "status": str(item.get("status"))})

    return {
        "assertion_failures": assertion,
        "infrastructure_failures": infrastructure,
        "timeouts": timeouts,
        "not_executed": not_executed,
        "retries": retries,
        "assertion_retried_until_green": retried_until_green,
    }


def _read_lane(lane_dir: str) -> dict:
    """Read one lane's artifacts. `status` is taken from lane-result.json
    (the lane runner's own verdict); every count comes from the extraction
    artifacts, and their absence is reported, never guessed."""
    try:
        entries = sorted(os.listdir(lane_dir))
    except OSError:
        entries = []
    lane_result = load_json(os.path.join(lane_dir, "lane-result.json"))
    observations = load_json(os.path.join(lane_dir, "observations.json"))
    detail = load_json(os.path.join(lane_dir, "detail.json"))

    out = {
        "dir": lane_dir,
        "present": isinstance(lane_result, dict),
        "lane_result_present": isinstance(lane_result, dict),
        "observations_present": isinstance(observations, dict),
        "detail_present": isinstance(detail, dict),
        "status": "missing",
        "classes_observed": [],
        "executions": None,
        "failures": [],
        "flaky": [],
        "attempts": [],
        "batches": [],
        "retried_classes": [],
        "infra_recovered_classes": [],
        "persistent_infra_classes": [],
        "hung_class": None,
        "hung_batch": None,
        "simulator_reset": False,
        "simulator_erase": False,
        "actual_s": None,
        "predicted_s": None,
        "timeout_s": None,
        "xcresults": [e for e in entries if e.endswith(".xcresult")],
    }
    if isinstance(lane_result, dict):
        out.update({
            "status": str(lane_result.get("status") or "unknown"),
            "retried_classes": list(lane_result.get("retried_classes") or []),
            "infra_recovered_classes": list(
                lane_result.get("infra_recovered_classes") or []),
            "persistent_infra_classes": list(
                lane_result.get("persistent_infra_classes") or []),
            "hung_class": lane_result.get("hung_class"),
            "hung_batch": lane_result.get("hung_batch"),
            "simulator_reset": bool(lane_result.get("simulator_reset")),
            "simulator_erase": bool(lane_result.get("simulator_erase")),
            "actual_s": lane_result.get("actual_s"),
            "predicted_s": lane_result.get("predicted_s"),
            "timeout_s": lane_result.get("timeout_s"),
            "attempts": lane_result.get("attempts") or [],
            "batches": lane_result.get("batches") or [],
        })
        if not out["failures"]:
            out["failures"] = list(lane_result.get("failures") or [])
        out["flaky"] = list(lane_result.get("flaky") or [])
    if isinstance(observations, dict):
        classes = observations.get("classes")
        if isinstance(classes, dict):
            out["classes_observed"] = sorted(classes.keys())
        counts = observations.get("counts")
        if isinstance(counts, dict):
            out["executions"] = _int_or_zero(counts.get("cases"))
    if isinstance(detail, dict):
        if not out["failures"]:
            out["failures"] = list(detail.get("failures") or [])
        if not out["flaky"]:
            out["flaky"] = list(detail.get("retried") or [])
        if not out["classes_observed"]:
            attempts = detail.get("attempts") or []
            if isinstance(attempts, list):
                out["classes_observed"] = sorted({
                    str(a.get("class")) for a in attempts
                    if isinstance(a, dict) and a.get("class")})
    out.update(_classify_attempts(out["attempts"], out["batches"]))
    return out


def _summarize_lane(lane: dict, expected_classes, expected_batches=None) -> dict:
    problems = []
    if not lane["lane_result_present"]:
        problems.append("lane-result.json missing")
    if lane["executions"] is None:
        problems.append("observations.json missing or without counts (execution "
                        "count could not be read from the result bundle)")
    observed = set(lane["classes_observed"])
    expected = set(expected_classes or [])
    missing = sorted(expected - observed)
    extra = sorted(observed - expected)
    if missing:
        problems.append("classes never executed: {0}".format(_csv(missing)))
    if extra:
        problems.append("unexpected classes executed: {0}".format(_csv(extra)))
    if expected_batches is not None:
        if len(lane["batches"] or []) != expected_batches:
            problems.append("expected {0} planned batches, lane result carries "
                            "{1}".format(expected_batches, len(lane["batches"] or [])))
    if lane["not_executed"]:
        problems.append("work recorded as not executed: {0}".format(
            _csv(sorted({e["name"] for e in lane["not_executed"]}))))
    if lane["assertion_retried_until_green"]:
        problems.append(
            "genuine assertions were retried and then passed (not validation): "
            + _csv(sorted({e["name"] for e in lane["assertion_retried_until_green"]})))

    return {
        "status": lane["status"],
        "executions": lane["executions"],
        "failures": len(lane["failures"]),
        "failure_detail": lane["failures"],
        "flaky": lane["flaky"],
        "classes_expected": len(expected),
        "classes_observed": len(observed),
        "classes_missing": missing,
        "batch_count": len(lane["batches"] or []) or None,
        "batches_expected": expected_batches,
        "assertion_failures": lane["assertion_failures"],
        "infrastructure_failures": lane["infrastructure_failures"],
        "timeouts": lane["timeouts"],
        "not_executed": lane["not_executed"],
        "retries": lane["retries"],
        "assertion_retried_until_green": lane["assertion_retried_until_green"],
        "retried_classes": lane["retried_classes"],
        "infra_recovered_classes": lane["infra_recovered_classes"],
        "persistent_infra_classes": lane["persistent_infra_classes"],
        "hung_class": lane["hung_class"],
        "hung_batch": lane["hung_batch"],
        "simulator_reset": lane["simulator_reset"],
        "simulator_erase": lane["simulator_erase"],
        "duration_s": lane["actual_s"],
        "predicted_s": lane["predicted_s"],
        "timeout_s": lane["timeout_s"],
        "problems": problems,
    }


def _read_repeats(repeats_dir: str, expected, iterations: int):
    """Read every repeat class's per-iteration lane artifacts."""
    classes = []
    for name in expected:
        class_dir = os.path.join(repeats_dir, name)
        iterations_out = []
        try:
            entries = sorted(os.listdir(class_dir))
        except OSError:
            entries = []
        for entry in entries:
            if not entry.startswith("iter-"):
                continue
            lane = _read_lane(os.path.join(class_dir, entry))
            iterations_out.append({
                "iteration": _int_or_zero(entry.split("-", 1)[1]),
                "dir": lane["dir"],
                "status": lane["status"],
                "executions": lane["executions"],
                "failures": len(lane["failures"]),
                "assertion_failures": lane["assertion_failures"],
                "infrastructure_failures": lane["infrastructure_failures"],
                "timeouts": lane["timeouts"],
                "not_executed": lane["not_executed"],
                "retries": lane["retries"],
                "assertion_retried_until_green": lane["assertion_retried_until_green"],
                "duration_s": lane["actual_s"],
                "xcresults": lane["xcresults"],
                "observations_present": lane["observations_present"],
                "lane_result_present": lane["lane_result_present"],
            })
        iterations_out.sort(key=lambda i: i["iteration"])
        classes.append({
            "class": name,
            "iterations_expected": iterations,
            "iterations_observed": len(iterations_out),
            "iterations": iterations_out,
        })
    return classes


def _repeat_problems(entry, iterations: int):
    problems = []
    if entry["iterations_observed"] != iterations:
        problems.append(
            "{0}: expected {1} repeat iterations, found {2}".format(
                entry["class"], iterations, entry["iterations_observed"]))
    seen = [i["iteration"] for i in entry["iterations"]]
    expected_numbers = list(range(1, iterations + 1))
    if seen != expected_numbers:
        problems.append("{0}: repeat iterations {1} (expected {2})".format(
            entry["class"], seen, expected_numbers))
    for iteration in entry["iterations"]:
        label = "{0} iteration {1}".format(entry["class"], iteration["iteration"])
        if iteration["status"] != "pass":
            problems.append("{0}: lane status {1!r}".format(label, iteration["status"]))
        if not iteration["lane_result_present"]:
            problems.append("{0}: lane-result.json missing".format(label))
        if iteration["executions"] is None:
            problems.append("{0}: execution count unreadable".format(label))
        if iteration["failures"]:
            problems.append("{0}: {1} genuine test failure(s)".format(
                label, iteration["failures"]))
        if iteration["assertion_failures"] or iteration["infrastructure_failures"] \
                or iteration["timeouts"] or iteration["not_executed"]:
            problems.append("{0}: environment/classification events present".format(label))
        if iteration["assertion_retried_until_green"]:
            problems.append(
                "{0}: genuine assertions were retried and then passed".format(label))
    return problems


def cmd_summarize(args) -> int:
    run_dir = os.path.abspath(args.run_dir)
    meta = load_json(os.path.join(run_dir, "meta.json"))
    if not isinstance(meta, dict):
        fail("meta.json not readable under {0}".format(run_dir))
        return 3

    expected = meta.get("expected") or {}
    iterations = _int_or_zero(expected.get("repeat_iterations")) or 0
    repeat_classes = list(expected.get("repeat_classes") or [])
    allow_recovered = bool(meta.get("allowed_recovered_infrastructure"))

    phases = {}
    gate_problems = []

    # --- tested SHA -------------------------------------------------------
    tested_sha = str(meta.get("tested_sha") or "")
    if not HEX40.match(tested_sha):
        gate_problems.append(
            "tested SHA is not a full 40-character git commit id: {0!r}".format(tested_sha))

    # --- non-lane phases --------------------------------------------------
    for name in ("static", "build"):
        status, doc = _phase_status(run_dir, name)
        phases[name] = doc if doc else {"phase": name, "status": status,
                                       "duration_s": 0, "checks": []}
        if status != "pass":
            if name == "static" and not meta.get("static_checks_enabled"):
                phases[name]["status"] = "skipped"
                continue
            gate_problems.append("{0} phase: {1}".format(name, status))
        for check in (phases[name].get("checks") or []):
            if str(check.get("status")) != "pass":
                gate_problems.append("{0} check {1}: {2}".format(
                    name, check.get("name"), check.get("status")))

    # --- lanes ------------------------------------------------------------
    unit = _read_lane(os.path.join(run_dir, "lanes", "unit"))
    if not os.path.isdir(os.path.join(run_dir, "lanes", "unit")):
        gate_problems.append("unit lane results are missing")
    unit_summary = _summarize_lane(unit, _expected_classes(
        run_dir, "unit", expected.get("unit_classes")),
        _int_or_zero(expected.get("unit_batches")) or None)
    gate_problems.extend("unit: " + p for p in unit_summary["problems"])

    ui_expected = _expected_classes(run_dir, "ui", expected.get("ui_classes"))
    if ui_expected:
        ui = _read_lane(os.path.join(run_dir, "lanes", "ui"))
        if not os.path.isdir(os.path.join(run_dir, "lanes", "ui")):
            gate_problems.append("UI lane results are missing")
        ui_summary = _summarize_lane(ui, ui_expected)
        gate_problems.extend("ui: " + p for p in ui_summary["problems"])
    else:
        ui_summary = {"status": "skipped", "executions": 0, "failures": 0,
                      "classes_expected": 0, "classes_observed": 0,
                      "problems": []}

    # --- repeats ----------------------------------------------------------
    repeats_dir = os.path.join(run_dir, "repeats")
    repeat_entries = _read_repeats(repeats_dir, repeat_classes, iterations) \
        if repeat_classes and iterations else []
    for entry in repeat_entries:
        gate_problems.extend(
            "repeat " + p for p in _repeat_problems(entry, iterations))
    repeat_executions = sum(
        i["executions"] or 0
        for entry in repeat_entries for i in entry["iterations"])
    repeat_failures = sum(
        i["failures"] for entry in repeat_entries for i in entry["iterations"])

    # --- classification roll-up ------------------------------------------
    events = {
        "assertion_failures": [],
        "infrastructure_failures": [],
        "infrastructure_recovered": [],
        "infrastructure_recovered_classes": [],
        "timeouts": [],
        "not_executed": [],
        "retries": [],
        "assertion_retried_until_green": [],
    }
    for label, summary in (("unit", unit_summary), ("ui", ui_summary)):
        for key in ("assertion_failures", "infrastructure_failures", "timeouts",
                    "not_executed", "retries",
                    "assertion_retried_until_green"):
            for entry in summary.get(key) or []:
                item = dict(entry)
                item["lane"] = label
                events[key].append(item)
        for name in summary.get("infra_recovered_classes") or []:
            events["infrastructure_recovered_classes"].append(
                {"lane": label, "name": name})
    for entry in repeat_entries:
        for iteration in entry["iterations"]:
            label = "repeat:{0}#{1}".format(entry["class"], iteration["iteration"])
            for key in ("assertion_failures", "infrastructure_failures",
                        "timeouts", "not_executed", "retries",
                        "assertion_retried_until_green"):
                for item in iteration.get(key) or []:
                    tagged = dict(item)
                    tagged["lane"] = label
                    events[key].append(tagged)

    # Classification verdict. The gate never claims success on a run whose
    # environment misbehaved: a persistent infrastructure failure is fatal
    # always, and a *recovered* one means the run is not usable as release
    # evidence either (the operator reruns it) unless the caller explicitly
    # downgraded it. Assertions that were re-run until they passed are not
    # validation in any mode.
    persistent_infra = [e for e in events["infrastructure_failures"]
                        if not e.get("recovered")]
    recovered_infra = [e for e in events["infrastructure_failures"]
                       if e.get("recovered")]
    persistent_timeouts = [e for e in events["timeouts"] if not e.get("recovered")]
    recovered_timeouts = [e for e in events["timeouts"] if e.get("recovered")]
    events["infrastructure_persistent"] = persistent_infra
    events["infrastructure_recovered"] = recovered_infra + recovered_timeouts
    # The lane runner also labels recovered classes directly. That label is
    # the same recovery seen through a second lens, so it is never ADDED to
    # the count - but a label the attempt chain cannot account for means the
    # evidence is incomplete, and that must not slip through as a clean run.
    recovered_names = sorted({e["name"] for e in
                              recovered_infra + recovered_timeouts})
    unaccounted = [entry for entry in events["infrastructure_recovered_classes"]
                   if not _covers_names(recovered_names, entry["name"])]

    if events["assertion_failures"] or repeat_failures or unit_summary.get("failures") \
            or ui_summary.get("failures"):
        gate_problems.append("genuine XCTest assertion failures present ({0})".format(
            len(events["assertion_failures"]) or
            unit_summary.get("failures") or ui_summary.get("failures")))
    if persistent_infra or persistent_timeouts:
        gate_problems.append(
            "persistent infrastructure failure(s)/hang(s) present "
            "({0} infra, {1} timeout)".format(len(persistent_infra),
                                              len(persistent_timeouts)))
    if (recovered_infra or recovered_timeouts) and not allow_recovered:
        gate_problems.append(
            "infrastructure failures were recovered by a bounded retry "
            "({0} infra, {1} timeout: {2}); the run is not trustworthy "
            "evidence - rerun the gate".format(
                len(recovered_infra), len(recovered_timeouts),
                _csv(recovered_names)))
    if unaccounted and not allow_recovered:
        gate_problems.append(
            "lane result reports recovered infrastructure the attempt chain "
            "does not account for: {0}".format(
                _csv(sorted({e["name"] for e in unaccounted}))))
    if events["assertion_retried_until_green"]:
        gate_problems.append(
            "genuine assertions were retried until they passed ({0}: {1})".format(
                len(events["assertion_retried_until_green"]),
                _csv(sorted({e["name"] for e in
                             events["assertion_retried_until_green"]}))))

    deduped = _dedupe(gate_problems)
    verdict = "PASS" if not deduped else "FAIL"

    result = {
        "schema_version": SCHEMA_VERSION,
        "gate": "conduit-local-ci-gate",
        "verdict": verdict,
        "requested_ref": meta.get("requested_ref"),
        "tested_sha": tested_sha,
        "tested_sha_short": tested_sha[:12],
        "xcode_version": meta.get("xcode_version"),
        "simulator": meta.get("simulator"),
        "timing": {
            "started_at": meta.get("started_at"),
            "finished_at": meta.get("finished_at"),
            "wall_s": meta.get("wall_s"),
            "phases": {name: doc.get("duration_s")
                       for name, doc in sorted(phases.items())},
        },
        "static_checks": phases.get("static", {}).get("checks", []),
        "build": {
            "status": phases.get("build", {}).get("status", "missing"),
            "duration_s": phases.get("build", {}).get("duration_s"),
            "xctestrun": (phases.get("build", {}).get("details") or {}).get("xctestrun", ""),
            "note": phases.get("build", {}).get("note", ""),
        },
        # A run with the cheap static checks skipped is explicitly partial:
        # it can never be cited as the exhaustive gate for a release head.
        "partial": not bool(meta.get("static_checks_enabled")),
        "unit": unit_summary,
        "ui": ui_summary,
        "focused_repeats": {
            "enabled": bool(repeat_classes and iterations),
            "iterations_per_class": iterations,
            "classes": repeat_entries,
            "executions": repeat_executions,
            "failures": repeat_failures,
        },
        "infrastructure": {
            "failures": len(events["infrastructure_failures"]),
            "persistent": len(persistent_infra) + len(persistent_timeouts),
            "recovered": len(events["infrastructure_recovered"]),
            "timeouts": len(events["timeouts"]),
            "retries": len(events["retries"]),
            "not_executed": len(events["not_executed"]),
            "simulator_resets": int(bool(unit_summary.get("simulator_reset"))) +
                                int(bool(ui_summary.get("simulator_reset"))),
            "simulator_erases": int(bool(unit_summary.get("simulator_erase"))) +
                               int(bool(ui_summary.get("simulator_erase"))),
            "events": events,
        },
        "assertion_rerun_until_green": len(events["assertion_retried_until_green"]),
        "problems": deduped,
        "artifacts": {
            "run_dir": run_dir,
            "gate_result": os.path.join(run_dir, "gate-result.json"),
            "summary_md": os.path.join(run_dir, "summary.md"),
            "build_log": os.path.join(run_dir, "build", "build.log"),
            "unit_dir": os.path.join(run_dir, "lanes", "unit"),
            "ui_dir": os.path.join(run_dir, "lanes", "ui") if ui_expected else None,
            "repeats_dir": repeats_dir if repeat_entries else None,
        },
    }
    write_json(args.out, result)
    if args.markdown:
        _write_markdown(args.markdown, result)
    _print_human(result)

    if verdict == "PASS":
        print("local gate: PASS")
        return 0
    print("local gate: FAIL ({0} problem(s) - see {1})".format(
        len(deduped), os.path.abspath(args.out)))
    return 1


def _expected_classes(run_dir: str, kind: str, fallback):
    """The class list the gate planned to execute. Preferred source is the
    plan projection the shell wrote, so completeness is checked against what
    was planned rather than against a count passed on the command line."""
    doc = load_json(os.path.join(run_dir, "lanes.json"))
    if isinstance(doc, dict):
        entry = doc.get(kind)
        if isinstance(entry, dict) and entry.get("classes"):
            return list(entry["classes"])
    return list(fallback or [])


def _dedupe(items):
    seen = set()
    out = []
    for item in items:
        if item in seen:
            continue
        seen.add(item)
        out.append(item)
    return out


def _covers_names(names, candidate: str) -> bool:
    """True when `candidate` names one of the classes in `names`.

    Attempt entries name a batch by its class list ("AlphaTests,BetaTests")
    while the lane runner labels a recovered CLASS by its own name, so the
    match has to be by CSV member, not by string equality.
    """
    for name in names:
        if candidate in [part for part in str(name).split(",") if part]:
            return True
    return False


def _write_markdown(path: str, result: dict) -> None:
    unit = result["unit"]
    ui = result["ui"]
    repeats = result["focused_repeats"]
    infra = result["infrastructure"]
    lines = []
    lines.append("# Conduit local gate: {0}".format(result["verdict"]))
    lines.append("")
    lines.append("Tested commit: `{0}` (requested `{1}`)".format(
        result["tested_sha"], result["requested_ref"]))
    lines.append("")
    lines.append("- Xcode: {0}".format(
        (result.get("xcode_version") or "").strip() or "unknown"))
    sim = result.get("simulator") or {}
    lines.append("- Simulator: {0} / {1} ({2})".format(
        sim.get("name") or "?", sim.get("runtime") or "?", sim.get("udid") or "?"))
    lines.append("- Wall clock: {0}s".format(result["timing"]["wall_s"]))
    if result.get("partial"):
        lines.append("- **PARTIAL RUN**: the cheap static checks were skipped; "
                     "this is not an exhaustive-gate result.")
    lines.append("")
    lines.append("| Phase | Status | Executions | Failures | Duration |")
    lines.append("|---|---|---|---|---|")
    lines.append("| build (once) | {0} | - | - | {1}s |".format(
        result["build"]["status"], result["build"]["duration_s"]))
    lines.append("| unit (ConduitTests) | {0} | {1} | {2} | {3}s |".format(
        unit.get("status"), unit.get("executions"), unit.get("failures"),
        unit.get("duration_s")))
    lines.append("| UI (ConduitUITests) | {0} | {1} | {2} | {3}s |".format(
        ui.get("status"), ui.get("executions"), ui.get("failures"),
        ui.get("duration_s")))
    if repeats.get("enabled"):
        lines.append("| repeats ({0} x {1} classes) | {2} | {3} | {4} | - |".format(
            repeats["iterations_per_class"], len(repeats["classes"]),
            "pass" if not repeats["failures"] else "fail",
            repeats["executions"], repeats["failures"]))
    lines.append("")
    lines.append("Classes: {0}/{1} unit, {2}/{3} UI executed.".format(
        unit.get("classes_observed"), unit.get("classes_expected"),
        ui.get("classes_observed"), ui.get("classes_expected")))
    lines.append("")
    lines.append("Infrastructure: {0} failure(s), {1} recovered, {2} timeout(s), "
                 "{3} retry attempt(s), {4} simulator reset(s)/{5} erase(s).".format(
                     infra["failures"], infra["recovered"], infra["timeouts"],
                     infra["retries"], infra["simulator_resets"],
                     infra["simulator_erases"]))
    if repeats.get("enabled"):
        lines.append("")
        lines.append("Repeat policy (unconditional repetitions, no retry):")
        for entry in repeats["classes"]:
            statuses = ", ".join(
                "iter {0}: {1} ({2} exec, {3} fail)".format(
                    i["iteration"], i["status"], i["executions"], i["failures"])
                for i in entry["iterations"])
            lines.append("- `{0}`: {1}".format(entry["class"], statuses))
    if result["problems"]:
        lines.append("")
        lines.append("## Problems")
        lines.append("")
        for problem in result["problems"]:
            lines.append("- {0}".format(problem))
    lines.append("")
    lines.append("Artifacts: `{0}`".format(result["artifacts"]["run_dir"]))
    directory = os.path.dirname(os.path.abspath(path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")


def _print_human(result: dict) -> None:
    unit = result["unit"]
    ui = result["ui"]
    repeats = result["focused_repeats"]
    print("")
    print("=== Conduit local gate ===")
    print("tested SHA : {0}  (requested {1})".format(
        result["tested_sha"], result["requested_ref"]))
    print("xcode      : {0}".format(
        (result.get("xcode_version") or "").strip() or "unknown"))
    sim = result.get("simulator") or {}
    print("simulator  : {0} / {1}".format(sim.get("name"), sim.get("runtime")))
    print("wall clock : {0}s".format(result["timing"]["wall_s"]))
    print("build      : {0} ({1}s)".format(
        result["build"]["status"], result["build"]["duration_s"]))
    print("unit       : {0} - {1} executions, {2} failures, "
          "{3}/{4} classes ({5}s)".format(
              unit.get("status"), unit.get("executions"), unit.get("failures"),
              unit.get("classes_observed"), unit.get("classes_expected"),
              unit.get("duration_s")))
    print("ui         : {0} - {1} executions, {2} failures, "
          "{3}/{4} classes ({5}s)".format(
              ui.get("status"), ui.get("executions"), ui.get("failures"),
              ui.get("classes_observed"), ui.get("classes_expected"),
              ui.get("duration_s")))
    if repeats.get("enabled"):
        print("repeats    : {0} class(es) x {1} iterations - {2} executions, "
              "{3} failures".format(len(repeats["classes"]),
                                    repeats["iterations_per_class"],
                                    repeats["executions"], repeats["failures"]))
    infra = result["infrastructure"]
    print("infra      : {0} failure(s), {1} recovered, {2} timeout(s), "
          "{3} retry attempt(s)".format(infra["failures"], infra["recovered"],
                                        infra["timeouts"], infra["retries"]))
    if result["problems"]:
        print("problems:")
        for problem in result["problems"]:
            print("  - {0}".format(problem))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("lanes")
    p.add_argument("--plan", required=True)
    p.add_argument("--out", required=True, help="shell-sourceable env file")
    p.set_defaults(func=cmd_lanes)

    p = sub.add_parser("repeat-spec")
    p.add_argument("--plan", required=True)
    p.add_argument("--classes", required=True, help="comma-separated class names")
    p.add_argument("--iterations", type=int, default=3)
    p.add_argument("--timeout-cap", type=int, default=REPEAT_BATCH_TIMEOUT_CAP_DEFAULT)
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_repeat_spec)

    p = sub.add_parser("meta")
    p.add_argument("--out", required=True)
    p.add_argument("--ref", required=True)
    p.add_argument("--sha", required=True)
    p.add_argument("--xcode", default="")
    p.add_argument("--simulator", default="")
    p.add_argument("--runtime", default="")
    p.add_argument("--simulator-udid", default="")
    p.add_argument("--started-at", default="")
    p.add_argument("--finished-at", default="")
    p.add_argument("--wall-s", type=int, default=0)
    p.add_argument("--unit-classes", type=int, default=0)
    p.add_argument("--unit-batches", type=int, default=0)
    p.add_argument("--ui-classes", type=int, default=0)
    p.add_argument("--repeat-classes", default="")
    p.add_argument("--repeat-iterations", type=int, default=0)
    p.add_argument("--allow-recovered-infrastructure", action="store_true")
    p.add_argument("--skip-static", action="store_true")
    p.set_defaults(func=cmd_meta)

    p = sub.add_parser("simulator")
    p.add_argument("--devices", required=True,
                   help="JSON from `xcrun simctl list devices available -j`")
    p.add_argument("--name", required=True)
    p.add_argument("--udid", default="")
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_simulator)

    p = sub.add_parser("phase")
    p.add_argument("--out", required=True)
    p.add_argument("--phase", required=True)
    p.add_argument("--status", required=True)
    p.add_argument("--duration", type=int, default=0)
    p.add_argument("--exit-code", type=int, default=None)
    p.add_argument("--note", default="")
    p.add_argument("--check", action="append", default=[],
                   help="name:status:seconds[:note] (repeatable)")
    p.add_argument("--detail", action="append", default=[],
                   help="KEY=VALUE phase detail (repeatable)")
    p.set_defaults(func=cmd_phase)

    p = sub.add_parser("summarize")
    p.add_argument("--run-dir", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--markdown", default="")
    p.set_defaults(func=cmd_summarize)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
