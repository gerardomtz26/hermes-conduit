#!/usr/bin/env bash
#
# Single-gate-per-Mac lock for scripts/local-ci-gate.sh.
#
# Two concurrent xcodebuild/test chains on one Mac corrupt each other's
# Simulator state, so at no point may two invocations both believe they own
# the gate. This module makes acquisition structural rather than a sequence
# of check-then-act steps:
#
#   1. a uniquely named TEMPORARY lock directory is created and its PID and
#      owner metadata are written into it FIRST - the canonical location never
#      exists without metadata in it, so a contender can never observe a
#      lock it cannot interpret;
#   2. the temp directory is renamed into the canonical location (an atomic
#      rename into an absent path - a rename onto a NON-empty directory
#      fails, which is what makes a concurrent second renamer lose);
#   3. the acquisition is then VERIFIED: only the pid that is readable at the
#      canonical path owns the lock. Whoever lost the race cleans up and
#      reports BUSY - it never believes it owns the Mac.
#
# Semantics:
#   * a lock exists with NO readable pid        -> BUSY (never stolen: it is
#                                                  not provably stale)
#   * a readable pid that is confirmed dead     -> steal (rename aside is not
#                                                  needed: the loser of the
#                                                  subsequent rename loses)
#   * cleanup removes the canonical lock ONLY IF its pid is still ours
#   * the trap must be installed before acquisition can leak state
#
# Callers install their EXIT/INT/TERM traps BEFORE calling acquire_gate_lock.
# Bash 3.2 compatible (macOS /bin/bash) and `set -u` safe.

# Last acquired temp-lock path for this process (so cleanup can also remove
# an in-flight temp directory when an interrupt lands mid-acquisition).
GATE_LOCK_TEMP=""
GATE_LOCK_HELD=0
GATE_LOCK_HELD_DIR=""
GATE_LOCK_OWNER=""

gate_lock_release() {
  # Never remove a lock we do not own: if another process took ownership
  # between our acquisition and this release, its pid must survive.
  local owner=""
  # An interrupt during acquisition leaves a temp directory: clear ours first,
  # whether or not we ever took ownership (otherwise a mid-acquisition trap
  # returns here and leaks it).
  if [ -n "$GATE_LOCK_TEMP" ] && [ -d "$GATE_LOCK_TEMP" ]; then
    rm -rf "$GATE_LOCK_TEMP" 2>/dev/null || true
    GATE_LOCK_TEMP=""
  fi
  [ "$GATE_LOCK_HELD" -eq 1 ] || return 0
  owner="$(cat "$GATE_LOCK_HELD_DIR/pid" 2>/dev/null || true)"
  if [ -n "$owner" ] && [ "$owner" = "$$" ]; then
    rm -rf "$GATE_LOCK_HELD_DIR" 2>/dev/null || true
  fi
  # An interrupt during acquisition leaves a temp directory: clean ours up.
  if [ -n "$GATE_LOCK_TEMP" ] && [ -d "$GATE_LOCK_TEMP" ]; then
    rm -rf "$GATE_LOCK_TEMP" 2>/dev/null || true
  fi
  GATE_LOCK_HELD=0
  GATE_LOCK_HELD_DIR=""
  GATE_LOCK_TEMP=""
  return 0
}

