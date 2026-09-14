#!/usr/bin/env bash
#
# State-machine tests for scripts/ci-test-lane.sh.
#
# The lane runner is exercised end-to-end against stub xcodebuild/xcrun
# binaries (no simulator, no real Xcode). Each case asserts the lane verdict,
# the attempt chain, and that an unclassifiable failure can never be retried
# into a green lane.
#
# Usage: bash scripts/tests/test_lane_runner.sh   (exit 0 = all cases pass)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
trap 'rm -rf "$WORK"' EXIT

pass_count=0
fail_count=0

ok()   { pass_count=$((pass_count + 1)); echo "  ok: $1"; }
bad()  { fail_count=$((fail_count + 1)); echo "  FAIL: $1"; }

assert_eq() { # $1=desc $2=actual $3=expected
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (actual='$2' expected='$3')"; fi
}

write_stub_xcodebuild() {
  cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
COUNT_FILE="$COUNT_FILE"
if [ "$FAKE_MODE" = "infra-once" ]; then
  n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
  n=$((n + 1))
  echo "$n" > "$COUNT_FILE"
  if [ "$n" -eq 1 ]; then
    echo "simulator crashed (stub)"
    exit 70
  fi
  exit 0
fi
case "$FAKE_MODE" in
  pass) exit 0 ;;
  fail65) echo "Test Case failed (stub)"; exit 65 ;;
  infra70) echo "Simulator boot failed (stub)"; exit 70 ;;
  hang) sleep 300; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUBS/xcodebuild"
}

write_stub_xcrun() {
  cat > "$STUBS/xcrun" <<'EOF'
#!/bin/bash
if [ "$1" = "xcresulttool" ]; then
  if [ -n "$FAKE_CANNED" ] && [ -f "$FAKE_CANNED" ]; then
    cat "$FAKE_CANNED"
    exit 0
  fi
  echo "not json - schema change (stub)"
  exit 0
fi
if [ "$1" = "simctl" ]; then
  # The erase-gated simulator recovery must be able to SUCCEED in tests, so
  # simctl list -j serves one pinned device (matching the default
  # SIMULATOR_NAME) for ci-lib's jq-based UDID resolution.
  if [ "$2 $3 $4 $5" = "list devices available -j" ]; then
    cat <<'DEV'
{"devices" : {"com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
  { "udid" : "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
    "name" : "iPhone 17 Pro", "state" : "Shutdown" }]}}
DEV
    exit 0
  fi
  # Simulate an erase/reboot recovery that never completes: the lane must
  # treat the environment as untrustworthy.
  if [ "$FAKE_UI_RECOVERY_FAILS" = "1" ] && [ "$2" = "bootstatus" ]; then
    echo "bootstatus failed (stub)"
    exit 1
  fi
  exit 0
fi
exit 0
EOF
  chmod +x "$STUBS/xcrun"
}

write_canned() { # $1=file $2=class $3=result
  cat > "$1" <<EOF
{"testNodes": [{"nodeType": "Test Plan", "name": "Conduit", "result": "Passed",
  "children": [{"nodeType": "Unit test bundle", "name": "ConduitTests", "result": "Passed",
    "children": [{"nodeType": "Test Suite", "name": "$2", "result": "Passed",
      "children": [{"nodeType": "Test Case", "name": "testC()", "result": "$3",
        "durationInSeconds": 0.1}]}]}]}]}
EOF
  export FAKE_CANNED="$1"
}

export PATH="$STUBS:$PATH"
write_stub_xcodebuild
write_stub_xcrun
touch "$WORK/fake.xctestrun"
# The stub xcodebuild invocations exit instantly; a full 15s poll interval
# per invocation would dominate the suite's wall clock (and blow the plan
# job's budget), so shrink the cadence. Behavior under test is unaffected:
# the deadline math and kill semantics are identical at any cadence.
export XCODEBUILD_POLL_INTERVAL_S=1

begin_case() { # $1=name $2=workdir
  current="$1"
  WORKCASE="$2"
  mkdir -p "$2"
  CASE_START=$(date +%s)
  echo "START $current"
}

end_case() { # closes the current case's timing line (suite-progress telemetry)
  [ -n "${current:-}" ] || return 0
  echo "END $current $(( $(date +%s) - CASE_START ))s"
  current=""
}

run_lane() { # $1=classes $2=timeout $3=mode $4=iterations
  _classes="$1"; _timeout="$2"; _mode="$3"; _iters="$4"; shift 4
  FAKE_MODE="$_mode" CLASS_TIMEOUT_MIN_S="1" CLASS_TIMEOUT_MULTIPLIER="0.1"     bash "$SCRIPTS/ci-test-lane.sh"     --kind unit --lane unit-t --target ConduitTests     --classes "$_classes"     --predicted 42 --timeout "$_timeout"     --iterations "$_iters"     --xctestrun "$WORK/fake.xctestrun"     --result-dir "$WORKCASE" >"$WORKCASE/stdout.log" 2>&1
  echo $? > "$WORKCASE/exit-code"
}

lane_field() { # $1=python expression applied to the lane-result document
  python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
print(eval('d' + sys.argv[2]))
" "$WORKCASE/lane-result.json" "$1" 2>/dev/null || echo NONE
}

