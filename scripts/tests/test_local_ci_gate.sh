#!/usr/bin/env bash
#
# Integration tests for scripts/local-ci-gate.sh.
#
# The gate orchestrates real Xcode project generation, a build-for-testing,
# the lane runner and the summarizer, so its contract with those pieces
# (argument shapes, paths, exit codes, the run directory layout) has no unit
# test: this suite builds a throwaway Conduit-shaped repository and drives the
# REAL gate against stub xcodegen/xcodebuild/xcrun binaries. No simulator, no
# Xcode, no macOS required - it runs on the Linux CI job as well.
#
# What it pins (each of these was a real defect or a real risk):
#   * a clean run exits 0 and reports the EXACT commit it tested;
#   * the repeat policy actually executes its iterations (a path mismatch
#     between the gate and its helper once made the loop run zero times while
#     the lane still reported "pass");
#   * the caller's working tree, index and stashes are untouched;
#   * a genuine assertion failure fails the gate and is reported as an
#     assertion; a test-runner/launch failure fails it and is reported as
#     infrastructure;
#   * a reused --run-dir is refused (a previous run's artifacts must never be
#     read back as evidence).
#
# Usage: bash scripts/tests/test_local_ci_gate.sh   (exit 0 = all cases pass)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
# CONDUIT_GATE_TEST_KEEP=1 leaves the throwaway fixture and its run directories
# in place for inspection instead of deleting them on exit.
if [ -n "${CONDUIT_GATE_TEST_KEEP:-}" ]; then
  echo "keeping the test workspace at $WORK"
  trap 'echo "kept: $WORK"' EXIT
else
  trap 'rm -rf "$WORK"' EXIT
fi

pass_count=0
fail_count=0
skip_count=0

ok()  { pass_count=$((pass_count + 1)); echo "  ok: $1"; }
bad() { fail_count=$((fail_count + 1)); echo "  FAIL: $1"; }

skip() { # $1 = what would have been asserted
  skip_count=$((skip_count + 1))
  echo "  skip: $1 (xcrun is not executable from Python on this platform)"
}

# Run the body only where the result bundle can actually be read.
needs_extraction() { [ "$EXTRACTION_SUPPORTED" -eq 1 ]; }

assert_eq() { # $1=desc $2=actual $3=expected
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (actual='$2' expected='$3')"; fi
}

assert_contains() { # $1=desc $2=haystack $3=needle
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1 (missing '$3' in: $(printf '%s' "$2" | head -c 400))" ;;
  esac
}

json_get() { # $1=file $2=python expression on `doc`
  python3 -c "
import json, sys
doc = json.load(open(sys.argv[1], encoding='utf-8'))
print(eval(sys.argv[2]))
" "$1" "$2" 2>/dev/null || printf ''
}

# --- stubs -------------------------------------------------------------------
write_stubs() {
  cat > "$STUBS/xcodegen" <<'EOF'
#!/bin/bash
# The gate only requires that project generation succeeds and that the
# generated project is never committed; nothing here reads it.
echo "xcodegen stub: $*"
exit 0
EOF

  cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
# -version is asked for the result document.
if [ "${1:-}" = "-version" ]; then
  echo "Xcode 27.0"
  echo "Build version 27A0stub"
  exit 0
fi
echo "xcodebuild stub: $*"
bundle=""
target="ConduitTests"
classes=""
for a in "$@"; do
  case "$a" in
    -resultBundlePath) ;;
    *.xcresult) bundle="$a"; mkdir -p "$a" ;;
    -only-testing:*) spec="${a#-only-testing:}"; target="${spec%%/*}"; classes="$classes ${spec#*/}" ;;
  esac
done
prev=""
for a in "$@"; do
  [ "$prev" = "-resultBundlePath" ] && { bundle="$a"; mkdir -p "$a"; }
  prev="$a"
done
if [ -z "$classes" ]; then
  classes=" $(cat "$FAKE_CLASSES_FALLBACK" 2>/dev/null)"
