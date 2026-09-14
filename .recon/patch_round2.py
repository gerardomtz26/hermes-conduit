"""Round-2 patcher: fix wedge recovery bookkeeping + wedge test stubs."""

import io

# --- ci-test-lane.sh: record infra-recovered classes properly -----------------
path = r"C:\dev\hermes-conduit-ci-audio\scripts\ci-test-lane.sh"
text = io.open(path, encoding="utf-8").read()

old = '''  if [ -z "$AFFECTED_CLASSES" ]; then
    return 1
  fi
  COREAUDIO_RECOVERY=1'''
new = '''  if [ -z "$AFFECTED_CLASSES" ]; then
    return 1
  fi
  COREAUDIO_RECOVERY=1
  # Infra-recovery bookkeeping: the affected classes ran twice and the retry
  # rescued an environment wedge (not a test flake) - reported through the
  # existing lane-result field, never as a clean pass.
  for wedge_cls in $AFFECTED_CLASSES; do
    echo "$wedge_cls" >> "$INFRA_RECOVERED_LINES"
  done'''
assert old in text, "recovery bookkeeping anchor missing"
text = text.replace(old, new)

old = '''    echo "::warning::lane $LANE passed after the CoreAudio wedge recovery on a clean simulator - infrastructure recovery, not a test flake; affected classes: $(printf '%s' "$AFFECTED_CLASSES" | tr ' ' ',')"
    finish_lane "pass" '[{"n": 1, "mode": "lane", "status": "audio-wedge"}, {"n": 2, "mode": "audio-retry", "status": "passed"}]' \\
      "$(printf '%s,' $AFFECTED_CLASSES | sed 's/,$//')" 0'''
new = '''    echo "::warning::lane $LANE passed after the CoreAudio wedge recovery on a clean simulator - infrastructure recovery, not a test flake; affected classes: $(printf '%s' "$AFFECTED_CLASSES" | tr ' ' ',')"
    finish_lane "pass" '[{"n": 1, "mode": "lane", "status": "audio-wedge"}, {"n": 2, "mode": "audio-retry", "status": "passed"}]' "" 0'''
assert old in text, "finish_lane pass-call anchor missing"
text = text.replace(old, new)

# Cosmetic: the wedge-pruning edit left the else at UI indentation.
old = '''      done
      else
        # A green unit lane deletes its attempt bundles - EXCEPT when a'''
new = '''      done
    else
      # A green unit lane deletes its attempt bundles - EXCEPT when a
      # CoreAudio wedge recovery ran: the attempt-1 bundle is the only
      # evidence of the wedge, and the attempt-2 bundle documents the
      # recovery.
      if [ "$COREAUDIO_RECOVERY" -eq 0 ]; then
        rm -rf "$RESULT_DIR"/attempt-*.xcresult "$RESULT_DIR"/iso-*.xcresult 2>/dev/null || true
      fi
    fi'''
assert old in text, "pruning indent anchor missing"
text = text.replace(old, new)
old = '''      if [ "$COREAUDIO_RECOVERY" -eq 0 ]; then
          rm -rf "$RESULT_DIR"/attempt-*.xcresult "$RESULT_DIR"/iso-*.xcresult 2>/dev/null || true
        fi
      fi
    fi
  fi
  exit "$4"'''
new = '''      if [ "$COREAUDIO_RECOVERY" -eq 0 ]; then
        rm -rf "$RESULT_DIR"/attempt-*.xcresult "$RESULT_DIR"/iso-*.xcresult 2>/dev/null || true
      fi
    fi
  fi
  exit "$4"'''
if old in text:
    text = text.replace(old, new)
io.open(path, "w", encoding="utf-8", newline="\n").write(text)
print("ci-test-lane.sh patched")

# --- test_lane_runner.sh: stub fixes ------------------------------------------
path = r"C:\dev\hermes-conduit-ci-audio\scripts\tests\test_lane_runner.sh"
text = io.open(path, encoding="utf-8").read()