attempts_statuses() {
  python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
print([a['status'] for a in d.get('attempts', [])])
" "$WORKCASE/lane-result.json" 2>/dev/null || echo NONE
}

isolation_statuses() {
  python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
print([c['status'] for c in (d.get('isolation') or {}).get('classes', [])])
" "$WORKCASE/lane-result.json" 2>/dev/null || echo NONE
}

retried_classes() {
  python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
print(d.get('retried_classes'))
" "$WORKCASE/lane-result.json" 2>/dev/null || echo NONE
}

run_ui_lane() { # $1=classes $2=lane-timeout(bookkeeping) $3=class-timeouts
  _classes="$1"; _timeout="$2"; _cto="$3"
  CLASS_TIMEOUT_MIN_S="1" CLASS_TIMEOUT_MULTIPLIER="0.1"     bash "$SCRIPTS/ci-test-lane.sh"     --kind ui --lane ui-t --target ConduitUITests     --classes "$_classes"     --class-timeouts "$_cto"     --predicted 42 --timeout "$_timeout"     --xctestrun "$WORK/fake.xctestrun"     --result-dir "$WORKCASE" >"$WORKCASE/stdout.log" 2>&1
  echo $? > "$WORKCASE/exit-code"
}

# Stub that decides per invocation SHAPE: the batched shard invocation
# (result bundle stem batch-a1/batch-a2) is driven by $FAKE_BATCH_A1 /
# $FAKE_BATCH_RETRY; per-class diagnosis invocations (bundle stem
# class-<cls>-a1/a2) are driven by the $FAKE_UI_* class tables. Every
# invocation rewrites the canned xcresult document to match its own verdict
# for EVERY class it was asked to run, so the runner's classification sees
# the right detail. Invocation facts land in $INVOCATION_LOG as
# "batch-a1", "batch-a2 (filters: ...)" and "class:<cls>:<kind>" lines.
write_ui_stub_xcodebuild() {
  cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
bundle=""
for a in "$@"; do
  case "$a" in
    *.xcresult) bundle="$a"; mkdir -p "$a" ;;
  esac
done
kind=a1
case "$bundle" in
  *-a2.xcresult) kind=a2 ;;
esac
mode=class
case "$bundle" in
  *batch-*) mode=batch ;;
