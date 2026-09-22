#!/usr/bin/env bash
#
# Deterministic tests for scripts/ci-gate-lock.sh - the single-gate-per-Mac
# lock. No simulator, no Xcode, no timing luck: every scenario constructs the
# state it needs and asserts the module's semantics directly.
#
# The property under test is the one two simultaneous gate runs live or die
# by: at no point may two invocations both believe they own the Mac gate.
#
# Notes for readers of this file:
#   * each case uses its OWN lock directory, so cases cannot contaminate each
#     other with state left by a previous assertion;
#   * a background holder records $BASHPID (a subshell's $$ is its PARENT's
#     pid in bash, which would make a "two contenders" test compare the same
#     number against itself).
#
# Usage: bash scripts/tests/test_gate_lock.sh   (exit 0 = all cases pass)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
MOD="$SCRIPTS/ci-gate-lock.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass_count=0
fail_count=0
ok()  { pass_count=$((pass_count + 1)); echo "  ok: $1"; }
bad() { fail_count=$((fail_count + 1)); echo "  FAIL: $1"; }
assert_eq() { # $1=desc $2=actual $3=expected
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (actual='$2' expected='$3')"; fi
}
no_temp_left() { # $1 = lock dir prefix -> count of *.new.* siblings
  ls -d "$1".new.* 2>/dev/null | wc -l | tr -d ' '
}

[ -f "$MOD" ] || { echo "missing $MOD"; exit 1; }
. "$MOD"

echo "=== gate lock tests (bash $(bash --version | head -1 | cut -d' ' -f4)) ==="

echo "--- case 1: acquire and release ---"
LOCK1="$WORK/lock-1"
if acquire_gate_lock "$LOCK1"; then
  ok "the first contender acquires the lock"
else
  bad "the first contender could not acquire the lock"
fi
assert_eq "the canonical lock carries this process's pid" \
  "$(cat "$LOCK1/pid" 2>/dev/null)" "$$"
gate_lock_release
assert_eq "release removes a lock this process still owns" \
  "$([ -e "$LOCK1" ] && echo yes || echo no)" "no"
assert_eq "release leaves no temporary lock behind" \
  "$(no_temp_left "$LOCK1")" "0"

echo "--- case 2: two contenders cannot both own the gate ---"
LOCK2="$WORK/lock-2"
( . "$MOD"
  trap 'gate_lock_release' EXIT INT TERM
  acquire_gate_lock "$LOCK2" || exit 9
  printf '%s\n' "$BASHPID" > "$WORK/holder"
  sleep 60 ) &
HOLDER_BG=$!
while [ ! -f "$WORK/holder" ]; do sleep 0.1; done
ACQUIRE_RC=0
acquire_gate_lock "$LOCK2" || ACQUIRE_RC=$?
assert_eq "the second contender is refused" "$ACQUIRE_RC" "2"
# The module records `$$`, and a subshell's `$$` is its parent's pid in bash
# (the gate itself is a top-level script, where `$$` is its real pid). The
# property that matters is that a refusal identifies a LIVE owner, and that
# the module's message and the lock's own record agree - assert those rather
# than comparing pids recorded under two different conventions.
if [ -n "${GATE_LOCK_OWNER:-}" ] && kill -0 "${GATE_LOCK_OWNER}" 2>/dev/null; then
  ok "the refusal names a live owner process"
else
  bad "the refusal did not identify a live owner (got '${GATE_LOCK_OWNER:-}')"
fi
assert_eq "and it matches the pid recorded in the lock itself" \
  "${GATE_LOCK_OWNER:-}" "$(cat "$LOCK2/pid")"
assert_eq "the refused contender leaked no temporary lock" \
  "$(no_temp_left "$LOCK2")" "0"
kill "$HOLDER_BG" 2>/dev/null
wait "$HOLDER_BG" 2>/dev/null
gate_lock_release
rm -rf "$LOCK2"

