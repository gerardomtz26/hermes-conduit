#!/usr/bin/env bash
#
# Conduit LOCAL exhaustive CI gate.
#
# This is the authoritative exhaustive test gate for a trusted commit: it is
# run on our own Mac over SSH (never inside GitHub's runner system), and it
# always tests an EXACT commit in a throwaway detached worktree - never the
# invoking checkout's working tree. See docs/CI.md ("Local exhaustive gate")
# for the contract and for the policy rules this script implements.
#
# What it does, in order:
#   1. resolve --ref to a full commit SHA (the ONLY revision it will test);
#   2. create a detached worktree for that SHA outside the developer's tree;
#   3. xcodegen generate (the generated .xcodeproj is never committed);
#   4. cheap static checks (planner inventory validation, CI-tooling
#      regression suites, localization coverage);
#   5. build-for-testing ONCE into a gate-specific DerivedData directory;
#   6. the COMPLETE ConduitTests unit suite (planner-batched, sequential);
#   7. the COMPLETE ConduitUITests suite (one batched UI shard);
#   8. the explicit repeat policy for timing/performance-sensitive classes:
#      K unconditional repetitions, every one of which must pass;
#   9. a machine-readable gate-result.json + summary.md, and exit 0 only if
#      the whole gate passed.
#
# Failure semantics (docs/CI.md): a genuine XCTest assertion failure fails the
# gate; an infrastructure/simulator/AX failure ALSO fails the gate but is
# reported as infrastructure, never as an assertion failure. Genuine
# assertions are never re-run until they agree: the lane runner is invoked
# with --iterations 1 (no Xcode-native flake retry), and the summarizer fails
# the gate outright if it finds an item that failed and then passed.
#
# The orchestrator and the result assembler come from the checkout this
# script was invoked from; the planner, lane runner and timing extractor come
# from the TESTED commit's tree, so the policy under test is the policy of the
# revision being certified.
#
# Bash 3.2 compatible (/bin/bash on macOS).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# jq is not required: every JSON-aware step goes through local-gate.py.
# Homebrew tools (xcodegen) are not on the minimal non-interactive SSH PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

HELPER="$SCRIPT_DIR/local-gate.py"
# Explicit default repeat classes: the settled-Markdown/dormancy and
# transcript-performance families that have repeatedly failed on
# scheduling-dependent behavior (the family that also blocked the 0.1.11
# build 147 release). Repeated unconditionally, so a flake in the family is
# evidence rather than a coin flip.
DEFAULT_REPEAT_CLASSES="SettledMessageIsolationTests,TranscriptPerfLedgerContractTests,TranscriptPerformanceFixtureTests,MarkdownRichContentHostedTests"

usage() {
  cat <<'USAGE'
Usage: scripts/local-ci-gate.sh --ref <git-ref-or-sha> [options]

Required:
  --ref REF                  Exact git ref or commit SHA to test. The gate
                             reports the full SHA it actually tested; a result
                             is only valid for that SHA.

Options:
  --fetch                    Fetch --remote before resolving --ref.
  --remote NAME              Remote for --fetch (default: origin).
  --gate-root DIR            Root for runs + worktrees.
                             Default: <parent of the repository>/conduit-local-gate
  --run-dir DIR              This run's artifact directory.
                             Default: <gate-root>/runs/<sha12>-<UTC stamp>
  --worktree-root DIR        Parent directory for the throwaway worktree.
                             Default: <gate-root>/worktrees
  --simulator NAME           Simulator device name (default: $SIMULATOR_NAME
                             or "iPhone 17 Pro").
  --repeat-classes CSV       Classes for the repeat policy.
                             Default: settled-Markdown/dormancy + transcript
                             performance families.
  --repeat-iterations N      Unconditional repetitions per repeat class (default 3).
  --repeat-timeout-cap S     Ceiling for one repeat iteration's watchdog
                             (default 900); the planner's batch budget still
                             applies, capped by this.
  --allow-recovered-infrastructure
                             Downgrade "an infrastructure failure was
                             recovered by the bounded retry" from FAIL to a
                             recorded warning. Off by default: the run is not
                             trustworthy evidence either way. Must be recorded
                             wherever the result is cited.
  --keep-worktree            Keep the throwaway worktree after the run.
  --skip-static              Skip the cheap static checks (developer loop
                             only; the result is marked partial).
  --no-lock                  Skip the single-gate-per-Mac lock (UNSAFE: two
                             concurrent xcodebuild chains corrupt each other's
                             Simulator).
  -h, --help                 This text.

Exit status: 0 = gate PASS, 1 = gate FAIL, 2 = usage/preflight error.
USAGE
}