esac
classes=""
methods=""
for a in "$@"; do
  case "$a" in
    -only-testing:*)
      spec="${a#-only-testing:}"
      rest="${spec#*/}"
      cls="${rest%%/*}"
      case "$rest" in
        */*) methods="$methods $rest" ;;
      esac
      case " $classes " in *" $cls "*) ;; *) classes="$classes $cls" ;; esac
      ;;
  esac
done

# Write the canned extraction document: one Test Suite node per Class:Result.
# Classes listed in $FAKE_BATCH_SKIP_CLASSES get an extra Skipped test (final
# != Passed, so the runner's retry filters must include it).
write_doc_multi() {
  docfile="$1"; shift
  nodes=""
  sep=""
  for pair in "$@"; do
    c="${pair%%:*}"; r="${pair#*:}"
    extra=""
    case " $FAKE_BATCH_SKIP_CLASSES " in *" $c "*)
      extra=",{\"nodeType\": \"Test Case\", \"name\": \"testD()\", \"result\": \"Skipped\",
        \"durationInSeconds\": 0.1}" ;;
    esac
    nodes="$nodes$sep{\"nodeType\": \"Test Suite\", \"name\": \"$c\", \"result\": \"$r\",
      \"children\": [{\"nodeType\": \"Test Case\", \"name\": \"testC()\", \"result\": \"$r\",
      \"durationInSeconds\": 0.1}$extra]}"
    sep=","
  done
  cat > "$FAKE_CANNED" <<DOC
{"testNodes": [{"nodeType": "Test Plan", "name": "Conduit", "result": "Passed",
  "children": [{"nodeType": "UI test bundle", "name": "ConduitUITests", "result": "Passed",
    "children": [$nodes]}]}]}
DOC
}

write_all_passed() {
  # $@ = class names
  pairs=""
  for c in "$@"; do pairs="$pairs $c:Passed"; done
  write_doc_multi "$FAKE_CANNED" $pairs
}

# The canned document must reflect an ABORTED batch: classes listed in
# $FAKE_BATCH_OMIT_CLASSES never ran and get no Test Suite node at all.
doc_classes=""
for c in $classes; do
  case " $FAKE_BATCH_OMIT_CLASSES " in *" $c "*) ;; *) doc_classes="$doc_classes $c" ;; esac
done

if [ "$mode" = "batch" ]; then
  case "$kind" in
    a1)
      echo "batch-a1" >> "$INVOCATION_LOG"
      [ -n "${FAKE_UI_NO_DOC:-}" ] || write_all_passed $doc_classes
      case "$FAKE_BATCH_A1" in
        hang)
          sleep 300
          exit 0
          ;;
        infra)
          echo "simulator crashed (stub)"
          exit 70
          ;;
        fail-test)
          pairs=""
          for c in $doc_classes; do
            case " $FAKE_BATCH_FAIL_CLASSES " in *" $c "*) pairs="$pairs $c:Failed" ;; *) pairs="$pairs $c:Passed" ;; esac
          done
          # NO_DOC keeps the canned document stale so extraction fails.
          [ -n "${FAKE_UI_NO_DOC:-}" ] || write_doc_multi "$FAKE_CANNED" $pairs
          echo "Test Case failed (stub)"
          exit 65
          ;;
        *)
          exit 0
          ;;
      esac
      ;;
    a2)
      echo "batch-a2 (filters:$methods)" >> "$INVOCATION_LOG"
      [ -n "${FAKE_UI_NO_DOC:-}" ] || write_all_passed $doc_classes
      case "$FAKE_BATCH_RETRY" in
        hang)
          sleep 300
          exit 0
          ;;
        infra)
          echo "simulator crashed (stub)"
          exit 70
          ;;
        fail)
          pairs=""
          for c in $doc_classes; do pairs="$pairs $c:Failed"; done
          [ -n "${FAKE_UI_NO_DOC:-}" ] || write_doc_multi "$FAKE_CANNED" $pairs
          echo "Test Case failed (stub)"
          exit 65
          ;;
        *)
          exit 0
          ;;
      esac
      ;;
  esac
  exit 0
fi

# Class mode: exactly one class per invocation.
cls=$(printf '%s\n' $classes | head -1)
echo "class:$cls:$kind" >> "$INVOCATION_LOG"
# A hanging class hangs on BOTH attempts: the second hang is what names the
# culprit and stops the lane.
case " $FAKE_UI_HANG " in *" $cls "*) sleep 300; exit 0 ;; esac
case "$kind" in
  a1) case " $FAKE_UI_FAIL_ONCE " in *" $cls "*) write_doc_multi "$FAKE_CANNED" "$cls:Failed"; echo "Test Case failed (stub)"; exit 65 ;; esac
      case " $FAKE_UI_FAIL_ALWAYS " in *" $cls "*) write_doc_multi "$FAKE_CANNED" "$cls:Failed"; echo "Test Case failed (stub)"; exit 65 ;; esac
      case " $FAKE_UI_INFRA_ONCE " in *" $cls "*) write_doc_multi "$FAKE_CANNED" "$cls:Passed"; echo "simulator crashed (stub)"; exit 70 ;; esac
      case " $FAKE_UI_INFRA_ALWAYS " in *" $cls "*) write_doc_multi "$FAKE_CANNED" "$cls:Passed"; echo "simulator crashed (stub)"; exit 70 ;; esac
      ;;
  a2) case " $FAKE_UI_FAIL_ALWAYS " in *" $cls "*) write_doc_multi "$FAKE_CANNED" "$cls:Failed"; echo "Test Case failed (stub)"; exit 65 ;; esac
      case " $FAKE_UI_INFRA_ALWAYS " in *" $cls "*) write_doc_multi "$FAKE_CANNED" "$cls:Passed"; echo "simulator crashed (stub)"; exit 70 ;; esac
      ;;
esac
write_doc_multi "$FAKE_CANNED" "$cls:Passed"
exit 0
EOF
  chmod +x "$STUBS/xcodebuild"
}

batch_invocations() { # $1 = exact batch line -> count
  grep -cx "$1" "$INVOCATION_LOG" 2>/dev/null || true
}
class_invocations() { # $1=class -> how many diagnosis invocations it got
  grep -c "^class:$1:" "$INVOCATION_LOG" 2>/dev/null || true
}



# --- case 1: pass -------------------------------------------------------------
end_case
begin_case "pass path" "$WORK/c1"
write_canned "$WORK/canned-pass.json" "AlphaTests" "Passed"
run_lane "AlphaTests" 300 pass 3
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" "['passed']"

# --- case 2: ordinary failure -> fail, no lane retry --------------------------
end_case
begin_case "ordinary failure" "$WORK/c2"
write_canned "$WORK/canned-fail.json" "AlphaTests" "Failed"
run_lane "AlphaTests" 300 fail65 3
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "attempts" "$(attempts_statuses)" "['test-failures']"
if grep -q "attempt 2" "$WORKCASE/stdout.log"; then
  bad "ordinary failure must not trigger a full-lane retry"
else
  ok "no full-lane retry after ordinary failure"
fi

# --- case 3: unclassified failure -> fail, never retried ----------------------
end_case
begin_case "unclassified failure" "$WORK/c3"
# Extraction must fail: xcrun returns an invalid document (no canned file).
export FAKE_CANNED="$WORK/does-not-exist.json"
run_lane "AlphaTests" 300 fail65 3
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "attempts" "$(attempts_statuses)" "['unclassified']"
if grep -q "attempt 2" "$WORKCASE/stdout.log"; then
  bad "unclassified failure must not be retried into a second lane run"
else
  ok "unclassified failure not retried"
fi

# --- case 4: infra failure -> exactly one full-lane retry, then error ---------
end_case
begin_case "infra failure retry" "$WORK/c4"
write_canned "$WORK/canned-pass2.json" "AlphaTests" "Passed"
run_lane "AlphaTests" 300 infra70 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "error"
assert_eq "attempts" "$(attempts_statuses)" "['infra-error', 'infra-error']"


# --- case 5: timeout -> isolation directly, hang identified -------------------
end_case
begin_case "timeout isolation" "$WORK/c5"
export ISOLATION_BUDGET_S=200 CLASS_TIMEOUT_MIN_S=1 CLASS_TIMEOUT_MULTIPLIER=0.1
run_lane "AlphaTests,BetaTests" 3 hang 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "timeout"
assert_eq "hung class" "$(lane_field "['hung_class']")" "AlphaTests"
assert_eq "first attempt" "$(attempts_statuses | grep -o 'timeout' | head -1)" "timeout"
if grep -q "lane-retry" "$WORKCASE/lane-result.json"; then
  bad "timeout must not do a second full-lane attempt"
else
  ok "no full-lane retry after timeout"
fi
assert_eq "isolation ran" "$(isolation_statuses)" "['timeout', 'not_diagnosed']"

# --- case 6: incomplete isolation fails the lane ------------------------------
end_case
begin_case "incomplete isolation" "$WORK/c6"
export ISOLATION_BUDGET_S=2 CLASS_TIMEOUT_MIN_S=1 CLASS_TIMEOUT_MULTIPLIER=0.1
run_lane "AlphaTests,BetaTests" 3 hang 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "timeout"
assert_eq "isolation statuses" "$(isolation_statuses)" "['not_diagnosed', 'not_diagnosed']"
if grep -q "undiagnosed classes" "$WORKCASE/stdout.log"; then
  ok "undiagnosed classes reported"
else
  bad "undiagnosed classes must be reported loudly"
fi


# --- case 7: isolation stops after the first confirmed hang ------
# Spec scenario: AlphaTests PASSES, BetaTests TIMES OUT, GammaTests
# would pass if called - but must NEVER run on the contaminated
# simulator. Tracks exact xcodebuild invocation counts via the stub.
end_case
begin_case "stop after hang" "$WORK/c7"
cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
n=$(printf '%s\n' "$@" | grep -c -- '-only-testing:' || true)
if [ "$n" -gt 1 ]; then
  echo "full" >> "$INVOCATION_LOG"
  sleep 300
  exit 0
fi
cls=$(printf '%s\n' "$@" | grep 'only-testing:' | head -1 | sed 's|.*/||')
echo "iso:$cls" >> "$INVOCATION_LOG"
case "$cls" in
  BetaTests) sleep 300; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUBS/xcodebuild"
