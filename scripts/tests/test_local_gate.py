"""Regression tests for the local exhaustive gate tooling.

Covers scripts/local-gate.py (plan projection, classification, verdict) with
synthetic plan/run artifacts, so the gate's fail-closed behavior is pinned on
Linux CI without a Mac: an unreadable artifact, a class that never executed,
a genuine assertion failure, an infrastructure failure, or an assertion that
was re-run until it passed must never produce a PASS verdict.
"""

import contextlib
import io
import json
import os
import shlex
import sys
import tempfile
import unittest
from pathlib import Path

from _util import SCRIPTS_DIR, load_module

local_gate = load_module("local_gate", "local-gate.py")


UNIT_LANE = {
    "lane": "unit-1",
    "target": "ConduitTests",
    "classes": ["AlphaTests", "BetaTests", "GammaTests"],
    "batches": [
        {"classes": ["AlphaTests", "BetaTests"], "predicted_s": 10.0, "timeout_s": 600},
        {"classes": ["GammaTests"], "predicted_s": 5.0, "timeout_s": 500},
    ],
    "batch_count": 2,
    "predicted_s": 15.0,
    "timeout_s": 1100,
}

UI_LANE = {
    "lane": "ui-1",
    "target": "ConduitUITests",
    "classes": ["LaunchUITests"],
    "class_timeouts": "LaunchUITests=420",
    "class_estimates": "LaunchUITests=100.0",
    "predicted_s": 100.0,
    "timeout_s": 1400,
}


def make_plan(unit_lanes=None, ui_lanes=None, **overrides):
    plan = {
        "schema_version": 2,
        "inventory": {"unit": ["AlphaTests", "BetaTests", "GammaTests"],
                      "ui": ["LaunchUITests"]},
        "unit_lanes": [UNIT_LANE] if unit_lanes is None else unit_lanes,
        "ui_lanes": [UI_LANE] if ui_lanes is None else ui_lanes,
        "lane_count": 1,
        "ui_lane_count": 1,
        "total_predicted_s": 15.0,
        "ui_predicted_s": 100.0,
        "imbalance_predicted_pct": 0.0,
        "ui_imbalance_predicted_pct": 0.0,
        "estimates": {},
        "config": {},
    }
    plan.update(overrides)
    return plan


def write_json(path, doc):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2), encoding="utf-8")


def lane_artifacts(lane_dir, *, status="pass", classes=("AlphaTests",),
                   cases=4, failures=(), attempts=None, batches=None,
                   retried=(), infra_recovered=(), persistent_infra=(),
                   observations=True, detail=True, lane_result=True):
    """Write the three artifacts ci-test-lane.sh leaves behind.

    An artifact that the caller disabled is DELETED, not left over from an
    earlier write: tests that model a missing extraction must start from a
    directory without one, otherwise the fixture silently passes for the
    wrong reason.
    """
    lane_dir = Path(lane_dir)
    lane_dir.mkdir(parents=True, exist_ok=True)
    for name, wanted in (("lane-result.json", lane_result),
                         ("observations.json", observations),
                         ("detail.json", detail)):
        target = lane_dir / name
        if not wanted and target.exists():
            target.unlink()
    if lane_result:
        write_json(lane_dir / "lane-result.json", {
            "schema_version": 1,
            "lane": "unit-1",
            "kind": "unit",
            "target": "ConduitTests",
            "classes": list(classes),
            "status": status,
            "predicted_s": 15.0,
            "timeout_s": 1100,
            "actual_s": 42,
            "attempts": attempts if attempts is not None else [
                {"mode": "batch", "n": 1, "class": "all", "status": "passed"}],
            "batches": batches if batches is not None else [
                {"batch": 1, "classes": list(classes), "timeout_s": 600,
                 "status": "pass",
                 "attempts": [{"attempt": 1, "status": "passed",
                               "seconds": 1.0, "failures": 0}]}],
            "retried_classes": list(retried),
            "infra_recovered_classes": list(infra_recovered),
            "persistent_infra_classes": list(persistent_infra),
        })
    if observations:
        write_json(lane_dir / "observations.json", {
            "schema_version": 1,
            "classes": {c: 1.0 for c in classes},
            "counts": {"classes": len(classes), "cases": cases},
        })
    if detail:
        write_json(lane_dir / "detail.json", {
            "schema_version": 1,
            "attempts": [
                {"class": c, "test": "testSomething", "attempts_count": 1,
                 "final": "Passed", "attempts": []}
                for c in classes
            ],
            "failures": list(failures),
            "retried": [],
        })
    return lane_dir


class LaneProjectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def _lanes(self, plan, json_out=None):
        plan_path = self.root / "plan.json"
        write_json(plan_path, plan)
        out = self.root / "lanes.env"
        args = ["lanes", "--plan", str(plan_path), "--out", str(out)]
        if json_out is not None:
            args += ["--json-out", str(json_out)]
        with contextlib.redirect_stdout(io.StringIO()):
            code = local_gate.main(args)
        return code, out

    def test_projects_single_unit_and_ui_lane(self):
        audit_path = self.root / "projection.json"
        code, out = self._lanes(make_plan(), json_out=audit_path)
        self.assertEqual(code, 0)
        text = out.read_text(encoding="utf-8")
        self.assertIn("GATE_UNIT_CLASS_COUNT=3", text)
        self.assertIn("GATE_UNIT_BATCH_COUNT=2", text)
        self.assertIn("GATE_UI_PRESENT=1", text)
        self.assertIn("GATE_UI_CLASS_TIMEOUTS=", text)
        # The audit copy is the plan projection the summarizer reads back for
        # its completeness check, so it lands at the path the shell passed.
        audit = json.loads(audit_path.read_text(encoding="utf-8"))
        self.assertEqual(audit["unit"]["classes"], ["AlphaTests", "BetaTests",
                                                   "GammaTests"])
        self.assertEqual(len(audit["unit"]["batches"]), 2)

    def test_default_audit_path_is_the_env_path_with_json_suffix(self):
        code, out = self._lanes(make_plan())
        self.assertEqual(code, 0)
        self.assertTrue((self.root / "lanes.json").exists())

    def test_refuses_multi_lane_plan(self):
        """The gate is exhaustive: a sharded plan would silently mean "the
        suites were split", so it must refuse rather than pick a lane."""
        plan = make_plan(unit_lanes=[UNIT_LANE, dict(UNIT_LANE, lane="unit-2")])
        code, _ = self._lanes(plan)
        self.assertEqual(code, 3)

    def test_refuses_lane_without_batches(self):
        plan = make_plan(unit_lanes=[dict(UNIT_LANE, batches=[])])
        code, _ = self._lanes(plan)
        self.assertEqual(code, 3)

    def test_no_ui_lane_is_allowed(self):
        code, out = self._lanes(make_plan(ui_lanes=[]))
        self.assertEqual(code, 0)
        self.assertIn("GATE_UI_PRESENT=0", out.read_text(encoding="utf-8"))


class RepeatSpecTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.plan_path = self.root / "plan.json"
        write_json(self.plan_path, make_plan())

    def _spec(self, classes, cap=900, iterations=3, tsv_out=None):
        out = self.root / "repeats.json"
        args = ["repeat-spec", "--plan", str(self.plan_path), "--classes", classes,
                "--iterations", str(iterations), "--timeout-cap", str(cap),
                "--out", str(out)]
        if tsv_out is not None:
            args += ["--tsv-out", str(tsv_out)]
        with contextlib.redirect_stdout(io.StringIO()):
            code = local_gate.main(args)
        return code, out

    def test_tsv_lands_where_the_caller_says(self):
        """The shell reads this file line by line; if the two sides disagree
        about its path the loop silently runs zero iterations while the lane
        status still says "pass" - exactly the silent no-op this pins."""
        tsv = self.root / "custom-name.tsv"
        code, _ = self._spec("AlphaTests", tsv_out=tsv)
        self.assertEqual(code, 0)
        self.assertTrue(tsv.exists())
        line = tsv.read_text(encoding="utf-8").strip()
        self.assertTrue(line.startswith("AlphaTests\t"))
        # And the explicitly named file differs from what a derived name would
        # have produced, so the assertion above cannot pass by accident.
        self.assertFalse((self.root / "repeats.tsv").exists())

    def test_whitespace_in_the_class_list_is_tolerated(self):
        code, _ = self._spec("AlphaTests, BetaTests")
        self.assertEqual(code, 0)
        spec = json.loads((self.root / "repeats.json").read_text(encoding="utf-8"))
        self.assertEqual([t["class"] for t in spec["tasks"]],
                         ["AlphaTests", "BetaTests"])

    def test_uses_planner_batch_budget_and_caps_it(self):
        code, out = self._spec("AlphaTests")
        self.assertEqual(code, 0)
        spec = json.loads(out.read_text(encoding="utf-8"))
        task = spec["tasks"][0]
        self.assertEqual(task["class"], "AlphaTests")
        self.assertEqual(task["planner_batch_timeout_s"], 600)
        self.assertEqual(task["timeout_s"], 600)
        self.assertFalse(task["timeout_capped"])
        tsv = (self.root / "repeats.tsv").read_text(encoding="utf-8").strip()
        self.assertTrue(tsv.startswith("AlphaTests\t"))

    def test_caps_a_huge_planner_budget(self):
        second = dict(UNIT_LANE["batches"][1], timeout_s=5000)
        plan = make_plan(unit_lanes=[dict(UNIT_LANE, batches=[UNIT_LANE["batches"][0],
                                                             second])])
        write_json(self.plan_path, plan)
        code, out = self._spec("GammaTests", cap=900)
        self.assertEqual(code, 0)
        task = json.loads(out.read_text(encoding="utf-8"))["tasks"][0]
        self.assertEqual(task["planner_batch_timeout_s"], 5000)
        self.assertEqual(task["timeout_s"], 900)
        self.assertTrue(task["timeout_capped"])

    def test_unknown_repeat_class_fails_closed(self):
        """A repeat class that left the suite means the repeat policy quietly
        stopped covering what it promises - that must fail, not warn."""
        code, _ = self._spec("AlphaTests,DoesNotExistTests")
        self.assertEqual(code, 3)


class NotRunBatchesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.plan_path = self.root / "plan.json"
        write_json(self.plan_path, make_plan())

    def _continuation(self, batch_statuses):
        lane_result = self.root / "lane-result.json"
        write_json(lane_result, {
            "schema_version": 1, "lane": "unit-1", "status": "fail",
            "batches": [{"batch": i, "classes": batch["classes"],
                         "timeout_s": batch["timeout_s"], "status": status,
                         "attempts": []}
                        for i, (batch, status) in
                        enumerate(zip(UNIT_LANE["batches"], batch_statuses), start=1)],
        })
        out = self.root / "cont.env"
        with contextlib.redirect_stdout(io.StringIO()):
            code = local_gate.main(["not-run-batches", "--plan", str(self.plan_path),
                                    "--lane-result", str(lane_result),
                                    "--out", str(out)])
        values = {}
        for line in out.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("=")
            values[key] = shlex.split(value)[0] if value.strip() else ""
        return code, values

    def test_projects_the_never_reached_batches(self):
        code, values = self._continuation(["test-failures", "not_run"])
        self.assertEqual(code, 0)
        self.assertEqual(values["GATE_CONT_PRESENT"], "1")
        self.assertEqual(values["GATE_CONT_BATCH_COUNT"], "1")
        self.assertEqual(values["GATE_CONT_BATCH_INDICES"], "2")
        self.assertEqual(values["GATE_CONT_CLASSES"], "GammaTests")
        # The continuation reuses the planner's own batch object, including
        # its watchdog, rather than inventing a budget.
        self.assertEqual(values["GATE_CONT_TIMEOUT"], "500")
        self.assertEqual(values["GATE_CONT_PREDICTED"], "5.0")

    def test_no_continuation_when_nothing_was_left_behind(self):
        code, values = self._continuation(["pass", "pass"])
        self.assertEqual(code, 0)
        self.assertEqual(values["GATE_CONT_PRESENT"], "0")

    def test_missing_lane_result_fails_closed(self):
        out = self.root / "cont.env"
        with contextlib.redirect_stdout(io.StringIO()):
            code = local_gate.main(["not-run-batches", "--plan", str(self.plan_path),
                                    "--lane-result", str(self.root / "nope.json"),
                                    "--out", str(out)])
        self.assertEqual(code, 3)
        self.assertFalse(out.exists())