REF=""; REMOTE="origin"; DO_FETCH=0
GATE_ROOT=""; RUN_DIR=""; WORKTREE_ROOT=""
SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17 Pro}"
REPEAT_CLASSES="$DEFAULT_REPEAT_CLASSES"
REPEAT_ITERATIONS=3
REPEAT_TIMEOUT_CAP=900
ALLOW_RECOVERED_INFRA=0
KEEP_WORKTREE=0
SKIP_STATIC=0
USE_LOCK=1

while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="$2"; shift 2 ;;
    --fetch) DO_FETCH=1; shift ;;
    --remote) REMOTE="$2"; shift 2 ;;
    --gate-root) GATE_ROOT="$2"; shift 2 ;;
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --worktree-root) WORKTREE_ROOT="$2"; shift 2 ;;
    --simulator) SIMULATOR_NAME="$2"; shift 2 ;;
    --repeat-classes) REPEAT_CLASSES="$2"; shift 2 ;;
    --repeat-iterations) REPEAT_ITERATIONS="$2"; shift 2 ;;
    --repeat-timeout-cap) REPEAT_TIMEOUT_CAP="$2"; shift 2 ;;
    --allow-recovered-infrastructure) ALLOW_RECOVERED_INFRA=1; shift ;;
    --keep-worktree) KEEP_WORKTREE=1; shift ;;
    --skip-static) SKIP_STATIC=1; shift ;;
    --no-lock) USE_LOCK=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "local-ci-gate: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$REF" ]; then
  echo "local-ci-gate: --ref is required (the exact ref or SHA to certify)" >&2
  usage >&2
  exit 2
fi

# --- preflight ---------------------------------------------------------------
for tool in git python3 xcodebuild xcodegen; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "local-ci-gate: required tool not found on PATH: $tool" >&2
    exit 2
  fi
done

if [ ! -f "$HELPER" ]; then
  echo "local-ci-gate: helper missing: $HELPER" >&2
  exit 2
fi

REPO_ROOT="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel 2>/dev/null)" || true
if [ -z "$REPO_ROOT" ]; then
  echo "local-ci-gate: $SCRIPT_DIR is not inside a git working tree" >&2
  exit 2
fi

# Everything the gate writes lives OUTSIDE the repository: the invoking
# checkout is never the run's workspace and never accumulates gate output.
if [ -z "$GATE_ROOT" ]; then
  GATE_ROOT="$(cd "$REPO_ROOT/.." && pwd)/conduit-local-gate"
fi
if [ -z "$WORKTREE_ROOT" ]; then
  WORKTREE_ROOT="$GATE_ROOT/worktrees"
fi

# --- single-gate-per-Mac lock ------------------------------------------------
# Two concurrent xcodebuild/test chains on one Mac corrupt each other's
# Simulator state; a gate result from such a run would be meaningless.
LOCK_DIR="$GATE_ROOT/gate.lock"
LOCK_HELD=0
if [ "$USE_LOCK" -eq 1 ]; then
  mkdir -p "$GATE_ROOT"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      echo "local-ci-gate: another gate is running (pid $holder): refusing to run two xcodebuild chains on one Mac" >&2
      echo "local-ci-gate: if that process is gone, remove $LOCK_DIR" >&2
      exit 2
    fi
    echo "local-ci-gate: taking over a stale gate lock ($(cat "$LOCK_DIR/info" 2>/dev/null || echo 'no info'))" >&2
    rm -rf "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "local-ci-gate: could not acquire the gate lock at $LOCK_DIR" >&2
      exit 2
    fi
  fi
  LOCK_HELD=1
  echo "$$" > "$LOCK_DIR/pid"
  printf 'ref=%s\nstarted=%s\n' "$REF" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK_DIR/info"
fi

cleanup() {
  local status=$?
  if [ "$LOCK_HELD" -eq 1 ]; then
    rm -rf "$LOCK_DIR"
  fi
  return "$status"
}
trap cleanup EXIT

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- resolve the tested revision --------------------------------------------
if [ "$DO_FETCH" -eq 1 ]; then
  echo "== fetching $REMOTE =="
  if ! git -C "$REPO_ROOT" fetch "$REMOTE" --tags --prune; then
    echo "local-ci-gate: fetch from $REMOTE failed" >&2
    exit 2
  fi