INVOCATION_LOG="$WORK/c7-invocations.log"
: > "$INVOCATION_LOG"
export INVOCATION_LOG
export ISOLATION_BUDGET_S=200 CLASS_TIMEOUT_MIN_S=1 CLASS_TIMEOUT_MULTIPLIER=0.1
run_lane "AlphaTests,BetaTests,GammaTests" 3 hang-second 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "timeout"
assert_eq "hung class" "$(lane_field "['hung_class']")" "BetaTests"
assert_eq "full lane run once" "$(grep -c '^full$' "$INVOCATION_LOG")" "1"
assert_eq "isolation statuses" "$(isolation_statuses)" "['pass', 'timeout', 'not_diagnosed']"
assert_eq "AlphaTests invoked once" "$(grep -c '^iso:AlphaTests$' "$INVOCATION_LOG")" "1"
assert_eq "BetaTests invoked once" "$(grep -c '^iso:BetaTests$' "$INVOCATION_LOG")" "1"
assert_eq "GammaTests never invoked" "$(grep -c '^iso:GammaTests$' "$INVOCATION_LOG")" "0"

# --- case 8: finished session survives its budget via finalize grace ----------
# Run #500 regression: xcodebuild printed its terminal result and was only
# finalizing the xcresult when the watchdog expired. The deadline must be
# extended ONCE (bounded grace) so the finished session can exit with its
# real status; success still comes from the exit status, never the marker.
end_case
begin_case "finalize grace lets a finished invocation pass" "$WORK/c8"
cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
echo "running tests (stub)"
sleep 4
echo "** TEST EXECUTE SUCCEEDED **"
echo "finalizing xcresult (stub)"
sleep 4
exit 0
EOF
chmod +x "$STUBS/xcodebuild"
export XCODEBUILD_FINALIZE_GRACE_S=30
write_canned "$WORK/canned-grace.json" "AlphaTests" "Passed"
run_lane "AlphaTests" 5 pass 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" "['passed']"
if grep -q "finalize grace" "$WORKCASE/stdout.log"; then
  ok "finalize grace reported"
else
  bad "finalize grace must be reported when it fires"
fi

# --- case 9: grace is bounded - a wedged finalize is still a timeout ----------
end_case
begin_case "finalize grace expiry kills and isolates" "$WORK/c9"
cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
echo "** TEST EXECUTE SUCCEEDED **"
echo "wedged finalization (stub)"
sleep 300
exit 0
EOF
chmod +x "$STUBS/xcodebuild"
export XCODEBUILD_FINALIZE_GRACE_S=3
export ISOLATION_BUDGET_S=200 CLASS_TIMEOUT_MIN_S=1 CLASS_TIMEOUT_MULTIPLIER=0.1
run_lane "AlphaTests" 3 pass 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "timeout"
assert_eq "first attempt" "$(attempts_statuses | grep -o 'timeout' | head -1)" "timeout"
if grep -q "finalize grace" "$WORKCASE/stdout.log"; then
  ok "grace was granted before the kill"