class RecoveryVerdictTests(unittest.TestCase):
    """End-to-end verdicts for the bounded recovery round.

    Builds run directories that model the three outcomes a recovery round can
    have: it recovered the work, it hit the same infrastructure class again, or
    it never ran because a genuine assertion was present.
    """

    SHA = "1" * 40
    WEDGE_FAILURE = [{"class": "System Failures",
                      "test": "Conduit encountered an error", "attempts": []}]
    BUSY_LOG = 'iOSSimulator: Failed to launch app with identifier: com.milim.relay ' \
               '(BSErrorCodeDescription=Busy)'
    WEDGE_ATTEMPTS = [{"mode": "batch", "n": 1, "class": "all",
                       "status": "test-failures"},
                      {"mode": "batch", "n": 2, "class": "all",
                       "status": "not_run"}]
    WEDGE_BATCHES = [
        {"batch": 1, "classes": ["AlphaTests", "BetaTests"], "timeout_s": 600,
         "status": "test-failures",
         "attempts": [{"attempt": 1, "status": "test-failures",
                       "seconds": 1.0, "failures": 1}]},
        {"batch": 2, "classes": ["GammaTests"], "timeout_s": 500,
         "status": "not_run", "attempts": []},
    ]

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.run_dir = Path(self.tmp.name)
        write_json(self.run_dir / "lanes.json", {
            "schema_version": 1,
            "unit": {"classes": ["AlphaTests", "BetaTests", "GammaTests"]},
            "ui": {"classes": ["LaunchUITests"]},
        })
        write_json(self.run_dir / "meta.json", {
            "schema_version": 1, "requested_ref": "origin/main",
            "tested_sha": self.SHA, "xcode_version": "Xcode 27.0",
            "simulator": {"name": "Conduit CI Gate", "runtime": "iOS 26.5",
                          "udid": "GATE-DEVICE"},
            "started_at": "2026-09-21T00:00:00Z",
            "finished_at": "2026-09-21T01:00:00Z", "wall_s": 3600,
            "allowed_recovered_infrastructure": False,
            "static_checks_enabled": True,
            "repeat_policy_enabled": True,
            "run_flags": {"lock_used": True, "simulator_prep": True},
            "expected": {"unit_classes": 3, "unit_batches": 2, "ui_classes": 1,
                         "repeat_classes": [], "repeat_iterations": 0},
        })
        write_json(self.run_dir / "static" / "phase.json", {
            "schema_version": 1, "phase": "static", "status": "pass",
            "duration_s": 5, "checks": [
                {"name": "plan-validate", "status": "pass", "duration_s": 1},
                {"name": "ci-tooling-regression", "status": "pass", "duration_s": 1},
                {"name": "localization-coverage", "status": "pass", "duration_s": 1},
            ]})
        write_json(self.run_dir / "build" / "phase.json", {
            "schema_version": 1, "phase": "build", "status": "pass",
            "duration_s": 60, "details": {"xctestrun": "/tmp/x.xctestrun"}})
        lane_artifacts(self.run_dir / "lanes" / "ui", status="pass",
                      classes=("LaunchUITests",), cases=3)

    def _wedge_log(self, lane_dir):
        logs = lane_dir / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        (logs / "batch-1-a1.log").write_text(self.BUSY_LOG + "\n", encoding="utf-8")

    def _recovery_phase(self, status="pass"):
        write_json(self.run_dir / "recovery" / "phase.json", {
            "schema_version": 1, "phase": "recovery", "status": status,
            "duration_s": 0, "checks": [
                {"name": "round-1", "status": status, "duration_s": 0}]})

    def _summarize(self):
        out = self.run_dir / "gate-result.json"
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = local_gate.main(["summarize", "--run-dir", str(self.run_dir),
                                    "--out", str(out),
                                    "--markdown", str(self.run_dir / "summary.md")])
        self.human = buffer.getvalue()
        return code, json.loads(out.read_text(encoding="utf-8"))

    def _primary(self, *, observed, cases):
        lane_artifacts(self.run_dir / "lanes" / "unit", status="fail",
                       classes=observed, cases=cases,
                       failures=self.WEDGE_FAILURE, attempts=self.WEDGE_ATTEMPTS,
                       batches=self.WEDGE_BATCHES)
        self._wedge_log(self.run_dir / "lanes" / "unit")

    def test_recovered_retry_passes_overall(self):
        """The wedge is recovered by one bounded round -> PASS, with the retry
        recorded in the result document."""
        self._primary(observed=("AlphaTests", "BetaTests"), cases=2)
        lane_artifacts(self.run_dir / "lanes" / "unit-recovery", status="pass",
                       classes=("GammaTests",), cases=1)
        self._recovery_phase("pass")
        code, doc = self._summarize()
        self.assertEqual(code, 0, doc["problems"])
        self.assertEqual(doc["verdict"], "PASS")
        self.assertEqual(doc["unit"]["classes_missing"], [])
        self.assertEqual(doc["unit"]["executions"], 3,
                         "one execution per class across all passes")
        infra = doc["infrastructure"]
        self.assertEqual(infra["failures"], 1)
        self.assertEqual(infra["retries"], 1)
        # The wedge event is healed by the round: reported as recovered, with
        # the round recorded as its healer - not as a bare "it got better".
        self.assertEqual(infra["recovered"], 1)
        self.assertEqual(infra["persistent"], 0)
        self.assertEqual(
            infra["events"]["infrastructure_failures"][0]["recovered_by"],
            "gate recovery round")
        self.assertEqual(infra["retry_detail"][0]["name"], "round-1")
        self.assertEqual(len(doc["unit"]["passes"]), 2)
        # The round is recorded, never hidden: both the machine-readable
        # document and the human summary carry it.
        self.assertIn("recovered", self.human)
        self.assertIn("recovery", json.dumps(doc))

    def test_recurrence_after_recovery_fails_as_infrastructure(self):
        """The same class comes back after the round -> FAIL (infrastructure),
        and no third attempt is made."""
        self._primary(observed=("AlphaTests", "BetaTests"), cases=2)
        lane_artifacts(self.run_dir / "lanes" / "unit-recovery", status="fail",
                       classes=(), cases=0, failures=self.WEDGE_FAILURE,
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}],
                       batches=[{"batch": 1, "classes": ["GammaTests"],
                                 "timeout_s": 500, "status": "test-failures",
                                 "attempts": [{"attempt": 1,
                                               "status": "test-failures",
                                               "seconds": 1.0, "failures": 1}]}])
        self._wedge_log(self.run_dir / "lanes" / "unit-recovery")
        self._recovery_phase("pass")
        code, doc = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertTrue(any("same simulator launch-refusal class" in p
                            for p in doc["problems"]), doc["problems"])
        self.assertIn("GammaTests", doc["unit"]["classes_missing"])
        self.assertEqual(doc["infrastructure"]["retries"], 1)
        self.assertTrue(doc["infrastructure"]["persistent"] >= 1)

    def test_genuine_assertion_never_enters_recovery(self):
        """With a real assertion present the round is not even projected, and
        the gate fails on the assertion."""
        lane_artifacts(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=3,
                       failures=[{"class": "BetaTests", "test": "testBoom",
                                  "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}])
        self._wedge_log(self.run_dir / "lanes" / "unit")
        code, doc = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["unit"]["failures"], 1)
        self.assertEqual(doc["infrastructure"]["retries"], 0)
        self.assertFalse(os.path.isdir(self.run_dir / "lanes" / "unit-recovery"))

    def test_counts_are_not_double_counted_across_passes(self):
        """A class that a later pass re-reported is counted once, and the
        re-run is visible rather than silently buried."""
        self._primary(observed=("AlphaTests", "BetaTests", "GammaTests"), cases=3)
        # A recovery pass that re-ran everything (which the gate never does:
        # only uncompleted work is retried) must not inflate the total.
        lane_artifacts(self.run_dir / "lanes" / "unit-recovery", status="pass",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=3)
        self._recovery_phase("pass")
        code, doc = self._summarize()
        self.assertEqual(code, 0, doc["problems"])
        self.assertEqual(doc["unit"]["executions"], 3,
                         "3 executions, not 6, across two passes")
        self.assertEqual(sorted(doc["unit"]["reread_classes"]),
                         ["AlphaTests", "BetaTests", "GammaTests"])
        self.assertTrue(any("more than one pass" in c for c in doc["caveats"]),
                        "the re-run is reported as a caveat, not hidden")

    def test_stale_not_executed_for_a_whole_batch_is_dropped(self):
        """A "not executed" entry names work as a batch ("A,B"), so it is only
        stale when BOTH classes have results - and the coverage check has to
        split the name to see that (a whole-string match never would)."""
        lane_artifacts(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests",), cases=1,
                       failures=self.WEDGE_FAILURE,
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"},
                                 {"mode": "batch", "n": 2, "class": "all",
                                  "status": "not_run"}],
                       batches=[
                           {"batch": 1, "classes": ["AlphaTests"],
                            "timeout_s": 600, "status": "test-failures",
                            "attempts": [{"attempt": 1, "status": "test-failures",
                                          "seconds": 1.0, "failures": 1}]},
                           {"batch": 2, "classes": ["BetaTests", "GammaTests"],
                            "timeout_s": 500, "status": "not_run",
                            "attempts": []}])
        self._wedge_log(self.run_dir / "lanes" / "unit")
        lane_artifacts(self.run_dir / "lanes" / "unit-recovery", status="pass",
                       classes=("BetaTests", "GammaTests"), cases=2)
        self._recovery_phase("pass")
        code, doc = self._summarize()
        self.assertEqual(code, 0, doc["problems"])
        self.assertEqual(doc["unit"]["not_executed"], [],
                         "both classes of the batch have results now")
        self.assertFalse(any("not executed" in p for p in doc["problems"]))

    def test_a_wedged_repetition_is_satisfied_by_its_one_retry(self):
        """A repetition lost to the launcher is retried once and counts as
        passed when that retry is clean - the wedge is not the test's fault."""
        self._primary(observed=("AlphaTests", "BetaTests", "GammaTests"), cases=3)
        meta = json.loads((self.run_dir / "meta.json").read_text(encoding="utf-8"))
        meta["expected"]["repeat_classes"] = ["AlphaTests"]
        meta["expected"]["repeat_iterations"] = 1
        write_json(self.run_dir / "meta.json", meta)
        base = self.run_dir / "repeats" / "AlphaTests"
        lane_artifacts(base / "iter-1", status="fail", classes=(), cases=0,
                       failures=[{"class": "System Failures",
                                  "test": "Conduit encountered an error",
                                  "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}],
                       batches=[{"batch": 1, "classes": ["AlphaTests"],
                                 "timeout_s": 600, "status": "test-failures",
                                 "attempts": [{"attempt": 1,
                                               "status": "test-failures",
                                               "seconds": 1.0, "failures": 1}]}])
        self._wedge_log(base / "iter-1")
        lane_artifacts(base / "iter-1-retry", status="pass",
                       classes=("AlphaTests",), cases=2)
        self._recovery_phase("pass")
        code, doc = self._summarize()
        entry = doc["focused_repeats"]["classes"][0]
        self.assertTrue(entry["iterations"][0]["satisfied"])
        self.assertEqual(entry["iterations"][0]["attempts_count"], 2)
        self.assertFalse(any("AlphaTests iteration 1" in p
                             for p in doc["problems"]), doc["problems"])

    def test_a_genuine_failure_is_final_across_attempts(self):
        """A genuine failing test is never satisfied by a later attempt: the
        repetition failed, and no retry may launder it."""
        self._primary(observed=("AlphaTests", "BetaTests", "GammaTests"), cases=3)
        meta = json.loads((self.run_dir / "meta.json").read_text(encoding="utf-8"))
        meta["expected"]["repeat_classes"] = ["AlphaTests"]
        meta["expected"]["repeat_iterations"] = 1
        write_json(self.run_dir / "meta.json", meta)
        base = self.run_dir / "repeats" / "AlphaTests"
        lane_artifacts(base / "iter-1", status="fail",
                       classes=("AlphaTests",), cases=2,
                       failures=[{"class": "AlphaTests", "test": "testBoom",
                                  "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}])
        lane_artifacts(base / "iter-1-retry", status="pass",
                       classes=("AlphaTests",), cases=2)
        code, doc = self._summarize()
        entry = doc["focused_repeats"]["classes"][0]
        self.assertTrue(entry["iterations"][0]["genuine_failure"])
        self.assertFalse(entry["iterations"][0]["satisfied"])
        self.assertEqual(code, 1)
        self.assertTrue(any("genuine test failure" in p for p in doc["problems"]))

    def test_gate_simulator_is_recorded(self):
        self._primary(observed=("AlphaTests", "BetaTests"), cases=2)
        lane_artifacts(self.run_dir / "lanes" / "unit-recovery", status="pass",
                       classes=("GammaTests",), cases=1)
        self._recovery_phase("pass")
        _, doc = self._summarize()
        self.assertEqual(doc["simulator"]["name"], "Conduit CI Gate")
        self.assertEqual(doc["simulator"]["udid"], "GATE-DEVICE")


class UIRecoveryVerdictTests(unittest.TestCase):
    """UI recovery is judged exactly like unit recovery.

    The shell writes a UI retry's evidence to lanes/ui-recovery; if the
    summarizer ignored it, recovered classes would be reported as never
    executed while the run's own recovery record claimed the opposite.
    """

    SHA = "1" * 40
    WEDGE_FAILURE = [{"class": "System Failures",
                      "test": "Conduit encountered an error", "attempts": []}]
    BUSY_LOG = ("Simulator device failed to launch com.milim.relay "
                "(BSErrorCodeDescription=Busy)")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.run_dir = Path(self.tmp.name)
        # Two UI classes so a partial recovery is expressible.
        write_json(self.run_dir / "lanes.json", {
            "schema_version": 1,
            "unit": {"classes": ["AlphaTests", "BetaTests", "GammaTests"]},
            "ui": {"classes": ["LaunchUITests", "SettingsUITests"]},
        })
        write_json(self.run_dir / "meta.json", {
            "schema_version": 1, "requested_ref": "origin/main",
            "tested_sha": self.SHA, "xcode_version": "Xcode 27.0",
            "simulator": {"name": "Conduit CI Gate", "runtime": "iOS 26.5",
                          "udid": "6D08B063-B890-4D18-893B-D1E89E119919"},
            "started_at": "2026-09-22T00:00:00Z",
            "finished_at": "2026-09-22T01:00:00Z", "wall_s": 3600,
            "allowed_recovered_infrastructure": False,
            "static_checks_enabled": True, "repeat_policy_enabled": False,
            "run_flags": {"lock_used": True, "simulator_prep": True},
            "expected": {"unit_classes": 3, "unit_batches": 1, "ui_classes": 2,
                         "repeat_classes": [], "repeat_iterations": 0},
        })
        write_json(self.run_dir / "static" / "phase.json", {
            "schema_version": 1, "phase": "static", "status": "pass",
            "duration_s": 5, "checks": [{"name": "plan-validate",
                                         "status": "pass", "duration_s": 1}]})
        write_json(self.run_dir / "build" / "phase.json", {
            "schema_version": 1, "phase": "build", "status": "pass",
            "duration_s": 30, "details": {"xctestrun": "/tmp/x.xctestrun"}})
        # A clean unit lane so only the UI suite decides the verdict.
        lane_artifacts(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=3, batches=[{"batch": 1,
                                          "classes": ["AlphaTests", "BetaTests",
                                                      "GammaTests"],
                                          "timeout_s": 600, "status": "pass",
                                          "attempts": [{"attempt": 1,
                                                        "status": "passed",
                                                        "seconds": 1.0,
                                                        "failures": 0}]}])
        # A round that did not run: the two recovery tests upgrade it below,
        # and a genuine failure must leave retries at 0.
        write_json(self.run_dir / "recovery" / "phase.json", {
            "schema_version": 1, "phase": "recovery", "status": "skipped",
            "duration_s": 0, "checks": []})

    def _wedge_lane(self, lane_dir, classes=None):
        lane_artifacts(lane_dir, status="fail", classes=(), cases=0,
                       failures=self.WEDGE_FAILURE, batches=[],
                       attempts=[{"mode": "class", "n": 1, "class": "any",
                                  "status": "test-failures"}])
        logs = Path(lane_dir) / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        (logs / "batch-a1.log").write_text(self.BUSY_LOG + chr(10),
                                           encoding="utf-8")

    def _round_ran(self):
        write_json(self.run_dir / "recovery" / "phase.json", {
            "schema_version": 1, "phase": "recovery", "status": "pass",
            "duration_s": 0, "checks": [{"name": "round-1", "status": "pass",
                                         "duration_s": 0}]})

    def _summarize(self):
        out = self.run_dir / "gate-result.json"
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = local_gate.main(["summarize", "--run-dir", str(self.run_dir),
                                    "--out", str(out),
                                    "--markdown", str(self.run_dir / "summary.md")])
        self.human = buffer.getvalue()
        return code, json.loads(out.read_text(encoding="utf-8"))

    def test_ui_infrastructure_failure_recovered_by_the_round_passes(self):
        self._round_ran()
        self._wedge_lane(self.run_dir / "lanes" / "ui")
        lane_artifacts(self.run_dir / "lanes" / "ui-recovery", status="pass",
                       classes=("LaunchUITests", "SettingsUITests"), cases=4)
        code, doc = self._summarize()
        self.assertEqual(code, 0, doc["problems"])
        self.assertEqual(doc["verdict"], "PASS")
        ui = doc["ui"]
        self.assertEqual(ui["classes_missing"], [],
                         "recovered classes must count as executed")
        self.assertEqual(ui["executions"], 4)
        self.assertTrue(any("recovery" in str(p.get("name"))
                            for p in ui["passes"]),
                        "the recovery pass must appear in the UI passes")
        self.assertEqual(doc["infrastructure"]["retries"], 1)
        self.assertEqual(ui["failures"], 0)

    def test_ui_recovery_that_recurs_fails_as_infrastructure(self):
        self._round_ran()
        self._wedge_lane(self.run_dir / "lanes" / "ui")
        self._wedge_lane(self.run_dir / "lanes" / "ui-recovery")
        code, doc = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertEqual(doc["ui"]["classes_missing"],
                         ["LaunchUITests", "SettingsUITests"])
        self.assertGreaterEqual(doc["infrastructure"]["persistent"], 1)
        self.assertTrue(any("UI recovery round hit the same simulator" in p
                            for p in doc["problems"]), doc["problems"])
        self.assertEqual(doc["ui"]["failures"], 0,
                         "a wedge is never an assertion failure")

    def test_genuine_ui_assertion_is_not_recovered(self):
        # A product failure: no recovery pass exists, and the assertion stands.
        lane_artifacts(self.run_dir / "lanes" / "ui", status="fail",
                       classes=("LaunchUITests",), cases=1,
                       failures=[{"class": "LaunchUITests",
                                  "test": "testLaunch", "attempts": []}],
                       attempts=[{"mode": "class", "n": 1,
                                  "class": "LaunchUITests",
                                  "status": "test-failures"}])
        code, doc = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["ui"]["failures"], 1)
        self.assertEqual(len(doc["ui"]["passes"]), 1,
                         "a genuine failure must not add a recovery pass")
        self.assertEqual(doc["infrastructure"]["retries"], 0)

    def test_only_the_failed_subset_is_recovered_without_double_counting(self):
        self._round_ran()
        # The shard ran LaunchUITests but was refused before SettingsUITests
        # produced results; the round retries only the incomplete class.
        lane_artifacts(self.run_dir / "lanes" / "ui", status="fail",
                       classes=("LaunchUITests",), cases=1, batches=[],
                       failures=self.WEDGE_FAILURE,
                       attempts=[{"mode": "class", "n": 1, "class": "any",
                                  "status": "test-failures"}])
        logs = self.run_dir / "lanes" / "ui" / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        (logs / "batch-a1.log").write_text(self.BUSY_LOG + chr(10),
                                           encoding="utf-8")
        lane_artifacts(self.run_dir / "lanes" / "ui-recovery", status="pass",
                       classes=("SettingsUITests",), cases=2)
        code, doc = self._summarize()
        ui = doc["ui"]
        self.assertEqual(ui["classes_missing"], [],
                         "completed only during recovery, so not unexecuted")
        # 1 case before + 2 after, counted once each: no class twice.
        self.assertEqual(ui["executions"], 3, ui.get("observed_names"))
        self.assertEqual(doc["infrastructure"]["retries"], 1)
        self.assertEqual(ui["failures"], 0)
        self.assertEqual(code, 0, doc["problems"])
        self.assertTrue(any("recovery" in c for c in doc.get("caveats", [])),
                        "the recovered run must carry a caveat")


class RecoverySpecTests(unittest.TestCase):
    """The bounded recovery round: what it is allowed for, and what it does."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.plan_path = self.root / "plan.json"
        write_json(self.plan_path, make_plan())
        self.lane_dir = self.root / "lanes" / "unit"
        self.lane_dir.mkdir(parents=True, exist_ok=True)

    def _lane(self, *, status="fail", classes=("AlphaTests",), cases=4,
              failures=(), attempts=None, batches=None, log_lines=None):
        lane_artifacts(self.lane_dir, status=status, classes=classes,
                       cases=cases, failures=failures, attempts=attempts,
                       batches=batches)
        logs = self.lane_dir / "logs"
        logs.mkdir(exist_ok=True)
        for index, line in enumerate(log_lines or [], start=1):
            (logs / "batch-{0}-a1.log".format(index)).write_text(
                line + "\n", encoding="utf-8")

    WEDGE_FAILURE = [{"class": "System Failures",
                      "test": "Conduit encountered an error", "attempts": []}]
    BUSY_LOG = ['iOSSimulator: 6930ECCE: Failed to launch app with identifier: '
                'com.milim.relay (error = ... BSErrorCodeDescription=Busy)']
    WEDGE_ATTEMPTS = [{"mode": "batch", "n": 1, "class": "all",
                       "status": "test-failures"},
                      {"mode": "batch", "n": 2, "class": "all",
                       "status": "not_run"}]
    WEDGE_BATCHES = [
        {"batch": 1, "classes": ["AlphaTests", "BetaTests"],
         "timeout_s": 600, "status": "test-failures",
         "attempts": [{"attempt": 1, "status": "test-failures",
                       "seconds": 1.0, "failures": 1}]},
        {"batch": 2, "classes": ["GammaTests"], "timeout_s": 500,
         "status": "not_run", "attempts": []},
    ]

    def _spec(self, **overrides):
        args = {"plan": str(self.plan_path), "lane": str(self.lane_dir),
                "out": str(self.root / "recovery.env")}
        args.update(overrides)
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = local_gate.main(["recovery-spec"] + [
                item for key, value in args.items() for item in ("--" + key, value)])
        values = {}
        env = self.root / "recovery.env"
        if env.exists():
            for line in env.read_text(encoding="utf-8").splitlines():
                key, _, value = line.partition("=")
                values[key] = shlex.split(value)[0] if value.strip() else ""
        return code, values

    def test_refused_when_a_genuine_assertion_is_present(self):
        """A product failure must never be retried around - the round is not
        even projected."""
        self._lane(classes=("AlphaTests", "BetaTests"), cases=7,
                   failures=[{"class": "BetaTests", "test": "testBoom",
                              "attempts": []}],
                   attempts=[{"mode": "batch", "n": 1, "class": "all",
                              "status": "test-failures"}],
                   log_lines=self.BUSY_LOG)
        code, _ = self._spec()
        self.assertEqual(code, 3)
        self.assertFalse((self.root / "recovery.env").exists())

    def test_refused_without_launch_refusal_evidence(self):
        """Infrastructure that is not the verified launch-refusal class is not
        recoverable: no synthetic entry, no Busy signature."""
        self._lane(status="fail", classes=("AlphaTests",), cases=1,
                   attempts=[{"mode": "batch", "n": 1, "class": "all",
                              "status": "unclassified"}])
        code, _ = self._spec()
        self.assertEqual(code, 3)

    def test_projects_the_incomplete_classes_for_the_wedge(self):
        self._lane(classes=("AlphaTests", "BetaTests"), cases=2,
                   failures=self.WEDGE_FAILURE, attempts=self.WEDGE_ATTEMPTS,
                   batches=self.WEDGE_BATCHES, log_lines=self.BUSY_LOG)
        code, values = self._spec()
        self.assertEqual(code, 0)
        self.assertEqual(values["GATE_RECOVERY_PRESENT"], "1")
        # Only work no pass completed: GammaTests (batch 2 never ran).
        self.assertEqual(values["GATE_RECOVERY_CLASSES"], "GammaTests")
        # The retry list is a TSV of chunks (one invocation per chunk of at most
        # 7 classes, so one wedged batch cannot eat the round), carrying the
        # planner's own batch budgets.
        tsv = (self.root / "recovery.tsv").read_text(encoding="utf-8").strip()
        self.assertEqual(tsv.count("\n") + 1, 1)
        self.assertTrue(tsv.startswith("retry-set\t"))
        self.assertIn('"timeout_s":500', tsv)

    def test_nothing_to_retry_when_everything_ran(self):
        self._lane(status="pass", classes=("AlphaTests", "BetaTests", "GammaTests"),
                   cases=3, log_lines=self.BUSY_LOG)
        code, values = self._spec()
        self.assertEqual(code, 0)
        self.assertEqual(values["GATE_RECOVERY_PRESENT"], "0")

    def test_ui_kind_projects_the_ui_classes(self):
        write_json(self.plan_path, make_plan())
        # The UI shard never launched, so no class has a result yet.
        self._lane(status="fail", classes=(), cases=0,
                   failures=self.WEDGE_FAILURE, batches=[],
                   attempts=[{"mode": "class", "n": 1, "class": "LaunchUITests",
                              "status": "test-failures"}],
                   log_lines=self.BUSY_LOG)
        code, values = self._spec(kind="ui")
        self.assertEqual(code, 0)
        self.assertEqual(values["GATE_RECOVERY_CLASSES"], "LaunchUITests")
        # The UI class's own watchdog travels with the retried class.
        self.assertIn("LaunchUITests=420", values["GATE_RECOVERY_CLASS_TIMEOUTS"])


class SimulatorTests(unittest.TestCase):
    def test_picks_newest_ios_runtime(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        devices = root / "devices.json"
        write_json(devices, {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                {"name": "iPhone 17 Pro", "udid": "OLD"}],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-10": [
                {"name": "iPhone 17 Pro", "udid": "NEW"}],
            "com.apple.CoreSimulator.SimRuntime.watchOS-26-0": [
                {"name": "iPhone 17 Pro", "udid": "WATCH"}],
        }})
        out = root / "simulator.json"
        code = local_gate.main(["simulator", "--devices", str(devices),
                                "--name", "iPhone 17 Pro", "--out", str(out)])
        self.assertEqual(code, 0)
        doc = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(doc["udid"], "NEW")
        self.assertEqual(doc["runtime"], "iOS 26.10")

    def test_missing_device_is_recorded_not_invented(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        devices = root / "devices.json"
        write_json(devices, {"devices": {}})
        out = root / "simulator.json"
        code = local_gate.main(["simulator", "--devices", str(devices),
                                "--name", "iPhone 17 Pro", "--out", str(out)])
        self.assertEqual(code, 0)
        doc = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(doc["udid"], "")
        self.assertEqual(doc["runtime"], "")


class SummarizeTests(unittest.TestCase):
    SHA = "1" * 40

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.run_dir = Path(self.tmp.name)

    def _layout(self, *, repeat_classes=("AlphaTests",), iterations=3,
                unit_classes=3, ui_classes=1, allow_recovered=False,
                static=True, unit_batches=1):
        write_json(self.run_dir / "lanes.json", {
            "schema_version": 1,
            "unit": {"classes": ["AlphaTests", "BetaTests", "GammaTests"]},
            "ui": ({"classes": ["LaunchUITests"]} if ui_classes else None),
        })
        write_json(self.run_dir / "meta.json", {
            "schema_version": 1,
            "requested_ref": "origin/main",
            "tested_sha": self.SHA,
            "xcode_version": "Xcode 27.0 Build version 27A1",
            "simulator": {"name": "iPhone 17 Pro", "runtime": "iOS 26.0",
                          "udid": "U"},
            "started_at": "2026-09-21T00:00:00Z",
            "finished_at": "2026-09-21T01:00:00Z",
            "wall_s": 3600,
            "allowed_recovered_infrastructure": allow_recovered,
            "static_checks_enabled": static,
            "repeat_policy_enabled": bool(repeat_classes) and iterations > 0,
            "expected": {
                "unit_classes": unit_classes,
                "unit_batches": unit_batches,
                "ui_classes": ui_classes,
                "repeat_classes": list(repeat_classes),
                "repeat_iterations": iterations,
            },
        })
        write_json(self.run_dir / "static" / "phase.json", {
            "schema_version": 1, "phase": "static", "status": "pass",
            "duration_s": 30, "checks": [
                {"name": "plan-validate", "status": "pass", "duration_s": 1},
                {"name": "ci-tooling-regression", "status": "pass", "duration_s": 20},
                {"name": "localization-coverage", "status": "pass", "duration_s": 2},
            ]})
        write_json(self.run_dir / "build" / "phase.json", {
            "schema_version": 1, "phase": "build", "status": "pass",
            "duration_s": 300,
            "details": {"xctestrun": "/tmp/derived-data/Conduit.xctestrun"}})
        lane_artifacts(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11,
                       batches=[
                           {"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                            "timeout_s": 600, "status": "pass",
                            "attempts": [{"attempt": 1, "status": "passed",
                                          "seconds": 1.0, "failures": 0}]},
                           {"batch": 2, "classes": ["GammaTests"],
                            "timeout_s": 500, "status": "pass",
                            "attempts": [{"attempt": 1, "status": "passed",
                                          "seconds": 1.0, "failures": 0}]},
                       ])
        if ui_classes:
            lane_artifacts(self.run_dir / "lanes" / "ui",
                           classes=("LaunchUITests",), cases=3)

    def _repeat_artifacts(self, klass, iterations, status="pass", cases=2,
                          **kwargs):
        for i in range(1, iterations + 1):
            lane_artifacts(self.run_dir / "repeats" / klass / "iter-{0}".format(i),
                           status=status, classes=(klass,), cases=cases, **kwargs)

    def _summarize(self):
        out = self.run_dir / "gate-result.json"
        markdown = self.run_dir / "summary.md"
        # The human summary is part of the contract (it must name the tested
        # commit), so it is captured rather than left to clutter the suite
        # output.
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = local_gate.main(["summarize", "--run-dir", str(self.run_dir),
                                    "--out", str(out), "--markdown", str(markdown)])
        self.human_output = buffer.getvalue()
        doc = json.loads(out.read_text(encoding="utf-8"))
        return code, doc, markdown

    def test_clean_run_passes_with_counts(self):
        self._layout(unit_batches=2)
        self._repeat_artifacts("AlphaTests", 3)
        code, doc, markdown = self._summarize()
        self.assertEqual(code, 0)
        self.assertEqual(doc["verdict"], "PASS")
        self.assertEqual(doc["tested_sha"], self.SHA)
        self.assertEqual(doc["unit"]["executions"], 11)
        self.assertEqual(doc["unit"]["failures"], 0)
        self.assertEqual(doc["ui"]["executions"], 3)
        self.assertEqual(doc["ui"]["failures"], 0)
        self.assertEqual(doc["focused_repeats"]["executions"], 6)
        self.assertEqual(doc["focused_repeats"]["failures"], 0)
        self.assertEqual(doc["infrastructure"]["failures"], 0)
        self.assertFalse(doc["partial"])
        self.assertIn("PASS", markdown.read_text(encoding="utf-8"))
        # The result must name the exact tested commit, not just a ref.
        self.assertIn(self.SHA, self.human_output)
        self.assertIn(self.SHA, markdown.read_text(encoding="utf-8"))

    def test_assertion_failure_is_reported_as_assertion(self):
        self._layout(repeat_classes=())
        lane_artifacts(self.run_dir / "lanes" / "unit",
                       status="fail",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11,
                       failures=[{"class": "BetaTests", "test": "testBoom",
                                  "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}],
                       batches=[{"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                                 "timeout_s": 600, "status": "test-failures",
                                 "attempts": [{"attempt": 1,
                                               "status": "test-failures",
                                               "seconds": 1.0, "failures": 1}]}])
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertEqual(doc["unit"]["failures"], 1)
        self.assertTrue(doc["unit"]["assertion_failures"])
        # An assertion failure must never be dressed up as infrastructure.
        self.assertEqual(doc["infrastructure"]["failures"], 0)

    def test_infrastructure_failure_is_reported_as_infrastructure(self):
        self._layout(repeat_classes=())
        lane_artifacts(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11, failures=[],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "infra-error"}],
                       batches=[{"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                                 "timeout_s": 600, "status": "infra-error",
                                 "attempts": [{"attempt": 1,
                                               "status": "infra-error",
                                               "seconds": 1.0, "failures": 0}]}])
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertEqual(doc["unit"]["failures"], 0, "no test asserted anything")
        self.assertEqual(doc["infrastructure"]["failures"], 1)

    def test_recovered_infrastructure_fails_by_default(self):
        """A recovered wedge means the run is not trustworthy evidence; the
        operator reruns it. Only the explicit opt-in downgrades it."""
        self._layout(repeat_classes=())
        lane_artifacts(self.run_dir / "lanes" / "unit", status="pass",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11, retried=("BetaTests",),
                       infra_recovered=("BetaTests",),
                       attempts=[
                           {"mode": "batch", "n": 1, "class": "all",
                            "status": "infra-error"},
                           {"mode": "batch-retry", "n": 1, "class": "all",
                            "status": "passed"}],
                       batches=[{"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                                 "timeout_s": 600, "status": "pass",
                                 "attempts": [
                                     {"attempt": 1, "status": "infra-error",
                                      "seconds": 1.0, "failures": 0},
                                     {"attempt": 2, "status": "passed",
                                      "seconds": 1.0, "failures": 0}]}])
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["infrastructure"]["recovered"], 1)
        # `infrastructure.retries` counts the GATE's bounded recovery round; the
        # lane runner's own retry attempts are reported in events.
        self.assertEqual(doc["infrastructure"]["retries"], 0)
        self.assertEqual(len(doc["infrastructure"]["events"]["retries"]), 1)

    def test_recovered_infrastructure_may_be_allowed_explicitly(self):
        self._layout(repeat_classes=(), allow_recovered=True)
        lane_artifacts(self.run_dir / "lanes" / "unit", status="pass",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11, infra_recovered=("BetaTests",),
                       retried=("BetaTests",),
                       attempts=[
                           {"mode": "batch", "n": 1, "class": "all",
                            "status": "infra-error"},
                           {"mode": "batch-retry", "n": 1, "class": "all",
                            "status": "passed"}],
                       batches=[{"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                                 "timeout_s": 600, "status": "pass",
                                 "attempts": [
                                     {"attempt": 1, "status": "infra-error",
                                      "seconds": 1.0, "failures": 0},
                                     {"attempt": 2, "status": "passed",
                                      "seconds": 1.0, "failures": 0}]}])
        code, doc, _ = self._summarize()
        self.assertEqual(code, 0, doc["problems"])
        self.assertEqual(doc["verdict"], "PASS")
        self.assertEqual(doc["infrastructure"]["recovered"], 1)

    def test_assertion_retried_until_green_always_fails(self):
        self._layout(repeat_classes=(), allow_recovered=True)
        lane_artifacts(self.run_dir / "lanes" / "unit", status="pass",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11,
                       failures=[{"class": "BetaTests", "test": "testFlimsy",
                                  "attempts": []}],
                       attempts=[
                           {"mode": "batch", "n": 1, "class": "all",
                            "status": "test-failures"},
                           {"mode": "batch-retry", "n": 1, "class": "all",
                            "status": "passed"}],
                       batches=[{"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                                 "timeout_s": 600, "status": "pass",
                                 "attempts": [
                                     {"attempt": 1, "status": "test-failures",
                                      "seconds": 1.0, "failures": 2},
                                     {"attempt": 2, "status": "passed",
                                      "seconds": 1.0, "failures": 0}]}])
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertEqual(doc["assertion_rerun_until_green"], 1)
        self.assertTrue(any("retried until they passed" in p
                            for p in doc["problems"]))

    def test_test_runner_launch_failure_is_infrastructure_not_an_assertion(self):
        """Regression: the first real gate run reported "genuine XCTest
        assertion failures present" for a Simulator that refused to launch the
        test host. The result bundle's only "failure" was XCTest's synthetic
        System Failures entry, which reports the RUN, not a test."""
        self._layout(repeat_classes=())
        lane_artifacts(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11,
                       failures=[{"class": "System Failures",
                                  "test": "Conduit encountered an error",
                                  "attempts": [{"result": "Failed",
                                                "seconds": 0.0}]}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "passed"},
                                 {"mode": "batch", "n": 2, "class": "all",
                                  "status": "test-failures"}],
                       batches=[
                           {"batch": 1, "classes": ["AlphaTests"], "timeout_s": 600,
                            "status": "pass",
                            "attempts": [{"attempt": 1, "status": "passed",
                                          "seconds": 1.0, "failures": 0}]},
                           {"batch": 2, "classes": ["BetaTests", "GammaTests"],
                            "timeout_s": 600, "status": "test-failures",
                            "attempts": [{"attempt": 1, "status": "test-failures",
                                          "seconds": 1.0, "failures": 1}]},
                       ])
        # The per-invocation extraction parts are what attribute the synthetic
        # failure to the invocation that produced it.
        parts = self.run_dir / "lanes" / "unit" / "parts"
        write_json(parts / "detail-batch-1-a1.json",
                   {"schema_version": 1, "failures": [], "attempts": []})
        write_json(parts / "detail-batch-2-a1.json",
                   {"schema_version": 1, "attempts": [], "failures": [
                       {"class": "System Failures",
                        "test": "Conduit encountered an error", "attempts": []}]})
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertEqual(doc["unit"]["failures"], 0,
                         "no test asserted anything")
        self.assertEqual(doc["unit"]["synthetic_failures"], 1)
        self.assertTrue(doc["infrastructure"]["failures"] >= 1)
        self.assertTrue(any("never started the app" in p for p in doc["problems"]),
                        doc["problems"])
        self.assertFalse(any("genuine XCTest assertion failures" in p
                             for p in doc["problems"]))

    def test_real_failure_beside_a_synthetic_one_is_still_an_assertion(self):
        self._layout(repeat_classes=())
        # The merged detail document is the UNION of the per-invocation parts
        # (that is what the runner's merge-parts produces), so it carries both
        # entries while the parts attribute each one to its invocation.
        lane_artifacts(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11,
                       failures=[{"class": "BetaTests", "test": "testBoom",
                                  "attempts": []},
                                 {"class": "System Failures",
                                  "test": "Simulator died", "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}])
        parts = self.run_dir / "lanes" / "unit" / "parts"
        write_json(parts / "detail-batch-1-a1.json",
                   {"schema_version": 1, "attempts": [], "failures": [
                       {"class": "BetaTests", "test": "testBoom", "attempts": []},
                       {"class": "System Failures", "test": "Simulator died",
                        "attempts": []}]})
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["unit"]["failures"], 1)
        self.assertEqual(doc["unit"]["synthetic_failures"], 1)
        self.assertTrue(doc["unit"]["assertion_failures"])
        self.assertTrue(any("genuine XCTest assertion failures" in p
                            for p in doc["problems"]))

    def test_unexecuted_batches_are_continued_and_merged(self):
        """One failing batch must not hide the rest of the suite: the shell
        runs the never-reached batches as a continuation, and the aggregate
        coverage is what the gate certifies."""
        self._layout(repeat_classes=(), unit_batches=2)
        # The failing batch reports the classes it DID run (observations),
        # which is what makes the aggregate coverage check meaningful: the
        # never-reached class is the one in the batch the lane stopped before.
        lane_artifacts(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests", "BetaTests"),
                       cases=4,
                       failures=[{"class": "AlphaTests", "test": "testBoom",
                                  "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"},
                                 {"mode": "batch", "n": 2, "class": "all",
                                  "status": "not_run"}],
                       batches=[
                           {"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                            "timeout_s": 600, "status": "test-failures",
                            "attempts": [{"attempt": 1, "status": "test-failures",
                                          "seconds": 1.0, "failures": 1}]},
                           {"batch": 2, "classes": ["GammaTests"],
                            "timeout_s": 500, "status": "not_run", "attempts": []},
                       ])
        lane_artifacts(self.run_dir / "lanes" / "unit-continuation",
                       status="pass", classes=("GammaTests",), cases=3)
        code, doc, _ = self._summarize()
        # Still a FAIL (a real assertion failed), but now complete: every
        # planned class has a result and the verdict names the real failure.
        self.assertEqual(code, 1)
        self.assertEqual(doc["unit"]["classes_missing"], [])
        self.assertEqual(doc["unit"]["classes_observed"], 3)
        self.assertEqual(doc["unit"]["executions"], 7)
        self.assertEqual(doc["unit"]["failures"], 1)
        # The continuation is pass 1 of the merged passes, and it executed the
        # class the primary lane never reached.
        self.assertEqual(doc["unit"]["passes"][1]["executions"], 3)
        self.assertEqual(doc["unit"]["reread_classes"], [])
        self.assertFalse(any("classes never executed" in p
                             for p in doc["unit"]["problems"]))

    def test_persistent_infrastructure_fails_even_when_recovery_is_allowed(self):
        """The opt-in is about recovered anomalies; a persistent one is
        never acceptable evidence."""
        self._layout(repeat_classes=(), allow_recovered=True)
        lane_artifacts(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11, failures=[], persistent_infra=("BetaTests",),
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "infra-error"},
                                 {"mode": "batch-retry", "n": 1, "class": "all",
                                  "status": "infra-error"}],
                       batches=[{"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                                 "timeout_s": 600, "status": "infra-error",
                                 "attempts": [
                                     {"attempt": 1, "status": "infra-error",
                                      "seconds": 1.0, "failures": 0},
                                     {"attempt": 2, "status": "infra-error",
                                      "seconds": 1.0, "failures": 0}]}])
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["infrastructure"]["persistent"], 1)
        self.assertEqual(doc["infrastructure"]["recovered"], 0)

    def test_recovered_label_the_chain_cannot_explain_fails_closed(self):
        """The lane runner's own recovered-class label without matching
        attempt evidence means the record is incomplete - that is not a
        clean run."""
        self._layout(repeat_classes=())
        lane_artifacts(self.run_dir / "lanes" / "unit", status="pass",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11, infra_recovered=("GammaTests",))
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertTrue(any("does not account for" in p for p in doc["problems"]))

    def test_missing_classes_fail_completeness(self):
        self._layout(repeat_classes=())
        lane_artifacts(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests"), cases=7)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertIn("GammaTests", doc["unit"]["classes_missing"])
        self.assertTrue(any("never executed" in p for p in doc["problems"]))

    def test_unreadable_extraction_fails_closed(self):
        """No observations.json means the execution count cannot be
        certified; a green lane verdict alone is not enough."""
        self._layout(repeat_classes=())
        lane_artifacts(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11, observations=False)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertIsNone(doc["unit"]["executions"])

    def test_missing_lane_result_fails_closed(self):
        self._layout(repeat_classes=())
        lane_artifacts(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11, lane_result=False)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["unit"]["status"], "missing")

    def test_short_sha_fails(self):
        self._layout(repeat_classes=())
        meta = json.loads((self.run_dir / "meta.json").read_text(encoding="utf-8"))
        meta["tested_sha"] = "deadbee"
        write_json(self.run_dir / "meta.json", meta)
        lane_artifacts(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertTrue(any("40-character" in p for p in doc["problems"]))

    def test_repeat_iteration_missing_fails(self):
        self._layout()
        self._repeat_artifacts("AlphaTests", 2)  # policy said 3
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertIn("iterations", " ".join(doc["problems"]))

    def test_repeat_assertion_failure_fails(self):
        self._layout()
        self._repeat_artifacts("AlphaTests", 3)
        lane_artifacts(self.run_dir / "repeats" / "AlphaTests" / "iter-2",
                       status="fail", classes=("AlphaTests",), cases=2,
                       failures=[{"class": "AlphaTests", "test": "testFlake",
                                  "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}])
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["focused_repeats"]["failures"], 1)

    def test_failed_static_phase_fails_the_gate(self):
        self._layout(repeat_classes=())
        write_json(self.run_dir / "static" / "phase.json", {
            "schema_version": 1, "phase": "static", "status": "fail",
            "duration_s": 30, "checks": [
                {"name": "localization-coverage", "status": "fail",
                 "duration_s": 2}]})
        lane_artifacts(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertTrue(any("localization-coverage" in p for p in doc["problems"]))

    def test_skipped_static_marks_the_run_partial(self):
        self._layout(repeat_classes=(), static=False)
        lane_artifacts(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 0)
        self.assertTrue(doc["partial"])
        self.assertTrue(any("static checks skipped" in r
                            for r in doc["partial_reasons"]))

    def test_disabled_repeat_policy_passes_but_is_flagged_partial(self):
        """Explicitly narrowing the gate is allowed; pretending the narrowed
        run was the exhaustive one is not."""
        self._layout(repeat_classes=(), iterations=0)
        lane_artifacts(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 0)
        self.assertFalse(doc["focused_repeats"]["enabled"])
        self.assertTrue(doc["partial"])
        self.assertTrue(any("repeat policy disabled" in r
                            for r in doc["partial_reasons"]))
        self.assertIn("PARTIAL", self.human_output)

    def test_missing_plan_projection_is_a_problem_not_a_crash(self):
        """meta.json carries class COUNTS, not names: with no projection the
        gate cannot check coverage, and it must say so rather than crash or
        wave the run through."""
        self._layout(repeat_classes=())
        lane_artifacts(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        (self.run_dir / "lanes.json").unlink()
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertTrue(any("planned class list is missing" in p
                            for p in doc["problems"]))

    def test_projection_count_mismatch_is_a_problem(self):
        self._layout(repeat_classes=())
        lane_artifacts(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        write_json(self.run_dir / "lanes.json", {
            "schema_version": 1,
            "unit": {"classes": ["AlphaTests"]},
            "ui": {"classes": ["LaunchUITests"]},
        })
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertTrue(any("lists 1 classes but the run recorded 3" in p
                            for p in doc["problems"]),
                        doc["problems"])

    def test_ui_classes_without_a_lane_is_a_problem(self):
        """A planner regression that dropped the UI lane must not read as a
        clean 'ui: skipped' pass when UI classes were expected."""
        self._layout(repeat_classes=(), ui_classes=1)
        lane_artifacts(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        write_json(self.run_dir / "lanes.json", {
            "schema_version": 1,
            "unit": {"classes": ["AlphaTests", "BetaTests", "GammaTests"]},
            "ui": None,
        })
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertTrue(any("planned no UI lane" in p for p in doc["problems"]))

    def test_a_failed_lane_verdict_always_fails_the_gate(self):
        """The runner's own verdict is evidence in its own right: green-looking
        event classification must not be able to contradict it."""
        self._layout(repeat_classes=())
        lane_artifacts(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertTrue(any("lane runner verdict is 'fail'" in p
                            for p in doc["problems"]), doc["problems"])

    def test_ui_diagnosis_parts_are_attributed_to_their_class(self):
        """The runner writes UI diagnosis parts as detail-<Cls>-a<k>.json (no
        'class-' infix). Without that key the synthetic launch failure in a
        shard that ALSO has a real failure would be mislabeled as an
        assertion."""
        self._layout(repeat_classes=())
        lane_artifacts(self.run_dir / "lanes" / "ui", status="fail",
                       classes=("LaunchUITests",), cases=2,
                       failures=[{"class": "System Failures",
                                  "test": "Conduit encountered an error",
                                  "attempts": []}],
                       attempts=[{"mode": "class", "n": 1,
                                  "class": "LaunchUITests",
                                  "status": "test-failures"}],
                       batches=[])
        parts = self.run_dir / "lanes" / "ui" / "parts"
        write_json(parts / "detail-LaunchUITests-a1.json",
                   {"schema_version": 1, "attempts": [], "failures": [
                       {"class": "System Failures",
                        "test": "Conduit encountered an error", "attempts": []}]})
        # The unit lane is metric-neutral for this test: make it clean.
        lane_artifacts(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["ui"]["synthetic_failures"], 1)
        self.assertTrue(doc["ui"]["infrastructure_failures"],
                        "the launch failure must be infrastructure, not an assertion")
        self.assertFalse(doc["ui"]["assertion_failures"])

    def test_ui_shard_targeted_retry_is_seen_as_one_work_item(self):
        """A UI shard has ONE batch, but its targeted retry is recorded under
        batch-retry with n=2: the two must be read as the same work item, or
        "failed an assertion then passed" is reported as a plain assertion."""
        self._layout(repeat_classes=())
        lane_artifacts(self.run_dir / "lanes" / "ui", status="pass",
                       classes=("LaunchUITests",), cases=2,
                       failures=[{"class": "LaunchUITests",
                                  "test": "testSomething", "attempts": []}],
                       attempts=[
                           {"mode": "batch", "n": 1, "class": "all",
                            "status": "test-failures"},
                           {"mode": "batch-retry", "n": 2, "class": "all",
                            "status": "passed"}],
                       batches=[])
        lane_artifacts(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertTrue(doc["assertion_rerun_until_green"] >= 1,
                        "the retried assertion must be reported as rerun-until-green")
        self.assertTrue(any("retried until they passed" in p
                            for p in doc["problems"]))

    def test_continuation_clears_stale_not_executed_evidence(self):
        """After the continuation runs the never-reached batches, the report
        must not still claim that work was not executed."""
        self._layout(repeat_classes=(), unit_batches=2)
        lane_artifacts(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests", "BetaTests"), cases=4,
                       failures=[{"class": "AlphaTests", "test": "testBoom",
                                  "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"},
                                 {"mode": "batch", "n": 2, "class": "all",
                                  "status": "not_run"}],
                       batches=[
                           {"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                            "timeout_s": 600, "status": "test-failures",
                            "attempts": [{"attempt": 1, "status": "test-failures",
                                          "seconds": 1.0, "failures": 1}]},
                           {"batch": 2, "classes": ["GammaTests"],
                            "timeout_s": 500, "status": "not_run", "attempts": []},
                       ])
        lane_artifacts(self.run_dir / "lanes" / "unit-continuation",
                       status="pass", classes=("GammaTests",), cases=3)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["unit"]["not_executed"], [])
        self.assertEqual(doc["infrastructure"]["not_executed"], 0)
        self.assertFalse(any("not executed" in p for p in doc["unit"]["problems"]),
                         doc["unit"]["problems"])

    def test_weakening_flags_are_recorded_as_caveats(self):
        self._layout(repeat_classes=(), allow_recovered=True)
        meta = json.loads((self.run_dir / "meta.json").read_text(encoding="utf-8"))
        meta["run_flags"] = {"lock_used": False, "simulator_prep": False}
        write_json(self.run_dir / "meta.json", meta)
        lane_artifacts(self.run_dir / "lanes" / "unit", status="pass",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11, infra_recovered=("BetaTests",))
        code, doc, markdown = self._summarize()
        self.assertEqual(code, 0, doc["problems"])
        caveats = " ".join(doc["caveats"])
        self.assertIn("--no-lock", caveats)
        self.assertIn("--no-simulator-prep", caveats)
        self.assertIn("--allow-recovered-infrastructure", caveats)
        self.assertIn("CAVEAT", markdown.read_text(encoding="utf-8"))

    def test_failed_simulator_preparation_is_a_caveat(self):
        self._layout(repeat_classes=())
        write_json(self.run_dir / "sim-prep" / "phase.json", {
            "schema_version": 1, "phase": "sim-prep", "status": "fail",
            "duration_s": 0, "checks": [
                {"name": "unit", "status": "fail", "duration_s": 12}]})
        lane_artifacts(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 0, doc["problems"])
        self.assertTrue(any("Simulator preparation failed before unit" in c
                            for c in doc["caveats"]), doc["caveats"])

    def test_failed_build_fails_the_gate(self):
        self._layout(repeat_classes=(), ui_classes=0)
        write_json(self.run_dir / "build" / "phase.json", {
            "schema_version": 1, "phase": "build", "status": "fail",
            "duration_s": 60, "note": "no .xctestrun produced"})
        lane_artifacts(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["build"]["status"], "fail")


class ScriptContractTests(unittest.TestCase):
    """The gate script and its helper must stay wired to each other and to
    the existing tooling they reuse."""

    def setUp(self):
        self.script = Path(SCRIPTS_DIR) / "local-ci-gate.sh"
        if not self.script.exists():
            self.skipTest("local-ci-gate.sh not present")
        self.text = self.script.read_text(encoding="utf-8")

    def test_reuses_the_existing_lane_runner_and_planner(self):
        self.assertIn("ci-test-lane.sh", self.text)
        self.assertIn("plan-tests.py", self.text)
        self.assertIn("ci-build-for-testing.sh", self.text)

    def test_is_exhaustive_single_lane(self):
        self.assertIn("--min-lanes 1 --max-lanes 1", self.text)
        self.assertIn("--ui-min-lanes 1 --ui-max-lanes 1", self.text)

    def test_never_retries_genuine_assertions(self):
        # --iterations 1 is what removes Xcode's native retry from the gate.
        self.assertIn("--iterations 1", self.text)
        self.assertNotIn("--iterations 3", self.text)

    def test_uses_a_detached_throwaway_worktree(self):
        self.assertIn("worktree add --detach", self.text)
        self.assertIn("worktree remove --force", self.text)

    def test_the_gate_is_single_shot_and_never_restarts_itself(self):
        """One authoritative full-gate invocation per requested SHA.

        Whatever drives the gate must not be able to loop it into "until
        green": the script never re-executes itself after a verdict, and a
        second full run for a SHA that already has a result is refused unless
        the caller explicitly asks for one.
        """
        self.assertIn("--allow-another-run", self.text)
        self.assertIn("one authoritative full-gate invocation per requested SHA",
                      self.text)
        # No self-invocation and no self-re-exec anywhere in the RUNNABLE
        # body (the usage banner legitimately names the script).
        body = self.text.split("usage() {", 1)[-1].split("}", 1)[-1]
        for forbidden in ('bash "$0"', "bash $0", "exec bash", 'exec "$0"',
                          "local-ci-gate.sh", "while true"):
            self.assertNotIn(forbidden, body,
                             "the gate must be a single-shot program")
        # The verdict path exits exactly once, at the end.
        self.assertIn("exit 0", self.text)
        self.assertIn("exit 1", self.text)

    def test_never_stashes_or_touches_the_invoking_tree(self):
        for forbidden in ("git stash", "git checkout", "git reset",
                          "worktree prune", "git clean"):
            self.assertNotIn(forbidden, self.text)

    def test_requires_an_exact_ref(self):
        self.assertIn("--ref is required", self.text)


class PythonCompatibilityTests(unittest.TestCase):
    def test_helper_compiles_under_the_ci_interpreter(self):
        path = os.path.join(SCRIPTS_DIR, "local-gate.py")
        with open(path, encoding="utf-8") as fh:
            source = fh.read()
        compile(source, path, "exec")


if __name__ == "__main__":
    unittest.main()