old = '''if [ "$n" -gt 1 ]; then
  write_doc "$FAKE_CANNED" "VoiceTests:Failed" "HealthyTests:Passed"
  [ "$FAKE_WEDGE_A1" = "signature" ] && emit_signature
  echo "Test Case failed (stub)"
  exit 65
fi'''
new = '''if [ "$n" -gt 1 ]; then
  # Attempt 1 covers the whole lane: every class named in $FAKE_WEDGE_FAIL_CLASSES
  # (default: the first filter) fails, the rest pass.
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
  if [ -z "$FAKE_WEDGE_FAIL_CLASSES" ]; then
    first=$(printf '%s\\n' "$@" | grep 'only-testing:' | head -1 | sed 's|.*/||')
    pairs="$first:Failed $pairs"
    pairs=$(printf '%s\\n' "$pairs" | sed "s/ $first:Passed//")
  fi
  write_doc "$FAKE_CANNED" $pairs
  [ "$FAKE_WEDGE_A1" = "signature" ] && emit_signature
  echo "Test Case failed (stub)"
  exit 65
fi'''
assert old in text, "wedge stub attempt-1 anchor missing"
text = text.replace(old, new)

# The stub must create the bundle dirs a real xcodebuild would.
old = '''#!/bin/bash
n=$(printf '%s\\n' "$@" | grep -c -- '-only-testing:' || true)
echo "inv:filters=$n" >> "$INVOCATION_LOG"
emit_signature() {'''
new = '''#!/bin/bash
for a in "$@"; do
  case "$a" in *.xcresult) mkdir -p "$a" ;; esac
done
n=$(printf '%s\\n' "$@" | grep -c -- '-only-testing:' || true)
echo "inv:filters=$n" >> "$INVOCATION_LOG"
emit_signature() {'''
assert old in text, "wedge stub mkdir anchor missing"
text = text.replace(old, new)

# Case D: BOTH classes fail, one outside the inventory.
old = '''begin_case "out-of-inventory failure voids the wedge path" "$WORK/w4"
export INVOCATION_LOG="$WORK/w4-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_WEDGE_A1="signature" FAKE_WEDGE_RETRY="pass"
run_lane "VoiceTests,OtherTests" 300 unused 3'''
new = '''begin_case "out-of-inventory failure voids the wedge path" "$WORK/w4"
export INVOCATION_LOG="$WORK/w4-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_WEDGE_A1="signature" FAKE_WEDGE_RETRY="pass"
export FAKE_WEDGE_FAIL_CLASSES="VoiceTests OtherTests"
run_lane "VoiceTests,OtherTests" 300 unused 3
export FAKE_WEDGE_FAIL_CLASSES=""'''
assert old in text, "case D anchor missing"
text = text.replace(old, new)

# Case E: the weak-signature stub must also write a proper failed doc.
old = '''cat > "$STUBS/xcodebuild" <<'STUB'
#!/bin/bash
n=$(printf '%s\\n' "$@" | grep -c -- '-only-testing:' || true)
echo "inv:filters=$n" >> "$INVOCATION_LOG"
echo "2026-09-14 00:00:00.000 Conduit[9:9] [aurioc]            AURemoteIO.cpp:1135  failed: -10851 (enable 1)"
echo "Test Case failed (stub)"
exit 65
STUB'''
new = '''cat > "$STUBS/xcodebuild" <<'STUB'
#!/bin/bash
for a in "$@"; do
  case "$a" in *.xcresult) mkdir -p "$a" ;; esac
done
cat > "$FAKE_CANNED" <<'DOC'
{"testNodes": [{"nodeType": "Test Plan", "name": "Conduit", "result": "Passed",
  "children": [{"nodeType": "Unit test bundle", "name": "ConduitTests", "result": "Passed",
    "children": [{"nodeType": "Test Suite", "name": "VoiceTests", "result": "Failed",
      "children": [{"nodeType": "Test Case", "name": "testC()", "result": "Failed",
        "durationInSeconds": 0.1}]}]}]}]}
DOC
n=$(printf '%s\\n' "$@" | grep -c -- '-only-testing:' || true)
echo "inv:filters=$n" >> "$INVOCATION_LOG"
echo "2026-09-14 00:00:00.000 Conduit[9:9] [aurioc]            AURemoteIO.cpp:1135  failed: -10851 (enable 1)"
echo "Test Case failed (stub)"
exit 65
STUB'''
assert old in text, "case E stub anchor missing"
text = text.replace(old, new)
io.open(path, "w", encoding="utf-8", newline="\n").write(text)
print("test_lane_runner.sh patched")