else
  bad "grace must be attempted before killing a finalized session"
fi

# --- case 10: infra failure recovers on the single post-reset retry -----------
end_case
begin_case "infra retry recovers to green" "$WORK/c10"
cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$COUNT_FILE"
if [ "$n" -eq 1 ]; then
  echo "simulator crashed once (stub)"
  exit 70
fi
exit 0
EOF
chmod +x "$STUBS/xcodebuild"
export COUNT_FILE="$WORK/c10-count"
: > "$COUNT_FILE"
write_canned "$WORK/canned-c10.json" "AlphaTests" "Passed"
run_lane "AlphaTests" 300 infra-once 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" "['infra-recovered', 'passed']"

# --- case 11: class failure during isolation fails the lane --------------------
end_case
begin_case "class failure during isolation" "$WORK/c11"
cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
n=$(printf '%s\n' "$@" | grep -c -- '-only-testing:' || true)
if [ "$n" -gt 1 ]; then
  sleep 300
  exit 0
fi
exit 65
EOF
chmod +x "$STUBS/xcodebuild"
export ISOLATION_BUDGET_S=200 CLASS_TIMEOUT_MIN_S=1 CLASS_TIMEOUT_MULTIPLIER=0.1
run_lane "AlphaTests,BetaTests" 3 fail65 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "isolation statuses" "$(isolation_statuses)" "['fail', 'fail']"

# ===========================================================================
# CoreAudio HOST wedge recovery (unit lanes): the strong AURemoteIO -10851 /
# HALC overload signature identifies a poisoned RUNNER ENVIRONMENT - any
# lane can be hit and there is deliberately NO test-class inventory. On the
# failure path the retry scope is EVERY identified failed class; on the
# timeout path the scope is the whole lane (no per-test attribution exists).
# The stub emits synthetic signature lines and discriminates invocations by
# BUNDLE NAME (attempt-1 / attempt-2-audio-retry / attempt-2-host-retry).
# ===========================================================================
# (the old AUDIO_INVENTORY export is gone: classification is inventory-free)

# Stub: attempt 1 (full lane) fails the classes named in
# $FAKE_WEDGE_FAIL_CLASSES while the rest pass, and emits the signature per
# $FAKE_WEDGE_A1 (signature | weak | "" ; hang hangs instead). The recovery
# invocations are driven by $FAKE_WEDGE_RETRY (targeted) /
# $FAKE_WEDGE_HOST_RETRY (whole-lane): pass | fail | signature. Every
# invocation lands in $INVOCATION_LOG.
write_wedge_stub_xcodebuild() {
  cat > "$STUBS/xcodebuild" <<'STUB'
#!/bin/bash
for a in "$@"; do
  case "$a" in *.xcresult)
    mkdir -p "$a"
    bundle="$a"
    ;;
  esac
done
n=$(printf '%s
' "$@" | grep -c -- '-only-testing:' || true)
echo "inv:filters=$n" >> "$INVOCATION_LOG"
emit_signature() {
  i=0
  while [ "$i" -lt 200 ]; do
    echo "2026-09-14 00:00:00.000 Conduit[9:9] [aurioc]            AURemoteIO.cpp:1135  failed: -10851 (enable 1)"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt 30 ]; do
    echo "2026-09-14 00:00:00.000 Conduit[9:9] [AMCP]          HALC_ProxyIOContext.cpp:1623  HALC_ProxyIOContext::IOWorkLoop: skipping cycle due to overload"
    i=$((i + 1))
  done
}
emit_weak() {
  echo "2026-09-14 00:00:00.000 Conduit[9:9] [aurioc]            AURemoteIO.cpp:1135  failed: -10851 (enable 1)"
}
write_doc() {
  docfile="$1"; shift
  nodes=""
  sep=""
  for pair in "$@"; do
    c="${pair%%:*}"; r="${pair#*:}"
    nodes="$nodes$sep{\"nodeType\": \"Test Suite\", \"name\": \"$c\", \"result\": \"$r\",
      \"children\": [{\"nodeType\": \"Test Case\", \"name\": \"testC()\", \"result\": \"$r\",
      \"durationInSeconds\": 0.1}]}"
    sep=","
  done
  cat > "$FAKE_CANNED" <<DOC
{"testNodes": [{"nodeType": "Test Plan", "name": "Conduit", "result": "Passed",
  "children": [{"nodeType": "Unit test bundle", "name": "ConduitTests", "result": "Passed",
    "children": [$nodes]}]}]}
DOC
}
mode=full
case "$bundle" in
  *attempt-2-audio-retry.xcresult) mode=audio-retry ;;
  *attempt-2-host-retry.xcresult) mode=host-retry ;;
esac