fi

SHA="$(git -C "$REPO_ROOT" rev-parse --verify "${REF}^{commit}" 2>/dev/null)" || true
if [ -z "$SHA" ]; then
  echo "local-ci-gate: cannot resolve '$REF' to a commit in $REPO_ROOT" >&2
  exit 2
fi
case "$SHA" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
    ;;
  *) echo "local-ci-gate: resolved revision is not a commit id: $SHA" >&2; exit 2 ;;
esac
SHA12="${SHA%${SHA#????????????}}"

if [ -z "$RUN_DIR" ]; then
  RUN_DIR="$GATE_ROOT/runs/${SHA12}-$(date -u +%Y%m%dT%H%M%SZ)"
fi
WT="$WORKTREE_ROOT/$SHA12"
mkdir -p "$RUN_DIR" "$WORKTREE_ROOT"

GATE_STARTED_AT="$(now_iso)"
GATE_START_EPOCH=$(date +%s)

echo "== Conduit local gate =="
echo "repo root : $REPO_ROOT"
echo "tested ref: $REF -> $SHA"
echo "run dir   : $RUN_DIR"
echo "worktree  : $WT"
echo "simulator : $SIMULATOR_NAME"

# --- worktree ----------------------------------------------------------------
# Detached: the gate never checks out a branch and never touches the invoking
# checkout's index, HEAD or stash.
if ! git -C "$REPO_ROOT" worktree add --detach "$WT" "$SHA"; then
  echo "local-ci-gate: could not create a detached worktree at $WT" >&2
  exit 2
fi
WT_SHA="$(git -C "$WT" rev-parse HEAD)"
if [ "$WT_SHA" != "$SHA" ]; then
  echo "local-ci-gate: worktree HEAD ($WT_SHA) is not the requested commit ($SHA)" >&2
  git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true
  exit 2
fi
echo "worktree ready at $WT (detached at $SHA)"

WORKTREE_REMOVED=0
remove_worktree() {
  if [ "$KEEP_WORKTREE" -eq 1 ]; then
    echo "keeping the throwaway worktree at $WT (--keep-worktree)"
    return 0
  fi
  # Only ever the worktree this run created: the dirty state is the generated
  # .xcodeproj plus build output, which is exactly why --force is needed.
  if git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1; then
    echo "removed the throwaway worktree at $WT (all diagnostics live in $RUN_DIR)"
  else
    echo "local-ci-gate: could not remove the throwaway worktree at $WT" >&2
  fi
}

# The target tree's own tooling is what runs the tests: the planner, the lane
# runner and the timing extractor must be the ones from the tested commit.
LANE_RUNNER="$WT/scripts/ci-test-lane.sh"
PLANNER="$WT/scripts/plan-tests.py"
for script in "$LANE_RUNNER" "$PLANNER" "$WT/scripts/ci-build-for-testing.sh"; do
  if [ ! -f "$script" ]; then
    echo "local-ci-gate: $SHA does not carry the tested tree's CI tooling ($script)" >&2
    remove_worktree
    exit 2
  fi
done

# --- helpers -----------------------------------------------------------------
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g; s/ $//')"

write_meta() { # $1 = finished_at, $2 = wall_s
  python3 "$HELPER" meta \
    --out "$RUN_DIR/meta.json" \
    --ref "$REF" --sha "$SHA" \
    --xcode "$XCODE_VERSION" \
    --simulator "$SIMULATOR_NAME" \
    --runtime "${SIMULATOR_RUNTIME:-}" \
    --simulator-udid "${SIMULATOR_UDID:-}" \
    --started-at "$GATE_STARTED_AT" --finished-at "$1" --wall-s "$2" \
    --unit-classes "${GATE_UNIT_CLASS_COUNT:-0}" \
    --unit-batches "${GATE_UNIT_BATCH_COUNT:-0}" \
    --ui-classes "${GATE_UI_CLASS_COUNT:-0}" \
    --repeat-classes "$REPEAT_CLASSES" \
    --repeat-iterations "$REPEAT_ITERATIONS" \
    $([ "$ALLOW_RECOVERED_INFRA" -eq 1 ] && printf '%s' '--allow-recovered-infrastructure') \
    $([ "$SKIP_STATIC" -eq 1 ] && printf '%s' '--skip-static')
}

