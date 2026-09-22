"""One-off patch: round-3 review fixes for scripts/local-ci-gate.sh."""

BS = chr(92)
NL = chr(10)

p = "scripts/local-ci-gate.sh"
text = open(p, encoding="utf-8").read()


def sub(old, new, what):
    global text
    assert old in text, what
    text = text.replace(old, new, 1)


# --- BLOCKER: job control so the group kill actually has a group -------------
sub(
    '  mkdir -p "$(dirname "$log")"\n'
    '  ( cd "$cwd" && exec "$@" ) >"$log" 2>&1 &\n'
    '  pid=$!',
    '  mkdir -p "$(dirname "$log")"\n'
    '  # Job control (set -m) puts this one background job into its OWN\n'
    '  # process group - the idiom ci-lib.sh uses for the same reason.\n'
    '  # Without it a non-interactive bash leaves the child in the SCRIPT\'s\n'
    '  # group, so `kill -- -$pid` targets a group that does not exist, fails\n'
    '  # silently, and only the direct child dies while a grandchild keeps the\n'
    '  # Simulator busy after the budget expired.\n'
    '  set -m\n'
    '  ( cd "$cwd" && exec "$@" ) >"$log" 2>&1 &\n'
    '  pid=$!\n'
    '  set +m',
    "run_bounded launch not found")

# --- the comment must match the code -----------------------------------------
sub('      # Kill the GROUP, not just the wrapper: the command runs through a\n'
    '      # subshell that execs a shell running xcrun, so a TERM to the pid\n'
    '      # alone leaves a grandchild holding the simulator after the budget\n'
    '      # expired (or after an interrupt).',
    '      # Kill the job\'s GROUP (set -m above made the child its leader) so\n'
    '      # grandchildren spawned by the command go too: a TERM to $pid alone\n'
    '      # would leave them holding the Simulator after the budget expired\n'
    '      # or after an interrupt.',
    "group-kill comment not found")

# --- the prep's terminate must be bounded like every other simctl call -------
sub(
    'udid=$(simulator_udid) && ' + BS + NL +
    '                xcrun simctl terminate "$udid" com.milim.relay >/dev/null 2>&1',
    'udid=$(simulator_udid) && ' + BS + NL +
    '                # Bounded like every other simctl call: a wedged' + NL +
    '                # CoreSimulatorService hangs simctl indefinitely, and' + NL +
    '                # this runs at every lane boundary.' + NL +
    '                bounded_run 60 xcrun simctl terminate "$udid" com.milim.relay',
    "prep terminate not found")

# --- label the repeat-retry prime so its logs do not collide -----------------
sub(
    '                simulator_prime' + NL +
    '                if run_lane unit "repeat-$rcls-$iteration-retry"',
    '                simulator_prime "$rcls-$iteration-retry"' + NL +
    '                if run_lane unit "repeat-$rcls-$iteration-retry"',
    "repeat prime call site not found")

# --- the registry append must not be silent ---------------------------------
sub(' >> "$SHA_REGISTRY" 2>/dev/null || true',
    ' >> "$SHA_REGISTRY" 2>/dev/null || \\\n'
    '  echo "local-ci-gate: warning: could not record the result for $SHA in "\n'
    '  "the SHA registry; it lives at $RUN_DIR/gate-result.json" >&2',
    "registry append not found")

open(p, "w", encoding="utf-8", newline="\n").write(text)
print("round-3 shell fixes applied")