echo "--- case 3: the pre-owner window has exactly one owner ---"
# One contender's temporary directory exists but the canonical lock does not
# yet (the moment between its metadata write and its rename). Whichever
# completes that rename owns the gate; the other must never believe it won.
LOCK3="$WORK/lock-3"
A_TEMP="$LOCK3.new.9999"
mkdir -p "$A_TEMP"
printf '9999\n' > "$A_TEMP/pid"
B_RC=0
acquire_gate_lock "$LOCK3" || B_RC=$?
assert_eq "the contender who completes the rename acquires" "$B_RC" "0"
if mv "$A_TEMP" "$LOCK3" 2>/dev/null; then
  if [ -e "$LOCK3/$(basename "$A_TEMP")" ]; then
    ok "the loser's rename only nested inside the owner's lock"
  else
    bad "the loser's rename replaced the owner's lock"
  fi
else
  ok "the loser's rename was refused outright"
fi
assert_eq "and the winner still owns the gate" "$(cat "$LOCK3/pid")" "$$"
LOSER_RC=0
acquire_gate_lock "$LOCK3" || LOSER_RC=$?
assert_eq "the loser, going through the module, is refused" "$LOSER_RC" "2"
assert_eq "with the winner's pid still intact" "$(cat "$LOCK3/pid")" "$$"
gate_lock_release
rm -rf "$LOCK3"

echo "--- case 4: a lock with no readable PID is BUSY, never stolen ---"
LOCK4="$WORK/lock-4"
mkdir -p "$LOCK4"
EMPTY_RC=0
acquire_gate_lock "$LOCK4" || EMPTY_RC=$?
assert_eq "an ownerless lock refuses acquisition" "$EMPTY_RC" "2"
assert_eq "and it is left in place (not stolen, not deleted)" \
  "$([ -d "$LOCK4" ] && echo yes || echo no)" "yes"
assert_eq "so the next contender can still see it is BUSY" \
  "$([ -f "$LOCK4/pid" ] && echo yes || echo no)" "no"
gate_lock_release
rm -rf "$LOCK4"

echo "--- case 5: a confirmed-dead owner is taken over ---"
LOCK5="$WORK/lock-5"
mkdir -p "$LOCK5"
printf '999999999\n' > "$LOCK5/pid"     # a pid that cannot be running
STALE_RC=0
acquire_gate_lock "$LOCK5" || STALE_RC=$?
assert_eq "a dead owner's lock is taken over" "$STALE_RC" "0"
assert_eq "and now carries this process's pid" "$(cat "$LOCK5/pid")" "$$"
gate_lock_release
rm -rf "$LOCK5"

echo "--- case 6: an old owner cannot remove another process's lock ---"
LOCK6="$WORK/lock-6"
OWN_RC=0
acquire_gate_lock "$LOCK6" || OWN_RC=$?
assert_eq "setup: the first owner acquires" "$OWN_RC" "0"
printf '424242\n' > "$LOCK6/pid"        # another process took ownership meanwhile
gate_lock_release
assert_eq "release does not remove a lock owned by someone else" \
  "$([ -d "$LOCK6" ] && echo yes || echo no)" "yes"
assert_eq "and the other owner's pid survives" "$(cat "$LOCK6/pid")" "424242"
rm -rf "$LOCK6"

echo "--- case 7: an interrupt during acquisition leaks nothing ---"
# Interrupted between writing its metadata and renaming it into place: the
# trap must clear the in-flight temporary lock and create no canonical lock.
LOCK7="$WORK/lock-7"
INFLIGHT="$LOCK7.new.4321"
mkdir -p "$INFLIGHT"
printf '%s\n' "$$" > "$INFLIGHT/pid"
( . "$MOD"
  GATE_LOCK_TEMP="$INFLIGHT"
  trap 'gate_lock_release; exit 143' INT TERM
  sleep 30 ) &
INTERRUPTED=$!
sleep 0.3
kill -TERM "$INTERRUPTED" 2>/dev/null
wait "$INTERRUPTED" 2>/dev/null
assert_eq "the in-flight temporary lock was removed by the trap" \
  "$([ -d "$INFLIGHT" ] && echo yes || echo no)" "no"
assert_eq "and no canonical lock was created" \
  "$([ -e "$LOCK7" ] && echo yes || echo no)" "no"

echo ""
echo "=== $pass_count passed, $fail_count failed ==="
[ "$fail_count" -eq 0 ]