GATE_STATIC_STATUS="skipped"
GATE_BUILD_STATUS="not_run"
GATE_UNIT_STATUS="not_run"
GATE_UI_STATUS="not_run"
GATE_REPEAT_STATUS="not_run"

# --- phase: generate ---------------------------------------------------------
echo ""
echo "== xcodegen generate =="
GEN_LOG="$RUN_DIR/generate.log"
if ( cd "$WT" && xcodegen generate ) >"$GEN_LOG" 2>&1; then
  echo "xcodegen generate ok"
else
  echo "local-ci-gate: xcodegen generate failed; see $GEN_LOG" >&2
  tail -n 40 "$GEN_LOG" >&2 || true
  remove_worktree
  exit 2
fi

# --- the device the run will actually use (recorded in the result) ----------
DEVICES_JSON="$RUN_DIR/simctl-devices.json"
xcrun simctl list devices available -j >"$DEVICES_JSON" 2>/dev/null || true
python3 "$HELPER" simulator --devices "$DEVICES_JSON" \
  --name "$SIMULATOR_NAME" --out "$RUN_DIR/simulator.json" >/dev/null 2>&1 || true
SIMULATOR_RUNTIME="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("runtime", ""))
except Exception:
    print("")
' "$RUN_DIR/simulator.json" 2>/dev/null || true)"
SIMULATOR_UDID="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("udid", ""))
except Exception:
    print("")
' "$RUN_DIR/simulator.json" 2>/dev/null || true)"

# --- phase: static checks ----------------------------------------------------
if [ "$SKIP_STATIC" -eq 1 ]; then
  echo ""
  echo "== static checks SKIPPED (--skip-static) =="
  record_phase static skipped 0 0 "--skip-static"
else
  echo ""
  echo "== static checks (planner inventory, CI tooling, localization) =="
  STATIC_START=$(date +%s)
  STATIC_OK=1
  STATIC_CHECKS=()
  run_static_check() { # $1=name, rest=command
    local name="$1"; shift
    local log="$RUN_DIR/static/$name.log"
    mkdir -p "$RUN_DIR/static"
    local start elapsed status
    start=$(date +%s)
    if ( cd "$WT" && "$@" ) >"$log" 2>&1; then
      status="pass"
    else
      status="fail"
      STATIC_OK=0
      echo "  $name: FAIL (see $log)"
      tail -n 30 "$log" || true
    fi
    elapsed=$(( $(date +%s) - start ))
    [ "$status" = "pass" ] && echo "  $name: pass (${elapsed}s)"
    STATIC_CHECKS+=(--check "$name:$status:$elapsed")
  }
  run_static_check plan-validate python3 scripts/plan-tests.py validate --repo-root .
  run_static_check ci-tooling-regression python3 -m unittest discover -s scripts/tests -p 'test_*.py'
  run_static_check localization-coverage python3 scripts/check-l10n-coverage.py --repo-root .

  if [ "$STATIC_OK" -eq 1 ]; then GATE_STATIC_STATUS="pass"; else GATE_STATIC_STATUS="fail"; fi
  python3 "$HELPER" phase --out "$RUN_DIR/static/phase.json" \
    --phase static --status "$GATE_STATIC_STATUS" \
    --duration "$(( $(date +%s) - STATIC_START ))" \
    --exit-code "$([ "$STATIC_OK" -eq 1 ] && echo 0 || echo 1)" \
    --note "planner inventory + CI-tooling regression suites + localization coverage" \
    "${STATIC_CHECKS[@]}"
fi

# --- phase: build-for-testing (exactly once) ---------------------------------
echo ""
echo "== build-for-testing (once) =="
BUILD_START=$(date +%s)
BUILD_OK=1
( cd "$WT" && DERIVED_DATA_PATH="$RUN_DIR/derived-data" \
    SIMULATOR_NAME="$SIMULATOR_NAME" \
    bash scripts/ci-build-for-testing.sh ) || BUILD_OK=0