if [ "$mode" = "full" ]; then
  # Attempt 1: the classes in $FAKE_WEDGE_FAIL_CLASSES fail, the rest pass.
  pairs=""
  for a in "$@"; do
    case "$a" in
      -only-testing:*)
        c="${a#-only-testing:*/}"
        case " $FAKE_WEDGE_FAIL_CLASSES " in *" $c "*)
          pairs="$pairs $c:Failed" ;; *) pairs="$pairs $c:Passed" ;;
        esac
        ;;
    esac
  done
  write_doc "$FAKE_CANNED" $pairs
  case "$FAKE_WEDGE_A1" in
    signature) emit_signature ;;
    weak) emit_weak ;;
  esac
  case "$FAKE_WEDGE_A1" in
    hang | hang-signature | hang-weak)
      [ "$FAKE_WEDGE_A1" = "hang-signature" ] && emit_signature
      [ "$FAKE_WEDGE_A1" = "hang-weak" ] && emit_weak
      sleep 300
      ;;
    *)
      echo "Test Case failed (stub)"
      exit 65
      ;;
  esac
  exit 0
fi

# Recovery invocations: EVERY filtered class, one doc, per-class logging.
pairs=""
for a in "$@"; do
  case "$a" in
    -only-testing:*)
      c="${a#-only-testing:*/}"
      echo "retry:$c" >> "$INVOCATION_LOG"
      case "$mode|$FAKE_WEDGE_RETRY|$FAKE_WEDGE_HOST_RETRY" in
        audio-retry|*pass*|pass) pairs="$pairs $c:Passed" ;;
        *) pairs="$pairs $c:Failed" ;;
      esac
      ;;
  esac
done
write_doc "$FAKE_CANNED" $pairs
if [ "$mode" = "audio-retry" ]; then
  case "$FAKE_WEDGE_RETRY" in
    pass) exit 0 ;;
    signature)
      emit_signature
      echo "Test Case failed (stub)"
      exit 65
      ;;
    *)
      echo "Test Case failed (stub)"
      exit 65
      ;;
  esac
fi
# host-retry
case "$FAKE_WEDGE_HOST_RETRY" in
  pass) exit 0 ;;
  signature)
    emit_signature
    echo "Test Case failed (stub)"
    exit 65
    ;;
  *)
    echo "Test Case failed (stub)"
    exit 65
    ;;
esac
STUB
  chmod +x "$STUBS/xcodebuild"
}

coreaudio_wedge_field() { # $1 = python expression over the wedge metadata
  python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
w = d.get('coreaudio_wedge') or {}
print(eval('w' + sys.argv[2]))
" "$WORKCASE/lane-result.json" "$1" 2>/dev/null || echo NONE
}

# --- host case 1+2+3: mixed failures, EVERY failed class retried once ---------
end_case
begin_case "coreaudio host wedge recovers: every failed class retried" "$WORK/w1"
write_stub_xcrun
write_wedge_stub_xcodebuild
export FAKE_CANNED="$WORK/canned-wedge.json"
export INVOCATION_LOG="$WORK/w1-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_WEDGE_A1="signature" FAKE_WEDGE_RETRY="pass"
export FAKE_WEDGE_FAIL_CLASSES="ChatResumeTests MarkdownTests"
run_lane "ChatResumeTests,MarkdownTests,PickerTests" 300 unused 3
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" "['audio-wedge', 'passed']"
assert_eq "both recovered classes recorded" "$(lane_field "['infra_recovered_classes']")" "['ChatResumeTests', 'MarkdownTests']"
assert_eq "wedge metadata embedded" "$(coreaudio_wedge_field "['wedge']")" "True"
assert_eq "signature counts in metadata" "$(coreaudio_wedge_field "['signals']['auremoteio_10851']")" "200"
assert_eq "attempt-1 + one targeted retry invocation" "$(grep -c '^inv:filters=' "$INVOCATION_LOG")" "2"
assert_eq "first failed class re-ran" "$(grep -c '^retry:ChatResumeTests$' "$INVOCATION_LOG")" "1"
assert_eq "second (non-audio) failed class re-ran" "$(grep -c '^retry:MarkdownTests$' "$INVOCATION_LOG")" "1"
assert_eq "healthy class never re-ran" "$(grep -c '^retry:PickerTests$' "$INVOCATION_LOG")" "0"
if grep -q "CoreAudio host wedge detected" "$WORKCASE/stdout.log" \
   && grep -q "AURemoteIO -10851 occurrences: 200" "$WORKCASE/stdout.log" \
   && grep -q "action: resetting simulator and retrying affected tests" "$WORKCASE/stdout.log"; then
  ok "wedge diagnostics announced with signal counts"
else
  bad "wedge diagnostics must announce the signature counts and the action"
fi
if ls "$WORKCASE"/attempt-1.xcresult >/dev/null 2>&1 && ls "$WORKCASE"/attempt-2-audio-retry.xcresult >/dev/null 2>&1; then
  ok "both wedge attempt bundles kept on a green lane"
else
  bad "wedge attempt bundles must be preserved for diagnosis"
fi