fi
# One unit batch per class in this fixture, so the batch index is recoverable
# from the result-bundle stem; the FAKE_* knobs decide that batch's verdict.
# A knob keyed on a batch number would ALSO hit the continuation pass, which
# renumbers its own batches from 1 - so the continuation is clean unless a knob
# explicitly targets it, and the cases below test the primary lane's stop.
stem="$(basename "$bundle" .xcresult)"
mode="pass"
case "$bundle" in
  *ui-recovery*)       mode="${FAKE_UI_RECOVERY:-pass}" ;;
  *unit-recovery*)     mode="${FAKE_RECOVERY_MODE:-pass}" ;;
  *unit-continuation*) mode="${FAKE_CONTINUATION_MODE:-pass}" ;;
  */lanes/ui/*)        mode="${FAKE_UI_BATCH:-pass}" ;;
  *)
    case "$stem" in
      batch-*) idx="${stem#batch-}"; idx="${idx%%-*}"; attempt="${stem##*-a}"
               eval "mode=\${FAKE_UNIT_B${idx}_A${attempt}:-pass}" ;;
      class-*) cls="${stem#class-}"; cls="${cls%-a*}"
               eval "mode=\${FAKE_CLASS_${cls}:-pass}" ;;
    esac
    ;;
esac
result="Passed"
extra_node=""
case "$mode" in
  fail) result="Failed" ;;
  crash)
    # The shape XCTest produces when the host never launched: a synthetic
    # "System Failures" entry, and NO real test case node.
    result="Failed"
    classes=""
    extra_node='{"nodeType": "Test Case", "name": "Conduit encountered an error", "result": "Failed", "durationInSeconds": 0.0}'
    ;;
esac
nodes=""
sep=""
for c in $classes; do
  nodes="$nodes$sep{\"nodeType\": \"Test Suite\", \"name\": \"$c\", \"result\": \"$result\",
    \"children\": [{\"nodeType\": \"Test Case\", \"name\": \"testSomething\", \"result\": \"$result\",
    \"durationInSeconds\": 0.1}]}"
  sep=","
done
[ -n "$extra_node" ] && { nodes="$nodes$sep{\"nodeType\": \"Test Suite\", \"name\": \"System Failures\", \"result\": \"Failed\",
  \"children\": [$extra_node]}"; }
cat > "$FAKE_CANNED" <<DOC
{"testNodes": [{"nodeType": "Test Plan", "name": "Conduit", "result": "Passed",
  "children": [{"nodeType": "Test bundle", "name": "$target", "result": "$result",
    "children": [$nodes]}]}]}
DOC
case "$mode" in
  crash) echo "Simulator device failed to launch com.milim.relay (stub)"; exit 65 ;;
  fail) echo "Test Case 'testSomething' failed (stub)"; exit 65 ;;
  infra) echo "test host quit unexpectedly (stub)"; exit 70 ;;
  *) exit 0 ;;
esac
EOF

  cat > "$STUBS/xcrun" <<'EOF'
#!/bin/bash
if [ "$1" = "xcresulttool" ]; then
  # `xcresulttool get test-results tests --path <bundle>`: serve what the
  # xcodebuild stub wrote for that invocation.
  cat "$FAKE_CANNED" 2>/dev/null || exit 0
  exit 0
fi
  if [ "$1" = "simctl" ]; then
    if [ "$2" = "create" ]; then
      # Model `simctl create`: it prints a runtime notice BEFORE the UDID, so
      # the gate has to match the UUID rather than take the whole output. A
      # test can remove the gate device from the listing below to exercise
      # this path.
      echo "No runtime specified, using 'iOS 26.5 (26.5 - 23F77) - com.apple.CoreSimulator.SimRuntime.iOS-26-5'"
      echo "6D08B063-B890-4D18-893B-D1E89E119919"
      exit 0
    fi
    if [ "$2 $3 $4" = "list devices available" ]; then
      if [ -n "${FAKE_NO_GATE_DEVICE:-}" ]; then
        cat <<'DEV'
{"devices" : {"com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
  { "udid" : "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
    "name" : "iPhone 17 Pro", "state" : "Booted" }]}}
DEV
      else
        cat <<'DEV'
{"devices" : {"com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
  { "udid" : "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
    "name" : "iPhone 17 Pro", "state" : "Booted" },
  { "udid" : "6D08B063-B890-4D18-893B-D1E89E119919",
    "name" : "Conduit CI Gate", "state" : "Shutdown" }]}}
DEV
      fi
      exit 0
    fi
  exit 0
fi
exit 0
EOF

  chmod +x "$STUBS/xcodegen" "$STUBS/xcodebuild" "$STUBS/xcrun"

  # Windows (MSYS/Cygwin) cannot exec an extension-less script: Python's
  # subprocess (the timing extractor shells out to `xcrun xcresulttool`) needs
  # a PATHEXT-visible name. CI runs this suite on Linux/macOS, where the plain
  # scripts are found; these shims exist so the suite is also runnable from a
  # Windows checkout instead of silently degrading to "extraction failed".
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      for name in xcodegen xcodebuild xcrun; do
        printf '@bash "%%~dp0%s" %%*\r\n' "$name" > "$STUBS/$name.cmd"
      done
      ;;
  esac
}

# --- fixture repository ------------------------------------------------------
# A Conduit-shaped tree: the real CI tooling under test, and stand-ins for the
# two pieces the gate only needs to SUCCEED at (project generation is stubbed
# through PATH; the build script is a fixture file, since its real
# implementation is CI v2's build job and is exercised on macOS).
make_fixture() { # $1 = path
  local repo="$1"
  mkdir -p "$repo/ConduitTests" "$repo/ConduitUITests" "$repo/Conduit" "$repo/scripts/tests"
  printf 'name: Conduit\n' > "$repo/project.yml"
  printf 'import Foundation\n' > "$repo/Conduit/App.swift"
  # 15 unit classes: enough for the planner to split them into THREE batches
  # (7/7/1 by the default 7-class batch cap), which is what makes the
  # continuation path reachable - a lane that stops on batch 2 still has a
  # batch it never reached.
  for name in Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota Kappa Lambda \
              Mu Nu Xi Omicron; do
    cat > "$repo/ConduitTests/${name}Tests.swift" <<SWIFT
import XCTest

final class ${name}Tests: XCTestCase {
    func testSomething() {}
}
SWIFT
  done
  cat > "$repo/ConduitUITests/LaunchUITests.swift" <<'SWIFT'
import XCTest

final class LaunchUITests: XCTestCase {
    func testSomething() {}
}
SWIFT
  for script in local-ci-gate.sh local-gate.py ci-gate-lock.sh plan-tests.py ci-test-lane.sh \
                ci-lib.sh extract-test-timings.py test-timings.json; do
    cp "$SCRIPTS/$script" "$repo/scripts/$script"
  done
  # The localization checker is CI infrastructure, not the gate's subject; a
  # passing stand-in keeps the static phase's contract (exit code) under test.
  # FAKE_STATIC_SLEEP makes it hang, so an interrupt can be tested against a
  # gate that is mid-run rather than against a finished one.
  cat > "$repo/scripts/check-l10n-coverage.py" <<'PY'
#!/usr/bin/env python3
import os
import sys
import time

delay = int(os.environ.get("FAKE_STATIC_SLEEP") or 0)
if delay:
    time.sleep(delay)
sys.exit(0)
PY
  cat > "$repo/scripts/tests/test_fixture_ok.py" <<'PY'
import unittest


class FixtureSanityTests(unittest.TestCase):
    def test_ok(self):
        self.assertTrue(True)


if __name__ == "__main__":
    unittest.main()
PY
  cat > "$repo/scripts/ci-build-for-testing.sh" <<'SH'
#!/usr/bin/env bash
# Fixture stand-in for CI v2's build job: produce a .xctestrun where the gate
# expects one and record the build metadata the gate moves into its run dir.
set -u
# FAKE_BUILD_FAIL models a build that fails before producing a .xctestrun:
# the gate must still finish and write its three artifacts, reporting FAIL.
if [ -n "${FAKE_BUILD_FAIL:-}" ]; then
  mkdir -p ci-lane/build
  echo "fixture build-for-testing failed (stub)" > ci-lane/build/build.log
  exit 1
fi
mkdir -p "$DERIVED_DATA_PATH/Build/Products"
: > "$DERIVED_DATA_PATH/Build/Products/Conduit_stub.xctestrun"
mkdir -p ci-lane/build
echo "fixture build-for-testing ok" > ci-lane/build/build.log
printf '{"schema_version": 1, "status": "ok", "duration_s": 1, "xctestrun": "%s"}\n' \
  "$DERIVED_DATA_PATH/Build/Products/Conduit_stub.xctestrun" \
  > ci-lane/build/build-result.json
exit 0
SH
  ( cd "$repo" && git init -q . && git add -A \
      && git -c user.email=t@example.com -c user.name=t commit -q -m fixture )
}

# --- gate invocation --------------------------------------------------------
GATE="$WORK/repo/scripts/local-ci-gate.sh"
RUN_LOG=""

run_gate() { # extra args...
  local n=0
  for arg in "$@"; do
    n=$((n + 1))
    case "$arg" in
      --run-dir-*) [ "$n" -eq 1 ] && run_dir_hint="${arg#--run-dir-}" ;;
    esac
  done
  RUN_LOG="$WORK/gate-$RANDOM.log"
  # XCODEBUILD_POLL_INTERVAL_S keeps the watchdog polling cheap: the stub
  # xcodebuild exits instantly, and CI's own suite shrinks the cadence for
  # the same reason.
  PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 CONDUIT_PERF_TRACE=1 \
    bash "$GATE" --allow-another-run "$@" >"$RUN_LOG" 2>&1
}

new_run_dir() { printf '%s\n' "$WORK/run-$RANDOM-$RANDOM"; }

assert_three_artifacts() { # $1 = run dir, $2 = label
  assert_eq "$2: meta.json was written"     "$([ -f "$1/meta.json" ] && echo yes || echo no)" "yes"
  assert_eq "$2: gate-result.json was written"     "$([ -f "$1/gate-result.json" ] && echo yes || echo no)" "yes"
  assert_eq "$2: summary.md was written"     "$([ -f "$1/summary.md" ] && echo yes || echo no)" "yes"
}


echo "=== local-ci-gate integration suite ==="
write_stubs
make_fixture "$WORK/repo"

# The timing extractor shells out to `xcrun xcresulttool` with an argv list, so
# it needs an executable `xcrun` on PATH - which is why this probe runs AFTER
# the stubs exist (an earlier probe placed before write_stubs reported
# "unsupported" everywhere and silently skipped the assertions on Linux CI).
# On Windows (MSYS/Cygwin) an extension-less script is not executable from
# Python at all, so the extraction - and with it every count, classification
# and verdict the gate derives from the result bundle - cannot be exercised
# there: those assertions are SKIPPED loudly rather than quietly passed, while
# the structural ones (refs, exit codes, the caller's tree, the lock, cleanup)
# still run everywhere.
EXTRACTION_SUPPORTED=1
if ! python3 - "$STUBS" <<'PY'
import os, subprocess, sys
os.environ["PATH"] = sys.argv[1] + os.pathsep + os.environ.get("PATH", "")
try:
    proc = subprocess.run(["xcrun", "xcresulttool"], capture_output=True,
                          timeout=60)
except (OSError, ValueError):
    sys.exit(1)
sys.exit(0 if proc.returncode == 0 else 1)
PY
then
  EXTRACTION_SUPPORTED=0
fi
echo "result-bundle extraction exercised here: $([ "$EXTRACTION_SUPPORTED" -eq 1 ] && echo yes || echo no)"

FIXTURE_HEAD="$(git -C "$WORK/repo" rev-parse HEAD)"
export FAKE_CANNED="$WORK/canned.json"

# ---------------------------------------------------------------------------
echo ""
echo "--- case: clean run ---"
RUN1="$(new_run_dir)"
CLEAN_EXIT=0
run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN1" \
    --repeat-classes AlphaTests --repeat-iterations 2 || CLEAN_EXIT=$?
if needs_extraction; then
  if [ "$CLEAN_EXIT" -eq 0 ]; then
    ok "clean run exits 0"
  else
    bad "clean run exited $CLEAN_EXIT (see $RUN_LOG)"
    tail -n 30 "$RUN_LOG"
  fi
elif [ "$CLEAN_EXIT" -ne 0 ]; then
  # Nothing can be certified without a readable result bundle, so on this host
  # the correct behavior is to refuse to pass rather than report an empty
  # success - which is itself worth pinning.
  ok "a run whose result bundle cannot be read does not pass"
else
  bad "the gate passed a run whose result bundle could not be read"
fi
GATE_JSON="$RUN1/gate-result.json"
if needs_extraction; then
assert_eq "verdict is PASS" "$(json_get "$GATE_JSON" 'doc["verdict"]')" "PASS"
assert_eq "tested SHA is the tested commit" \
  "$(json_get "$GATE_JSON" 'doc["tested_sha"]')" "$FIXTURE_HEAD"
assert_eq "unit executions counted" \
  "$(json_get "$GATE_JSON" 'doc["unit"]["executions"]')" "15"
assert_eq "unit classes complete" \
  "$(json_get "$GATE_JSON" 'doc["unit"]["classes_observed"]')" "15"
assert_eq "no continuation was needed" \
  "$(json_get "$GATE_JSON" '"continuation" in doc["unit"]')" "False"
assert_eq "UI executions counted" \
  "$(json_get "$GATE_JSON" 'doc["ui"]["executions"]')" "1"
assert_eq "repeat policy executed every iteration" \
  "$(json_get "$GATE_JSON" 'len(doc["focused_repeats"]["classes"][0]["iterations"])')" "2"
assert_eq "repeat executions counted" \
  "$(json_get "$GATE_JSON" 'doc["focused_repeats"]["executions"]')" "2"
assert_eq "no infrastructure events" \
  "$(json_get "$GATE_JSON" 'doc["infrastructure"]["failures"]')" "0"
assert_eq "run is not partial" "$(json_get "$GATE_JSON" 'doc["partial"]')" "False"
else
  skip "clean-run verdict, execution counts and repeat evidence"
fi
assert_eq "the plan's three batches all ran" \
  "$(json_get "$GATE_JSON" 'doc["unit"]["batch_count"]')" "3"
assert_eq "xcode version recorded" \
  "$(json_get "$GATE_JSON" 'doc["xcode_version"].strip()')" "Xcode 27.0 Build version 27A0stub"
assert_eq "simulator runtime recorded" \
  "$(json_get "$GATE_JSON" 'doc["simulator"]["runtime"]')" "iOS 26.0"
assert_eq "the gate ran on its OWN simulator device, not the default" \
  "$(json_get "$GATE_JSON" 'doc["simulator"]["name"]')" "Conduit CI Gate"
assert_eq "the gate tooling's own commit is recorded"   "$(json_get "$GATE_JSON" 'doc["tooling_sha"]')"   "$(git -C "$WORK/repo" rev-parse HEAD)"
assert_eq "static checks ran" \
  "$(json_get "$GATE_JSON" 'len(doc["static_checks"])')" "3"
assert_contains "human summary names the tested commit" \
  "$(cat "$RUN1/summary.md")" "$FIXTURE_HEAD"
assert_eq "build metadata moved into the run dir" \
  "$([ -f "$RUN1/build/build.log" ] && echo yes || echo no)" "yes"
if [ -d "$WORK/gate/worktrees" ] && [ -n "$(ls -A "$WORK/gate/worktrees" 2>/dev/null)" ]; then
  bad "throwaway worktree was left behind"
else
  ok "throwaway worktree removed"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- case: the caller's tree, index and stashes are untouched ---"
# Model a developer mid-work: an uncommitted change, an untracked file, and a
# stash. The gate must test the COMMIT and leave all three alone.
( cd "$WORK/repo" && printf 'wip\n' >> Conduit/App.swift \
    && git -c user.email=t@example.com -c user.name=t stash push -q -m gate-wip )
( cd "$WORK/repo" && printf 'untracked\n' > uncommitted.txt \
    && printf 'dirty\n' >> Conduit/App.swift )
STATUS_BEFORE="$(git -C "$WORK/repo" status --porcelain)"
STASHES_BEFORE="$(git -C "$WORK/repo" stash list)"
STASH_REF_BEFORE="$(git -C "$WORK/repo" rev-parse refs/stash)"
HEAD_BEFORE="$(git -C "$WORK/repo" rev-parse HEAD)"
HEAD_REF_BEFORE="$(git -C "$WORK/repo" symbolic-ref HEAD)"
RUN2="$(new_run_dir)"
run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN2" \
    --repeat-classes AlphaTests --repeat-iterations 1 >/dev/null 2>&1
assert_eq "working tree unchanged" "$(git -C "$WORK/repo" status --porcelain)" "$STATUS_BEFORE"
assert_eq "stash list unchanged" "$(git -C "$WORK/repo" stash list)" "$STASHES_BEFORE"
assert_eq "stash commit untouched" "$(git -C "$WORK/repo" rev-parse refs/stash)" "$STASH_REF_BEFORE"
assert_eq "HEAD unchanged" "$(git -C "$WORK/repo" rev-parse HEAD)" "$HEAD_BEFORE"
assert_eq "HEAD ref unchanged" "$(git -C "$WORK/repo" symbolic-ref HEAD)" "$HEAD_REF_BEFORE"
assert_contains "the stash created before the run is still listed" "$STASHES_BEFORE" "gate-wip"
assert_eq "the dirty working tree was not what got tested" \
  "$(json_get "$RUN2/gate-result.json" 'doc["tested_sha"]')" "$HEAD_BEFORE"

# ---------------------------------------------------------------------------
echo ""
echo "--- case: a genuine assertion failure stops the lane, and the lane is continued ---"
export FAKE_UNIT_B1_A1=fail
RUN3="$(new_run_dir)"
if run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN3" \
    --repeat-classes "" >/dev/null 2>&1; then
  bad "a genuine assertion failure did not fail the gate"
else
  ok "a genuine assertion failure fails the gate"
fi
GATE3="$RUN3/gate-result.json"
if needs_extraction; then
assert_eq "verdict is FAIL" "$(json_get "$GATE3" 'doc["verdict"]')" "FAIL"
assert_eq "reported as an assertion failure" \
  "$(json_get "$GATE3" 'doc["unit"]["failures"] > 0')" "True"
assert_eq "not reported as infrastructure" \
  "$(json_get "$GATE3" 'doc["unit"]["synthetic_failures"]')" "0"
assert_eq "no infrastructure events" \
  "$(json_get "$GATE3" 'doc["infrastructure"]["failures"]')" "0"
assert_contains "the failure names the assertion" \
  "$(cat "$RUN3/summary.md")" "genuine XCTest assertion failures"
assert_contains "the failing test is identified" \
  "$(cat "$RUN3/gate-result.json")" "testSomething"
# Batches 2 and 3 never ran; the gate runs them as a continuation so one
# failing batch cannot hide the rest of the suite.
assert_eq "the never-reached batches were continued" \
  "$(json_get "$GATE3" 'len(doc["unit"]["passes"]) > 1')" "True"
assert_eq "the continuation ran every class the lane never reached" \
  "$(json_get "$GATE3" 'doc["unit"]["passes"][1]["executions"]')" "8"
assert_eq "every planned class still has a result" \
  "$(json_get "$GATE3" 'doc["unit"]["classes_missing"]')" "[]"
else
  skip "assertion-failure classification and the continuation pass"
fi
unset FAKE_UNIT_B1_A1

# ---------------------------------------------------------------------------
echo ""
echo "--- case: the test runner never launched the app (wedge -> one recovery round) ---"
# XCTest reports this under its synthetic "System Failures" class; the gate
# must call it infrastructure, not an assertion (this is exactly what the
# gate's first real runs on main produced, and it was mislabeled then). With
# the bounded recovery round, the class it leaves incomplete is retried once
# after an erase of the gate simulator - and that is the one case a run may
# still PASS: the retry is recorded, never hidden.
export FAKE_UNIT_B2_A1=crash
RUN4="$(new_run_dir)"
CLEAN4_EXIT=0
run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN4" \
    --repeat-classes "" >/dev/null 2>&1 || CLEAN4_EXIT=$?
if needs_extraction; then
  if [ "$CLEAN4_EXIT" -eq 0 ]; then
    ok "a wedged run recovered by the bounded round passes the gate"
  else
    bad "the wedged run was not recovered (see $RUN4/summary.md)"
    tail -n 20 "$RUN4/summary.md" 2>/dev/null
  fi
GATE4="$RUN4/gate-result.json"
assert_eq "no assertion failure claimed" \
  "$(json_get "$GATE4" 'doc["unit"]["failures"]')" "0"
assert_eq "the synthetic failure is counted separately" \
  "$(json_get "$GATE4" 'doc["unit"]["synthetic_failures"] > 0')" "True"
assert_eq "the recovery round was used exactly once" \
  "$(json_get "$GATE4" 'doc["infrastructure"]["retries"]')" "1"
assert_eq "the healed wedge is recorded as recovered" \
  "$(json_get "$GATE4" 'doc["infrastructure"]["recovered"] > 0')" "True"
assert_eq "nothing stayed persistent" \
  "$(json_get "$GATE4" 'doc["infrastructure"]["persistent"]')" "0"
assert_eq "every planned class still has a result" \
  "$(json_get "$GATE4" 'doc["unit"]["classes_missing"]')" "[]"
assert_contains "the recovered launch failure is visible in the summary" \
  "$(cat "$RUN4/summary.md")" "recovery"
else
  skip "test-runner-crash classification and the recovery round"
fi
unset FAKE_UNIT_B2_A1

# ---------------------------------------------------------------------------
echo ""
echo "--- case: refusals that must not run anything ---"
RUN5="$(new_run_dir)"
if run_gate --ref definitely-not-a-ref --gate-root "$WORK/gate" --run-dir "$RUN5" \
    >/dev/null 2>&1; then
  bad "an unresolvable ref was accepted"
else
  ok "an unresolvable ref is refused"
fi
assert_eq "no result document for a refused run" \
  "$([ -f "$RUN5/gate-result.json" ] && echo yes || echo no)" "no"

if run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN3" \
    >/dev/null 2>&1; then
  bad "a non-empty --run-dir was reused"
else
  ok "a non-empty --run-dir is refused"
fi

# A run directory inside the repository would put gate output in the very
# working tree the gate promises never to touch.
if run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$WORK/repo/ci-local" \
    >/dev/null 2>&1; then
  bad "--run-dir inside the repository was accepted"
else
  ok "--run-dir inside the repository is refused"
fi
assert_eq "nothing was written into the repository by that refusal" \
  "$([ -e "$WORK/repo/ci-local" ] && echo yes || echo no)" "no"

# Non-numeric flags fail as usage errors rather than mid-run arithmetic.
if run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$(new_run_dir)" \
    --repeat-iterations abc >/dev/null 2>&1; then
  bad "a non-numeric --repeat-iterations was accepted"
else
  ok "a non-numeric --repeat-iterations is refused"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- case: a genuine assertion never enters the recovery round ---"
export FAKE_UNIT_B1_A1=fail
RUN7="$(new_run_dir)"
if run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN7" \
    --repeat-classes "" >/dev/null 2>&1; then
  bad "a genuine assertion failure did not fail the gate"
else
  ok "a genuine assertion failure fails the gate"
fi
GATE7="$RUN7/gate-result.json"
assert_eq "no recovery pass was created" \
  "$(ls -d "$RUN7"/lanes/unit-recovery-* 2>/dev/null | wc -l | tr -d ' ')" "0"
if needs_extraction; then
assert_eq "no recovery retry was recorded" \
  "$(json_get "$GATE7" 'doc["infrastructure"]["retries"]')" "0"
assert_contains "the failure is named as an assertion" \
  "$(cat "$RUN7/summary.md")" "genuine XCTest assertion failures"
else
  skip "assertion failure blocks the recovery round"
fi
unset FAKE_UNIT_B1_A1

# ---------------------------------------------------------------------------
echo ""
echo "--- case: the launch-refusal wedge gets exactly one recovery round ---"
# Both the primary lane and its continuation pass are refused (the
# continuation renumbers its batches, so each is keyed independently), which
# is what leaves work incomplete - and that is the only shape the recovery
# round is allowed for.
export FAKE_UNIT_B1_A1=crash FAKE_CONTINUATION_MODE=crash
RUN8="$(new_run_dir)"
CLEAN8_EXIT=0
run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN8" \
    --repeat-classes "" >/dev/null 2>&1 || CLEAN8_EXIT=$?
if needs_extraction; then
  if [ "$CLEAN8_EXIT" -eq 0 ]; then
    ok "a recovered run passes the gate"
  else
    bad "the recovered run still failed (see $RUN8/summary.md)"
    tail -n 20 "$RUN8/summary.md" 2>/dev/null
  fi
else
  skip "the recovered run's verdict"
fi
GATE8="$RUN8/gate-result.json"
if needs_extraction; then
assert_eq "one recovery retry was recorded" \
  "$(json_get "$GATE8" 'doc["infrastructure"]["retries"]')" "1"
assert_eq "the recovered work is recorded as recovered" \
  "$(json_get "$GATE8" 'doc["infrastructure"]["recovered"] > 0')" "True"
assert_eq "nothing stayed persistent" \
  "$(json_get "$GATE8" 'doc["infrastructure"]["persistent"]')" "0"
assert_eq "no class is left without a result" \
  "$(json_get "$GATE8" 'doc["unit"]["classes_missing"]')" "[]"
else
  skip "wedge recovery outcome (verdict and classification)"
fi
assert_eq "the recovery pass exists (one retry set, one launch)" \
  "$(ls -d "$RUN8"/lanes/unit-recovery-* 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_eq "the gate ran on its own simulator device" \
  "$(json_get "$GATE8" 'doc["simulator"]["name"]')" "Conduit CI Gate"
assert_contains "the recovery is recorded, not hidden" \
  "$(cat "$RUN8/summary.md")" "recovery"

# ---------------------------------------------------------------------------
echo ""
echo "--- case: a recurrence after the recovery round fails as infrastructure ---"
export FAKE_UNIT_B1_A1=crash FAKE_CONTINUATION_MODE=crash FAKE_RECOVERY_MODE=crash
RUN9="$(new_run_dir)"
if run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN9" \
    --repeat-classes "" >/dev/null 2>&1; then
  bad "a recurring wedge did not fail the gate"
else
  ok "a recurring wedge fails the gate"
fi
GATE9="$RUN9/gate-result.json"
if needs_extraction; then
assert_eq "only one retry was attempted" \
  "$(json_get "$GATE9" 'doc["infrastructure"]["retries"]')" "1"
assert_eq "the recurrence is persistent infrastructure" \
  "$(json_get "$GATE9" 'doc["infrastructure"]["persistent"] > 0')" "True"
assert_contains "the report names the recurrence" \
  "$(cat "$RUN9/summary.md")" "launch-refusal class"
else
  skip "recurrence verdict and classification"
fi
unset FAKE_UNIT_B1_A1 FAKE_CONTINUATION_MODE FAKE_RECOVERY_MODE

# ---------------------------------------------------------------------------
echo ""
echo "--- case: an interrupt releases the lock and the worktree ---"
# Interrupt the gate mid-run (during the static phase, which the fixture can
# make hang) and require the same cleanup the end of a run performs.
export FAKE_STATIC_SLEEP=30
RUN10="$(new_run_dir)"
STATUS_BEFORE_INTERRUPT="$(git -C "$WORK/repo" status --porcelain)"
PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 \
  bash "$GATE" --allow-another-run --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN10" \
    --repeat-classes "" >"$WORK/interrupt.log" 2>&1 &
INTERRUPTED_PID=$!
sleep 3
kill -TERM "$INTERRUPTED_PID" 2>/dev/null
INTERRUPT_EXIT=0
wait "$INTERRUPTED_PID" || INTERRUPT_EXIT=$?
unset FAKE_STATIC_SLEEP
# SIGTERM is the signal sent, so the gate reports 143 (128 + SIGTERM); an
# INT would report 130.
assert_eq "the interrupted run exits 143 (SIGTERM)" "$INTERRUPT_EXIT" "143"
assert_eq "the lock was released" \
  "$([ -d "$WORK/gate/gate.lock" ] && echo yes || echo no)" "no"
assert_eq "no worktree was left behind" \
  "$(ls -A "$WORK/gate/worktrees" 2>/dev/null | wc -l | tr -d ' ')" "0"
assert_eq "the caller's repository is unchanged by the interrupted run" \
  "$(git -C "$WORK/repo" status --porcelain)" "$STATUS_BEFORE_INTERRUPT"

# ---------------------------------------------------------------------------
echo ""
echo "--- case: the gate simulator is created when it does not exist ---"
export FAKE_NO_GATE_DEVICE=1
RUN11="$(new_run_dir)"
CLEAN11_EXIT=0
run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN11" \
    --repeat-classes "" >/dev/null 2>&1 || CLEAN11_EXIT=$?
if needs_extraction; then
  if [ "$CLEAN11_EXIT" -eq 0 ]; then
    ok "a run without the gate device still runs (it creates it)"
  else
    bad "a missing gate simulator stopped the run (see $RUN11/summary.md)"
  fi
else
  skip "the missing-device run's verdict"
fi
assert_contains "the creation is visible in the log" "$(cat "$RUN_LOG")" \
  "gate simulator 'Conduit CI Gate' created"
assert_eq "the created device is recorded" \
  "$(json_get "$RUN11/gate-result.json" 'doc["simulator"]["udid"]')" \
  "6D08B063-B890-4D18-893B-D1E89E119919"
unset FAKE_NO_GATE_DEVICE

# ---------------------------------------------------------------------------
echo ""
# ---------------------------------------------------------------------------
echo ""
echo "--- case: a failed build still writes all three artifacts ---"
# Regression for the Bash 3.2 empty-array fatal: `set -u` with an empty array
# expansion used to abort /bin/bash 3.2 during argument expansion, BEFORE the
# gate could write its result. Whatever fails, meta.json + gate-result.json +
# summary.md must exist and the verdict must be FAIL.
export FAKE_BUILD_FAIL=1
RUN15="$(new_run_dir)"
BUILD_EXIT=0
run_gate --ref HEAD --gate-root "$WORK/gate-artifacts" --run-dir "$RUN15"     --repeat-classes "" >/dev/null 2>&1 || BUILD_EXIT=$?
if [ "$BUILD_EXIT" -eq 0 ]; then
  bad "a failed build passed the gate"
else
  ok "a failed build fails the gate (exit $BUILD_EXIT)"
fi
assert_three_artifacts "$RUN15" "a failed build"
assert_eq "the failed build's verdict is FAIL"   "$(json_get "$RUN15/gate-result.json" 'doc["verdict"]')" "FAIL"
unset FAKE_BUILD_FAIL

echo ""
echo "--- case: --no-simulator-prep still writes all three artifacts ---"
# The SIM_PREP_CHECKS array is EMPTY on this path, which is exactly the
# expansion that used to be fatal under Bash 3.2. Combined with a genuine
# assertion failure so the verdict is FAIL on every platform (without one, a
# host that can read result bundles would legitimately pass).
export FAKE_UNIT_B1_A1=fail
RUN16="$(new_run_dir)"
NOPREP_EXIT=0
run_gate --ref HEAD --gate-root "$WORK/gate-artifacts" --run-dir "$RUN16"     --repeat-classes "" --no-simulator-prep >/dev/null 2>&1 || NOPREP_EXIT=$?
if [ "$NOPREP_EXIT" -eq 0 ]; then
  bad "the run with --no-simulator-prep passed despite a genuine failure"
else
  ok "the run with --no-simulator-prep fails (exit $NOPREP_EXIT)"
fi
assert_three_artifacts "$RUN16" "--no-simulator-prep"
assert_eq "its verdict is FAIL"   "$(json_get "$RUN16/gate-result.json" 'doc["verdict"]')" "FAIL"
assert_eq "the run records that preparation was off" \
  "$(json_get "$RUN16/gate-result.json" 'doc["run_flags"]["simulator_prep"] is False')" "True"
unset FAKE_UNIT_B1_A1

echo ""
echo ""
echo ""
echo "--- case: a UI-only recovery round is recorded end to end ---"
# The hole the reviewer found: the shell writes a UI retry to lanes/ui-recovery
# (no trailing suffix), which the phase accounting's globs could not see - so a
# UI-only recovery recorded retries: 0 while the verdict said PASS. This case
# drives the REAL shell lines: clean unit lane, wedged UI shard, healed UI
# recovery, and then asks the result document whether the round ran.
export FAKE_UI_BATCH=crash
RUN17="$(new_run_dir)"
UIREC_EXIT=0
run_gate --ref HEAD --gate-root "$WORK/gate-artifacts" --run-dir "$RUN17"     --repeat-classes "" >/dev/null 2>&1 || UIREC_EXIT=$?
if needs_extraction; then
  if [ "$UIREC_EXIT" -eq 0 ]; then
    ok "a UI-only recovery round lets the run pass"
  else
    bad "the UI-only recovery run failed (see $RUN17/summary.md)"
    tail -n 20 "$RUN17/summary.md" 2>/dev/null
  fi
  GATE17="$RUN17/gate-result.json"
  assert_eq "the round is recorded as having run"     "$(json_get "$GATE17" 'doc["infrastructure"]["retries"]')" "1"
  assert_eq "the UI classes recovered count as executed"     "$(json_get "$GATE17" 'len(doc["ui"]["classes_missing"])')" "0"
  assert_eq "both UI passes are in the record"     "$(json_get "$GATE17" 'len(doc["ui"]["passes"])')" "2"
  assert_eq "and the unit suite needed no recovery"     "$(json_get "$GATE17" 'len(doc["unit"]["passes"])')" "1"
  assert_contains "the healed round is a caveat, not silence"     "$(cat "$RUN17/summary.md")" "recovery"
else
  skip "UI-only recovery round (needs a readable result bundle)"
fi
unset FAKE_UI_BATCH

echo "--- case: one authoritative full-gate invocation per requested SHA ---"
# The gate is single-shot: after a verdict, another COMPLETE run for the same
# SHA must be an explicit caller request. Nothing may restart it into "until
# green" - and the tooling refuses rather than trusting whatever drives it.
# (exit 2 is the policy refusal; 0/1 is a run that actually started, so these
# assertions are structural and hold on every platform.)
RUN12="$(new_run_dir)"
FIRST_EXIT=0
PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 CONDUIT_PERF_TRACE=1 bash "$GATE" --allow-another-run --ref HEAD --gate-root "$WORK/gate-policy" --run-dir "$RUN12" --repeat-classes "" >"$WORK/policy-first.log" 2>&1 || FIRST_EXIT=$?
if [ "$FIRST_EXIT" -eq 2 ]; then
  bad "the first full gate run for this SHA was refused"
else
  ok "the first full gate run for this SHA is allowed to start"
fi
RUN13="$(new_run_dir)"
SECOND_EXIT=0
PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 CONDUIT_PERF_TRACE=1 bash "$GATE" --ref HEAD --gate-root "$WORK/gate-policy" --run-dir "$RUN13" --repeat-classes "" >"$WORK/policy-second.log" 2>&1 || SECOND_EXIT=$?
assert_eq "a second full gate run is refused (exit 2)" "$SECOND_EXIT" "2"
assert_contains "the refusal states the policy" "$(cat "$WORK/policy-second.log")"   "one authoritative full-gate invocation per requested SHA"
assert_contains "the refusal names the explicit escape" "$(cat "$WORK/policy-second.log")"   "--allow-another-run"
assert_eq "the refused run started no work at all"   "$([ -d "$RUN13/lanes" ] && echo yes || echo no)" "no"
RUN14="$(new_run_dir)"
EXPLICIT_EXIT=0
PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 CONDUIT_PERF_TRACE=1 bash "$GATE" --allow-another-run --ref HEAD --gate-root "$WORK/gate-policy" --run-dir "$RUN14" --repeat-classes "" >"$WORK/policy-third.log" 2>&1 || EXPLICIT_EXIT=$?
if [ "$EXPLICIT_EXIT" -eq 2 ]; then
  bad "--allow-another-run did not allow the explicitly requested run"
else
  ok "an explicitly requested second run is allowed to start"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- case: only one gate at a time ---"
mkdir -p "$WORK/gate/gate.lock"
echo "$$" > "$WORK/gate/gate.lock/pid"
RUN6="$(new_run_dir)"
if run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN6" >/dev/null 2>&1; then
  bad "a second concurrent gate was allowed to start"
else
  ok "a second concurrent gate is refused"
fi
assert_contains "the refusal explains why" "$(cat "$RUN_LOG")" "another gate is running"
rm -rf "$WORK/gate/gate.lock"

echo ""
echo "=== $pass_count passed, $fail_count failed, $skip_count skipped ==="
[ "$fail_count" -eq 0 ]