BUILD_ELAPSED=$(( $(date +%s) - BUILD_START ))
mkdir -p "$RUN_DIR/build"
# The build script writes ci-lane/build inside the (throwaway) worktree;
# move the diagnostics out so they survive the worktree's removal.
if [ -d "$WT/ci-lane/build" ]; then
  mv "$WT/ci-lane/build"/* "$RUN_DIR/build/" 2>/dev/null || true
fi
XCTESTRUN="$(ls -t "$RUN_DIR/derived-data"/Build/Products/*.xctestrun 2>/dev/null | head -n 1 || true)"
if [ "$BUILD_OK" -eq 1 ] && [ -n "$XCTESTRUN" ]; then
  GATE_BUILD_STATUS="pass"
  echo "build-for-testing ok in ${BUILD_ELAPSED}s"
  echo "xctestrun: $XCTESTRUN"
else
  GATE_BUILD_STATUS="fail"
  echo "local-ci-gate: build-for-testing FAILED (exit non-zero or no .xctestrun produced)"
  echo "full log: $RUN_DIR/build/build.log"
  tail -n 60 "$RUN_DIR/build/build.log" 2>/dev/null || true
  XCTESTRUN=""
fi
python3 "$HELPER" phase --out "$RUN_DIR/build/phase.json" \
  --phase build --status "$GATE_BUILD_STATUS" \
  --duration "$BUILD_ELAPSED" --exit-code "$([ "$GATE_BUILD_STATUS" = pass ] && echo 0 || echo 1)" \
  --note "$([ -n "$XCTESTRUN" ] && echo "build-for-testing products" || echo "no .xctestrun produced")" \
  --detail "xctestrun=$XCTESTRUN"

# --- phase: plan -------------------------------------------------------------
# One lane per kind: the gate is exhaustive, not sharded, so it forces the
# planner to emit the whole suite as a single unit lane (with its
# planner-owned sequential batches and per-batch watchdogs) and a single UI
# lane. --unit-max-batches-per-job is relaxed because that knob bounds HOSTED
# jobs; locally every batch runs in one process with no job ceiling, and the
# planner's per-batch watchdogs remain the enforcement.
LANES_ENV="$RUN_DIR/lanes.env"

run_lane() { # $1=kind $2=lane $3=target $4=classes $5=predicted $6=timeout
              # $7=result-dir, then extra flags after
  local kind="$1" lane="$2" target="$3" classes="$4" predicted="$5" timeout="$6"
  local result_dir="$7"; shift 7
  echo ""
  echo "== $kind lane $lane =="
  echo "classes: $(printf '%s' "$classes" | tr ',' '\n' | wc -l | tr -d ' ') | watchdog: ${timeout}s"
  CONDUIT_PERF_TRACE="${CONDUIT_PERF_TRACE:-1}" \
    bash "$LANE_RUNNER" --kind "$kind" --lane "$lane" --target "$target" \
      --classes "$classes" --predicted "$predicted" --timeout "$timeout" \
      --iterations 1 --xctestrun "$XCTESTRUN" --result-dir "$result_dir" "$@"
}

if [ "$GATE_BUILD_STATUS" != "pass" ]; then
  echo ""
  echo "== test lanes SKIPPED: the build did not produce test products =="
  GATE_UNIT_STATUS="skipped"
  GATE_UI_STATUS="skipped"
  GATE_REPEAT_STATUS="skipped"
else
  # shellcheck disable=SC1090
  . "$LANES_ENV"

  # --- phase: plan -------------------------------------------------------
  # The planner is the single owner of the batch layout and every watchdog
  # budget, so it must succeed before any lane starts.
  PLAN_OK=1
  mkdir -p "$RUN_DIR/plan"
  if ! python3 "$PLANNER" plan --repo-root "$WT" \
      --baseline scripts/test-timings.json \
      --min-lanes 1 --max-lanes 1 --unit-max-batches-per-job 1000 \
      --ui-min-lanes 1 --ui-max-lanes 1 \
      --out "$RUN_DIR/plan/plan.json" \
      --summary-out "$RUN_DIR/plan/plan-summary.md" \
      >"$RUN_DIR/plan/plan.log" 2>&1; then
    PLAN_OK=0
  fi
  if [ "$PLAN_OK" -ne 1 ] || [ ! -s "$RUN_DIR/plan/plan.json" ]; then
    echo "local-ci-gate: planning failed; see $RUN_DIR/plan/plan.log" >&2
    tail -n 40 "$RUN_DIR/plan/plan.log" >&2 || true
    GATE_UNIT_STATUS="fail"; GATE_UI_STATUS="fail"; GATE_REPEAT_STATUS="fail"
  else
    echo "plan: $RUN_DIR/plan/plan.json"
    if ! python3 "$HELPER" lanes --plan "$RUN_DIR/plan/plan.json" --out "$LANES_ENV"; then
      echo "local-ci-gate: lane projection failed" >&2
      GATE_UNIT_STATUS="fail"; GATE_UI_STATUS="fail"; GATE_REPEAT_STATUS="fail"
    else
      # shellcheck disable=SC1090
      . "$LANES_ENV"

      # --- complete unit suite -------------------------------------------
      if run_lane unit "$GATE_UNIT_LANE" "$GATE_UNIT_TARGET" "$GATE_UNIT_CLASSES" \
          "$GATE_UNIT_PREDICTED" "$GATE_UNIT_TIMEOUT" "$RUN_DIR/lanes/unit" \
          --batches-json "$GATE_UNIT_BATCHES_JSON"; then
        GATE_UNIT_STATUS="pass"
      else
        GATE_UNIT_STATUS="fail"
      fi

      # --- complete UI suite ---------------------------------------------
      if [ "${GATE_UI_PRESENT:-0}" -eq 1 ]; then
        if run_lane ui "$GATE_UI_LANE" "$GATE_UI_TARGET" "$GATE_UI_CLASSES" \
            "$GATE_UI_PREDICTED" "$GATE_UI_TIMEOUT" "$RUN_DIR/lanes/ui" \
            --class-timeouts "$GATE_UI_CLASS_TIMEOUTS"; then
          GATE_UI_STATUS="pass"
        else
          GATE_UI_STATUS="fail"
        fi
      else
        GATE_UI_STATUS="skipped"
      fi

      # --- explicit repeat policy ----------------------------------------
      GATE_REPEAT_STATUS="pass"
      if [ -z "$REPEAT_CLASSES" ] || [ "$REPEAT_ITERATIONS" -le 0 ]; then
        GATE_REPEAT_STATUS="skipped"
        echo ""
        echo "== repeat policy disabled =="
      else
        REPEAT_SPEC="$RUN_DIR/repeats.json"
        if ! python3 "$HELPER" repeat-spec --plan "$RUN_DIR/plan/plan.json" \
            --classes "$REPEAT_CLASSES" --iterations "$REPEAT_ITERATIONS" \
            --timeout-cap "$REPEAT_TIMEOUT_CAP" --out "$REPEAT_SPEC"; then
          echo "local-ci-gate: repeat policy could not be projected" >&2
          GATE_REPEAT_STATUS="fail"
        else
          echo ""
          echo "== repeat policy: $REPEAT_ITERATIONS unconditional iterations per class =="
          while IFS=$'\t' read -r rcls rbatches rpredicted rtimeout; do
            [ -z "$rcls" ] && continue
            rtimeout="${rtimeout%$'\r'}"
            rpredicted="${rpredicted%$'\r'}"
            rbatches="${rbatches%$'\r'}"
            iteration=1
            while [ "$iteration" -le "$REPEAT_ITERATIONS" ]; do
              if run_lane unit "repeat-$rcls-$iteration" "$GATE_UNIT_TARGET" \
                  "$rcls" "$rpredicted" "$rtimeout" \
                  "$RUN_DIR/repeats/$rcls/iter-$iteration" \
                  --batches-json "$rbatches"; then
                echo "  $rcls iteration $iteration: pass"
              else
                echo "  $rcls iteration $iteration: FAIL"
                GATE_REPEAT_STATUS="fail"
              fi
              iteration=$(( iteration + 1 ))
            done
          done < "$REPEAT_SPEC.tsv"
        fi
      fi
    fi
  fi
fi

# --- summarize ---------------------------------------------------------------
GATE_FINISHED_AT="$(now_iso)"
GATE_ELAPSED=$(( $(date +%s) - GATE_START_EPOCH ))
write_meta "$GATE_FINISHED_AT" "$GATE_ELAPSED"

VERDICT=1
if python3 "$HELPER" summarize --run-dir "$RUN_DIR" \
    --out "$RUN_DIR/gate-result.json" --markdown "$RUN_DIR/summary.md"; then
  VERDICT=0
fi

echo ""
echo "tested SHA : $SHA"
echo "run dir    : $RUN_DIR"
echo "result json: $RUN_DIR/gate-result.json"
echo "summary    : $RUN_DIR/summary.md"

remove_worktree

if [ "$VERDICT" -eq 0 ]; then
  echo "local gate: PASS for $SHA"
  exit 0
fi
echo "local gate: FAIL for $SHA"
echo "to inspect the exact tree: git -C \"$REPO_ROOT\" worktree add --detach <path> $SHA"
exit 1