# --- host case 4: retry fails WITHOUT the signature -> real product failure ---
end_case
begin_case "wedge retry failure without signature is a product failure" "$WORK/w2"
export INVOCATION_LOG="$WORK/w2-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_WEDGE_A1="signature" FAKE_WEDGE_RETRY="fail"
export FAKE_WEDGE_FAIL_CLASSES="ChatResumeTests"
run_lane "ChatResumeTests,PickerTests" 300 unused 3
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "attempts" "$(attempts_statuses)" "['audio-wedge', 'test-failures']"
assert_eq "no third invocation" "$(grep -c '^inv:filters=' "$INVOCATION_LOG")" "2"
assert_eq "failed wedge lane reports the failures" "$(lane_field "['failures']" | grep -c ChatResumeTests)" "1"
assert_eq "failed wedge lane claims no recovery" "$(lane_field "['infra_recovered_classes']")" "[]"

# --- host case 8: retry carries the signature -> persistent, no loop ----------
end_case
begin_case "persistent coreaudio wedge fails bounded" "$WORK/w3"
export INVOCATION_LOG="$WORK/w3-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_WEDGE_A1="signature" FAKE_WEDGE_RETRY="signature"
export FAKE_WEDGE_FAIL_CLASSES="ChatResumeTests"
run_lane "ChatResumeTests,PickerTests" 300 unused 3
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "attempts" "$(attempts_statuses)" "['audio-wedge', 'persistent-coreaudio-wedge']"
assert_eq "hard limit: exactly two invocations" "$(grep -c '^inv:filters=' "$INVOCATION_LOG")" "2"
if grep -q "persistent CoreAudio runner failure" "$WORKCASE/stdout.log"; then
  ok "persistent wedge reported as an environment verdict"
else
  bad "a persistent wedge must say so explicitly"
fi

# --- host case 5: weak/ambient signature + failure -> no recovery -------------
end_case
begin_case "weak signature never authorizes recovery" "$WORK/w4"
cat > "$STUBS/xcodebuild" <<'STUB'
#!/bin/bash
for a in "$@"; do
  case "$a" in *.xcresult) mkdir -p "$a" ;; esac
done
cat > "$FAKE_CANNED" <<'DOC'
{"testNodes": [{"nodeType": "Test Plan", "name": "Conduit", "result": "Passed",
  "children": [{"nodeType": "Unit test bundle", "name": "ConduitTests", "result": "Passed",
    "children": [{"nodeType": "Test Suite", "name": "ChatResumeTests", "result": "Failed",
      "children": [{"nodeType": "Test Case", "name": "testC()", "result": "Failed",
        "durationInSeconds": 0.1}]}]}]}]}
DOC
n=$(printf '%s\n' "$@" | grep -c -- '-only-testing:' || true)
echo "inv:filters=$n" >> "$INVOCATION_LOG"
echo "2026-09-14 00:00:00.000 Conduit[9:9] [aurioc]            AURemoteIO.cpp:1135  failed: -10851 (enable 1)"
echo "Test Case failed (stub)"
exit 65
STUB
chmod +x "$STUBS/xcodebuild"
export INVOCATION_LOG="$WORK/w4-invocations.log"; : > "$INVOCATION_LOG"
run_lane "ChatResumeTests" 300 unused 3
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "attempts" "$(attempts_statuses)" "['test-failures']"
assert_eq "exactly one invocation" "$(grep -c '^inv:filters=' "$INVOCATION_LOG")" "1"

# --- host case 6: strong signature + TIMEOUT -> one lane retry, no isolation --
end_case
begin_case "timeout with strong host signature retries the lane once" "$WORK/w5"
write_wedge_stub_xcodebuild
export INVOCATION_LOG="$WORK/w5-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_WEDGE_A1="hang-signature" FAKE_WEDGE_HOST_RETRY="pass"
export FAKE_WEDGE_FAIL_CLASSES="ChatResumeTests"
export ISOLATION_BUDGET_S=200 CLASS_TIMEOUT_MIN_S=1 CLASS_TIMEOUT_MULTIPLIER=0.1
run_lane "ChatResumeTests,PickerTests" 3 unused 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" "['host-wedge-timeout', 'passed']"
assert_eq "no per-class recovery claims" "$(lane_field "['infra_recovered_classes']")" "[]"
assert_eq "wedge metadata embedded" "$(coreaudio_wedge_field "['wedge']")" "True"
assert_eq "exactly two full-lane invocations" "$(grep -c '^inv:filters=' "$INVOCATION_LOG")" "2"
assert_eq "no isolation ran" "$(grep -c 'isolation:' "$WORKCASE/stdout.log")" "0"
if grep -q "CoreAudio host wedge detected behind the watchdog" "$WORKCASE/stdout.log"; then
  ok "timeout host wedge diagnosed from the invocation log"
else
  bad "the timeout host wedge must be diagnosed before isolation"
fi

# --- host case 7: weak signature + timeout -> UNCHANGED isolation path --------
end_case
begin_case "weak signature timeout keeps the isolation path" "$WORK/w6"
cat > "$STUBS/xcodebuild" <<'STUB'
#!/bin/bash
n=$(printf '%s\n' "$@" | grep -c -- '-only-testing:' || true)
if [ "$n" -gt 1 ]; then
  echo "2026-09-14 00:00:00.000 Conduit[9:9] [aurioc]            AURemoteIO.cpp:1135  failed: -10851 (enable 1)"
  sleep 300
  exit 0
