#!/usr/bin/env bash
#
# DIAGNOSTIC EXPERIMENT ONLY (ci/sequential-xcodebuild-stall-diagnostic).
#
# Runs two frozen unit-lane class groups as two SEQUENTIAL xcodebuild
# test-without-building invocations inside ONE GitHub job on ONE hosted
# macos-26 runner, with NO Simulator erase/reset between them. The only
# fresh boundary between the groups is the xcodebuild/XCTest/testhost
# process itself. Isolates PR #182's result (the 7/7 split did not stall
# as separate matrix jobs) from the fresh-runner variable.
#
# Fidelity contract: each invocation is shaped exactly like a normal unit
# lane attempt — same planned watchdog (timeout_s from the plan), same
# native retry flags (-retry-tests-on-failure -test-iterations 3), same
# destination and build products. The ONE deliberate difference from a
# normal lane: no simulator shutdown/erase happens between invocation 1
# and invocation 2, so host/Simulator state survives the xcodebuild
# boundary.
#
# Invocation 2 ALWAYS runs, even if invocation 1 fails or stalls: the
# experiment is about the state that survives xcodebuild termination.
# Every invocation appends one JSON line to seq-records.jsonl immediately
# (an EXIT trap assembles seq-result.json even when GitHub kills the job),
# and the script exits nonzero if either invocation failed or stalled.
#
# Bash 3.2 compatible; sources ci-lib.sh for destination/deadline helpers.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ci-lib.sh"

PLAN_JSON=""; TARGET=""; XCRUN_FILE=""; RESULT_DIR=""; LANE_A=""; LANE_B=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plan-json) PLAN_JSON="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --xctestrun) XCRUN_FILE="$2"; shift 2 ;;
    --result-dir) RESULT_DIR="$2"; shift 2 ;;
    --lane-a) LANE_A="$2"; shift 2 ;;
    --lane-b) LANE_B="$2"; shift 2 ;;
    *) echo "::error::unknown argument: $1"; exit 2 ;;
  esac
done
missing=""
[ -z "$PLAN_JSON" ] && missing="$missing --plan-json"
[ -z "$TARGET" ] && missing="$missing --target"
[ -z "$XCRUN_FILE" ] && missing="$missing --xctestrun"
[ -z "$RESULT_DIR" ] && missing="$missing --result-dir"
[ -z "$LANE_A" ] && missing="$missing --lane-a"
[ -z "$LANE_B" ] && missing="$missing --lane-b"
if [ -n "$missing" ]; then
  echo "::error::ci-sequential-xcodebuild-diagnostic.sh missing arguments:$missing"
  exit 2
fi
if [ ! -f "$XCRUN_FILE" ]; then
  echo "::error::xctestrun file not found: $XCRUN_FILE"
  exit 1
fi

LOG_DIR="$RESULT_DIR/logs"
mkdir -p "$LOG_DIR"
RECORDS_JSONL="$RESULT_DIR/seq-records.jsonl"
: > "$RECORDS_JSONL"
SEQ_N=0
SEQ_FAILED=0
SEQ_RECORDS=""
SEQ_COMPLETED=0
STARTED_AT=""
build_destination
disable_pasteboard_sync

# Same native retry shape as a normal unit lane (--iterations 3).
RETRY_ARGS="-retry-tests-on-failure -test-iterations 3"

lane_classes() { # $1=plan $2=lane -> comma-separated classes (no repr)
  python3 -c "
import json, sys
doc = json.load(open(sys.argv[1], encoding='utf-8'))
lanes = {l['lane']: l for l in doc['unit_lanes']}
print(','.join(lanes[sys.argv[2]]['classes']))
" "$1" "$2"
}

lane_timeout() { # $1=plan $2=lane -> the lane's planned watchdog seconds
  python3 -c "
import json, sys
doc = json.load(open(sys.argv[1], encoding='utf-8'))
lanes = {l['lane']: l for l in doc['unit_lanes']}
print(lanes[sys.argv[2]]['timeout_s'])
" "$1" "$2"
}

write_seq_result() {
  python3 -c "
import json, sys
records = []
with open(sys.argv[1], encoding='utf-8') as fh:
    for line in fh:
        line = line.strip()
        if line:
            records.append(json.loads(line))
doc = {
    'schema_version': 1,
    'diagnostic': 'sequential-xcodebuild-boundary',
    'same_runner': True,
    'simulator_erased_between_invocations': False,
    'started_at': sys.argv[2],
    'completed': sys.argv[3] == '1',
    'invocations': records,
}
with open(sys.argv[4], 'w', encoding='utf-8', newline='\n') as fh:
    fh.write(json.dumps(doc, indent=2, sort_keys=True) + '\n')
print('sequential diagnostic result written:', sys.argv[4])
" "$RECORDS_JSONL" "${STARTED_AT:-}" "${SEQ_COMPLETED:-0}" "$RESULT_DIR/seq-result.json" || \
  echo "::error::could not write seq-result.json"
}
# The EXIT trap alone does not fire on GitHub's job-kill signals; TERM/INT
# handlers make sure even a truncated run records what completed.
trap write_seq_result EXIT
trap write_seq_result TERM
trap write_seq_result INT