# Returns: 0 acquired, 2 BUSY (another live owner or no readable pid),
#          1 could not create the temp directory.
acquire_gate_lock() { # $1 = canonical lock dir
  local canonical="$1" temp holder
  temp="$canonical.new.$$"
  GATE_LOCK_TEMP="$temp"
  rm -rf "$temp" 2>/dev/null || true
  if ! mkdir -p "$temp" 2>/dev/null; then
    GATE_LOCK_TEMP=""
    return 1
  fi
  # Metadata BEFORE the canonical location can exist: a lock a contender
  # cannot interpret is never left behind.
  printf '%s\n' "$$" > "$temp/pid" || { rm -rf "$temp"; GATE_LOCK_TEMP=""; return 1; }

  if [ -e "$canonical" ]; then
    holder="$(cat "$canonical/pid" 2>/dev/null || true)"
    if [ -z "$holder" ]; then
      # No readable pid: BUSY. It is not provably stale, and stealing a lock
      # we cannot explain is how two gates end up on one Mac.
      rm -rf "$temp"; GATE_LOCK_TEMP=""
      GATE_LOCK_OWNER=""
      return 2
    fi
    case "$holder" in
      *[!0-9]*)
        # Corrupt pid content is not a provably dead owner: same rule as a
        # missing one - BUSY, never stolen.
        rm -rf "$temp"; GATE_LOCK_TEMP=""
        GATE_LOCK_OWNER=""
        return 2
        ;;
    esac
    if kill -0 "$holder" 2>/dev/null; then
      rm -rf "$temp"; GATE_LOCK_TEMP=""
      GATE_LOCK_OWNER="$holder"
      return 2
    fi
    # Confirmed dead owner: steal it ATOMICALLY by renaming the stale lock
    # aside, then re-checking what we just moved. A destructive `rm -rf` here
    # is the classic check-then-act race: a contender can pass the liveness
    # check above, let the OTHER process complete its claim, and then delete
    # that live lock - two owners, one Mac, corrupt Simulator state. Exactly
    # one process can move the canonical directory aside, so the loser of that
    # rename simply fails, and a moved-away lock that turns out to be LIVE is
    # put back before we refuse.
    # Unique per attempt: a leftover aside from a killed steal must never be
    # THIS steal's target (mv into an existing directory nests instead of
    # failing, and the cleanup would then delete a live lock alongside the
    # stale one).
    local aside="$canonical.stale.$$.$RANDOM.$(date +%s)"
    if ! mv "$canonical" "$aside" 2>/dev/null; then
      # Another contender moved it first; its claim path decides the outcome.
      rm -rf "$temp"; GATE_LOCK_TEMP=""
      GATE_LOCK_OWNER=""
      return 2
    fi
    holder="$(cat "$aside/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      # The directory we moved aside holds a LIVE owner (it replaced the
      # stale lock mid-steal): restore it and refuse.
      mv "$aside" "$canonical" 2>/dev/null || true
      rm -rf "$temp"; GATE_LOCK_TEMP=""
      GATE_LOCK_OWNER="$holder"
      return 2
    fi
    rm -rf "$aside" 2>/dev/null || true
  fi

  # Atomic claim: rename onto an absent path succeeds once; onto a path that
  # became non-empty in between it fails (rename(2) semantics), so exactly one
  # contender's temp directory becomes the canonical lock.
  if ! mv "$temp" "$canonical" 2>/dev/null; then
    if [ -d "$temp" ] && [ -d "$canonical/$(basename "$temp")" ]; then
      # mv nested it (the target existed as a directory): nobody claimed it.
      rm -rf "$canonical/$(basename "$temp")" 2>/dev/null || true
    fi
    rm -rf "$temp" 2>/dev/null || true
    GATE_LOCK_TEMP=""
    return 2
  fi

  # Verify: only the pid readable at the canonical path owns the gate.
  # GATE_LOCK_TEMP is kept set until ownership is confirmed, so an interrupt
  # between the rename and GATE_LOCK_HELD=1 still releases this lock instead
  # of leaking it.
  holder="$(cat "$canonical/pid" 2>/dev/null || true)"
  if [ "$holder" != "$$" ]; then
    # mv nests into an existing directory target (BSD/GNU behavior): if ours
    # ended up inside the canonical lock, it is not ours to keep.
    rm -rf "$canonical/$(basename "$temp")" 2>/dev/null || true
    rm -rf "$temp" 2>/dev/null || true
    GATE_LOCK_TEMP=""
    return 2
  fi
  GATE_LOCK_HELD=1
  GATE_LOCK_HELD_DIR="$canonical"
  GATE_LOCK_TEMP=""
  return 0
}