fi
exit 0
STUB
chmod +x "$STUBS/xcodebuild"
export INVOCATION_LOG="$WORK/w6-invocations.log"; : > "$INVOCATION_LOG"
export ISOLATION_BUDGET_S=200 CLASS_TIMEOUT_MIN_S=1 CLASS_TIMEOUT_MULTIPLIER=0.1
run_lane "AlphaTests,BetaTests" 3 unused 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "isolation ran" "$(isolation_statuses)" "['pass', 'pass']"
assert_eq "no host-retry attempt" "$(grep -c 'host-retry' "$WORKCASE/lane-result.json" 2>/dev/null || true)" "0"
if grep -q "CoreAudio host wedge detected" "$WORKCASE/stdout.log"; then
  bad "a weak-signature timeout must not classify as a host wedge"
else
  ok "weak-signature timeout never classified"
fi

# --- host case 10: signature + zero failing tests -> ordinary infra retry -----
end_case
begin_case "signature with zero failing tests takes the infra path" "$WORK/w7"
cat > "$STUBS/xcodebuild" <<'STUB'
#!/bin/bash
for a in "$@"; do
  case "$a" in *.xcresult) mkdir -p "$a" ;; esac
done
n=$(printf '%s\n' "$@" | grep -c -- '-only-testing:' || true)
echo "inv:filters=$n" >> "$INVOCATION_LOG"
cat > "$FAKE_CANNED" <<'DOC'
{"testNodes": [{"nodeType": "Test Plan", "name": "Conduit", "result": "Passed",
  "children": [{"nodeType": "Unit test bundle", "name": "ConduitTests", "result": "Passed",
    "children": [{"nodeType": "Test Suite", "name": "ChatResumeTests", "result": "Passed",
      "children": [{"nodeType": "Test Case", "name": "testC()", "result": "Passed",
        "durationInSeconds": 0.1}]}]}]}]}
DOC
i=0
while [ "$i" -lt 200 ]; do
  echo "2026-09-14 00:00:00.000 Conduit[9:9] [aurioc]            AURemoteIO.cpp:1135  failed: -10851 (enable 1)"
  i=$((i + 1))
done
echo "simulator crashed once (stub)"
if [ "$(grep -c '^inv:filters=' "$INVOCATION_LOG")" -ge 2 ]; then
  exit 0
fi
exit 70
STUB
chmod +x "$STUBS/xcodebuild"
export INVOCATION_LOG="$WORK/w7-invocations.log"; : > "$INVOCATION_LOG"
export COUNT_FILE="$WORK/w7-count"
write_canned "$WORK/canned-w7.json" "ChatResumeTests" "Passed"
export FAKE_CANNED="$WORK/canned-w7.json"
run_lane "ChatResumeTests" 300 infra-once 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts are the ordinary infra chain" "$(attempts_statuses)" "['infra-recovered', 'passed']"
assert_eq "no audio-retry marker" "$(grep -o 'audio-retry' "$WORKCASE/lane-result.json" 2>/dev/null | wc -l | tr -d ' ')" "0"

# --- host case: timeout-path retry fails WITHOUT signature -> product failure -
end_case
begin_case "timeout host-retry failure without signature is a product failure" "$WORK/w8"
write_wedge_stub_xcodebuild
export INVOCATION_LOG="$WORK/w8-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_WEDGE_A1="hang-signature" FAKE_WEDGE_HOST_RETRY="fail"
export FAKE_WEDGE_FAIL_CLASSES="ChatResumeTests"
export ISOLATION_BUDGET_S=200 CLASS_TIMEOUT_MIN_S=1 CLASS_TIMEOUT_MULTIPLIER=0.1
run_lane "ChatResumeTests,PickerTests" 3 unused 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "attempts" "$(attempts_statuses)" "['host-wedge-timeout', 'test-failures']"
assert_eq "hard limit: exactly two invocations" "$(grep -c '^inv:filters=' "$INVOCATION_LOG")" "2"
assert_eq "no per-class recovery claims" "$(lane_field "['infra_recovered_classes']")" "[]"

# --- host case: timeout-path retry signature-again -> persistent, no loop -----
end_case
begin_case "timeout host-retry signature-again is persistent infrastructure" "$WORK/w9"
write_wedge_stub_xcodebuild
export INVOCATION_LOG="$WORK/w9-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_WEDGE_A1="hang-signature" FAKE_WEDGE_HOST_RETRY="signature"
export FAKE_WEDGE_FAIL_CLASSES="ChatResumeTests"
export ISOLATION_BUDGET_S=200 CLASS_TIMEOUT_MIN_S=1 CLASS_TIMEOUT_MULTIPLIER=0.1
run_lane "ChatResumeTests,PickerTests" 3 unused 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "attempts" "$(attempts_statuses)" "['host-wedge-timeout', 'persistent-coreaudio-wedge']"
assert_eq "hard limit: exactly two invocations" "$(grep -c '^inv:filters=' "$INVOCATION_LOG")" "2"
if grep -q "persistent CoreAudio runner failure" "$WORKCASE/stdout.log"; then
  ok "persistent timeout-path wedge reported as an environment verdict"
else
  bad "a persistent timeout-path wedge must say so explicitly"
fi



echo ""
end_case
echo "unit+isolation state machine: $pass_count passed, $fail_count failed so far"