record_invocation() { # $1=lane $2=classes $3=timeout $4=exit $5=elapsed
  local status_name="fail"
  if [ "$4" -eq 0 ]; then status_name="pass"
  elif [ "$4" -eq 124 ]; then status_name="timeout"
  fi
  python3 -c "
import json, sys
rec = {
    'lane': sys.argv[1],
    'status': sys.argv[2],
    'exit_code': int(sys.argv[3]),
    'elapsed_s': int(sys.argv[4]),
    'timeout_s': int(sys.argv[5]),
    'classes': sys.argv[6].split(','),
}
with open(sys.argv[7], 'a', encoding='utf-8', newline='\n') as fh:
    fh.write(json.dumps(rec, sort_keys=True) + '\n')
" "$1" "$status_name" "$4" "$5" "$3" "$2" "$RECORDS_JSONL" || \
    echo "::error::could not record invocation result for $1"
  if [ "$4" -ne 0 ]; then
    SEQ_FAILED=$(( ${SEQ_FAILED:-0} + 1 ))
  fi
}

A_CLASSES=$(lane_classes "$PLAN_JSON" "$LANE_A")
A_TIMEOUT=$(lane_timeout "$PLAN_JSON" "$LANE_A")
B_CLASSES=$(lane_classes "$PLAN_JSON" "$LANE_B")
B_TIMEOUT=$(lane_timeout "$PLAN_JSON" "$LANE_B")
if [ -z "$A_CLASSES" ] || [ -z "$B_CLASSES" ] || [ -z "$A_TIMEOUT" ] || [ -z "$B_TIMEOUT" ]; then
  echo "::error::could not resolve both lane groups from the plan artifact ($LANE_A / $LANE_B) - refusing to run a mis-targeted experiment"
  exit 2
fi
case "$A_TIMEOUT$B_TIMEOUT" in
  ''|*[!0-9]*) echo "::error::non-numeric watchdog budget from plan ($A_TIMEOUT / $B_TIMEOUT)"; exit 2 ;;
esac
echo "sequential diagnostic: $LANE_A (${A_TIMEOUT}s watchdog) then $LANE_B (${B_TIMEOUT}s watchdog) on ONE runner; NO Simulator erase between invocations"

STARTED_AT=$(now_iso)

# Startup parity with a normal unit lane: one bounded shutdown before the
# FIRST invocation only. Deliberately NOT repeated between the groups -
# surviving host/Simulator state across the xcodebuild boundary is the
# experiment.
bounded_run 60 xcrun simctl shutdown all || true

run_invocation() { # $1=lane $2=classes-csv $3=timeout-s ; sets R_EXIT/R_ELAPSED
  local lane="$1" classes="$2" budget="$3"
  local cls i
  IFS=',' read -r -a cls <<< "$classes"
  if [ "${#cls[@]}" -eq 0 ] || [ -z "${cls[0]:-}" ]; then
    echo "::error::sequential invocation $lane: no classes resolved; recording failure and continuing"
    R_EXIT=1
    R_ELAPSED=0
    return 0
  fi
  local only_args=()
  for i in "${!cls[@]}"; do
    only_args+=("-only-testing:$TARGET/${cls[$i]}")
  done
  local log="$LOG_DIR/seq-$lane.log"
  local started status=0
  started=$(date +%s)
  echo "::group::sequential xcodebuild: $lane (${#cls[@]} classes, watchdog ${budget}s)"
  run_with_deadline "$budget" "$log" \
    test-without-building \
    -xctestrun "$XCRUN_FILE" \
    -destination "$DESTINATION" \
    -resultBundlePath "$RESULT_DIR/seq-$lane.xcresult" \
    $RETRY_ARGS \
    -parallel-testing-enabled NO \
    "${only_args[@]}" || status=$?
  echo "::endgroup::"
  R_EXIT=$status
  R_ELAPSED=$(( $(date +%s) - started ))
  if [ "$status" -eq 0 ]; then
    echo "sequential invocation $lane: PASS in ${R_ELAPSED}s"
  elif [ "$status" -eq 124 ]; then
    echo "::error::sequential invocation $lane: WATCHDOG TIMEOUT after ${R_ELAPSED}s (budget ${budget}s)"
  else
    echo "::error::sequential invocation $lane: FAILED (exit $status) after ${R_ELAPSED}s"
  fi
}

# --- invocation 1: unit-5a1 ---------------------------------------------------
run_invocation "$LANE_A" "$A_CLASSES" "$A_TIMEOUT"
record_invocation "$LANE_A" "$A_CLASSES" "$A_TIMEOUT" "$R_EXIT" "$R_ELAPSED"

# --- invocation 2: unit-5a2 (ALWAYS runs; same host/Simulator state) ----------
run_invocation "$LANE_B" "$B_CLASSES" "$B_TIMEOUT"
record_invocation "$LANE_B" "$B_CLASSES" "$B_TIMEOUT" "$R_EXIT" "$R_ELAPSED"

SEQ_COMPLETED=1
write_seq_result

if [ "$SEQ_FAILED" -gt 0 ]; then
  echo "::error::sequential diagnostic: $SEQ_FAILED invocation(s) failed"
  exit 1
fi
echo "sequential diagnostic: both invocations passed on one runner"
exit 0
