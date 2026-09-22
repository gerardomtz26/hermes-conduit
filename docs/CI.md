# CI v2 — timing-aware dynamic test lanes

This document describes the Conduit CI architecture that replaced the static
`unit-a…unit-d` shard system (see PR history for the migration). The pipeline
still runs the complete XCTest suite on every PR; nothing is skipped,
quarantined, or moved to a nightly gate.

## Two gates, two jobs

Conduit is tested by two independent gates, and they answer different
questions:

| Gate | Where | Scope | What a green result means |
|---|---|---|---|
| **GitHub-hosted CI** (this document) | GitHub runners, public/fork PRs included | The complete suite, sharded into dynamic lanes | The commit compiles and the suite passes on a clean machine |
| **Local exhaustive gate** (`scripts/local-ci-gate.sh`) | Our own Mac, over SSH, outside GitHub's runner system | The complete suite, plus an explicit repeat policy, plus the cheap static checks | A **trusted** commit is correct: see [Local exhaustive gate](#local-exhaustive-gate-mac-outside-github) |

**A local gate result is valid only for the exact commit SHA it reports.**
Any other SHA — a branch name that moved, a later commit, "essentially the
same" tree — invalidates the result. The gate is the authority that a release
head is certified with; the hosted pipeline stays as it is today (its slim
redesign is a separate, later change), and remains what guards arbitrary
public and fork PRs.

## Architecture

```
                 test inventory (source scan)
                          |
  timing history (Actions cache) -> plan-tests.py
             (LPT timing balance, watchdog math)
             |                         |
   plan.json / matrices       CI tooling self-test (ubuntu;
   (unit + UI)                planner tests, lane-runner state
             |                machine, destination lookup - runs
             |                concurrently, never delays the build)
      build-for-testing (once, workspace-anchored DerivedData)
             |
      .xctestrun + products artifact
             |
   +---------+---------+---------+
   v         v         v         v
 unit-1    unit-2    ...     ui-1   ui-2   ui-3 ...
 (test-without-building from the SHARED products;
  measured watchdogs. Units execute each lane as
  SEQUENTIAL small xcodebuild batches (<= 7 classes
  per invocation, fresh xcodebuild process per batch,
  same runner/Simulator; native flake retry inside
  every batch; one batch-level retry for a watchdog
  stall or infrastructure wedge). UI runs each shard
  as ONE batched invocation with method-precise retry
  and a per-class diagnosis fallback)
   |         |         |         |
   +---------+----+----+---------+
                  v
          report job -> GitHub Step Summary
                  v
        timing-history-update (main only, EWMA)
```

### Jobs

| Job | Runner | Purpose |
|---|---|---|
| `plan` | ubuntu | Discovery validation + lane generation (unit AND UI matrices). Cheap guard before any macOS minutes are spent. |
| `self-test` | ubuntu | CI-tooling regression suites (planner tests, lane-runner state machine, destination lookup, gate/timing contracts) - concurrent with `build`, so the minutes-long bash state-machine suite never delays macOS work nor risks the plan job's timeout. |
| `build` | macos-26 | `build-for-testing` exactly once; `.xctestrun` portability audit; uploads products. |
| `unit` (matrix) | macos-26 | One dynamically planned lane per matrix entry, executed as sequential small xcodebuild batches (see below). |
| `ui` (matrix) | macos-26 | Dynamically planned UI lane; runs each shard as ONE batched invocation (see below). |
| `report` | ubuntu | Aggregates lane results into the CI Test Report step summary. |
| `timing-history-update` | ubuntu | Main-only: merges fresh timings into the history cache (EWMA). |

The self-test job's timeout hierarchy is load-bearing: each synthetic hang
in the state-machine suite is watchdog-killed within a 1-6 s test budget <
the suite's Python wrapper subprocess cap (480 s; the suite measures
~3.5-4 min on macOS) < the job's own 12-minute ceiling - GitHub must never
be the first layer to kill a regression suite.

## Test discovery

`scripts/plan-tests.py` discovers XCTestCase classes by scanning
`ConduitTests/` and `ConduitUITests/` sources:

* A class is a **test class** if it directly inherits `XCTestCase` (repo
  convention) or is named `*Tests` and inherits `XCTestCase` transitively.
  This matches the XCTest runtime inventory exactly (verified against
  `xcodebuild -enumerate-tests`: 67 unit + 1 UI classes).
* Classes that merely resolve to `XCTestCase` without the above (mocks such
  as `MockGateway`, `FakeSocket`) enumerate zero tests and are excluded from
  lanes - the same behavior as the old static shard guard.
* Target membership comes from the **directory** (`ConduitTests/` vs
  `ConduitUITests/`), never from the class name.
* Duplicates, and `*Tests`-named classes that do not resolve to
  `XCTestCase`, are hard errors. A new test class can never silently miss CI.

## Dynamic lanes

Unit classes are balanced with **longest-processing-time-first** (LPT) over
per-class duration estimates, with deterministic tie-breaking (estimate
descending, then class name). Lane count is derived, not fixed, and accounts
for the fixed cost of an xcodebuild invocation:

```
modeled wall(n) = invocation_overhead_s (240s) + heaviest LPT lane load
lanes = smallest n in [1, 8] with modeled wall(n) within 120s of the best
        achievable wall, capped by class count
```

Every lane pays the fixed startup/finalization cost, but lanes run in
parallel - so adding a lane only rebalances execution while multiplying paid
invocations. A lane is spawned only when it buys more than the 120 s wall
tolerance. Splitting 200 s of tests into two 5-minute jobs (when the
invocation overhead is several minutes) is a net loss; a heavy outlier class
that dominates every possible split consolidates the suite into fewer lanes.
Predicted imbalance is reported in the plan summary and the CI Test Report.

### Sequential unit batches

Large single unit invocations repeatedly watchdog-stalled on hosted
macos-26 (diagnostic chain: PRs #178-#183 - audio-specific hypotheses did
not hold, a 30-class lane cap did not help, the reproducing set narrowed to
14 classes, and those same 14 completed as two 7-class invocations run
back-to-back inside ONE job on ONE runner with ONE Simulator session: only
the `xcodebuild`/XCTest/testhost process was fresh between them). Unit
lanes therefore execute their planner-assigned classes as **sequential
small batches**:

* `plan-tests.py` chunks each lane's class list, **in its stored (LPT)
  order**, into batches of at most
  `MAX_UNIT_CLASSES_PER_XCODEBUILD_BATCH = 7` classes - purely mechanical,
  no regrouping by subsystem - and prices every batch with its own watchdog
  (`max(600s, ceil((invocation_overhead 240s + predicted execution) x
  2.5))`). The batch layout + budgets travel with the lane matrix
  (`--batches-json`) and the runner refuses to start unless the batches
  exactly reproduce the lane's class order; the planner is the single
  source of that policy.
* A lane may not chain more than `MAX_UNIT_BATCHES_PER_JOB = 4` sequential
  batches inside one GitHub job. The cap is on BATCHES per job, not on an
  arbitrary "safe class count": the planner verifies the ACTUAL LPT
  assignment (`ceil(lane classes / 7) <= 4` per lane) and increments the
  lane count - never lowering what timing-aware selection chose - until
  every lane fits, failing planning closed if the configured lane bounds
  make the policy unsatisfiable. This keeps unit wall time in the 10-20
  minute range: batches run concurrently across hosted Macs instead of
  serially on one. Watchdog budgets are deliberately untouched by this
  policy (one variable per change). The policy bounds the suite at
  `max_lanes x unit_max_batches_per_job x 7` classes (224 with defaults):
  beyond that, planning fails closed loudly and `MAX_LANES` or the batch
  policy must be raised - the planner warns as the lane count approaches
  the bound.
* Each batch runs as its own fresh `xcodebuild test-without-building`
  invocation on the same runner and the same Simulator session - **no
  erase or reset between successful batches** (the fresh process is the
  recovery boundary; a fresh hosted runner is not needed).
* Recovery is batch-level, exactly once per batch: a watchdog stall retries
  THAT batch after a bounded simulator shutdown (NO erase); an
  infrastructure wedge (nonzero exit, KNOWN zero failing tests) retries it
  after the historical erase. Real test failures (after the native
  in-invocation retry) and unclassifiable results are never retried - they
  fail the lane on that batch. A second stall fails the lane with the batch
  named (`hung_batch`).

### Parallel UI lanes

UI classes are balanced with the same LPT algorithm and the same overhead-
aware lane selection (bounds 3-4 instead of 1-8, so normal PR wall clock is
governed by the slowest UI shard rather than the sum of the whole UI suite).
Today's ~22 minutes of cumulative UI work lands on 3 lanes of roughly 7-8
predicted minutes each. The count scales out automatically if the UI suite
grows (and shrinks if it drops below 3 classes).

### Batched UI shards, per-class diagnosis

On the healthy path a UI shard runs **all of its classes in ONE `xcodebuild
test-without-building` invocation** from the shared build products (the app
is never rebuilt), under a watchdog equal to the sum of the planner's
per-class budgets. A successful shard therefore pays Xcode/CoreSimulator/
test-session startup once instead of once per class, while per-class timing
history still comes from the shared extraction.

Recovery never lets ordinary-failure retries re-execute healthy work:

* **Ordinary test failures** retry ONLY the non-passing tests (any final
  result other than Passed) in one follow-up invocation - exact
  `Target/Class/testMethod` filters when the xcresult identifies them, the
  failing class otherwise - and only when every assigned class actually ran
  (a batch that aborted before a class started - or an exit-0 batch whose
  xcresult lacks a class's record - falls through to diagnosis below, so
  unexecuted classes can never be retried into a green lane). Successful
  classes are never re-executed, and a retry pass is reported as a
  runner-level FLAKE (with both attempt result bundles kept), never hidden
  as a clean pass.
* **Watchdog timeout / infrastructure wedge** of the batch cannot be
  attributed to a class: the simulator is erased and the affected classes
  re-run through **per-class diagnosis** - each class its own invocation
  under its own planned watchdog, with the same targeted-retry and hang
  attribution rules as before. (Diagnosis necessarily re-runs classes that
  already passed inside a killed batch - a dead invocation leaves no
  trustworthy per-class result.) A class that hangs twice names the culprit
  (`hung_class` in the lane result) and stops the shard; a class whose
  retry fails again as an infrastructure failure is recorded as a persistent
  infrastructure failure and fails the lane while the remaining classes
  still run after a clean simulator reset; only an untrusted recovery stops
  a shard without executing the remaining classes.

## Timing data

* `scripts/test-timings.json` - checked-in **baseline fallback** (seconds per
  class), seeded from a full-suite xcresult measured on local hardware.
  Unseen classes get a conservative default (20 s) so a batch of new tests
  cannot all pile into one lane.
* **Timing history** - living estimates kept in a GitHub Actions cache
  (`timing-history-v1-*`). Only successful main runs write it; PR runs
  consume it read-only. Missing, corrupt, or stale history simply falls back
  to the baseline; planning correctness never depends on it.
* `scripts/update-timing-history.py` merges fresh per-class durations with an
  EWMA (`updated = 0.75 * previous + 0.25 * observed`), clamps extreme
  outliers to 5x the previous estimate, takes first observations verbatim,
  and prunes entries for classes that no longer exist.

## Build-once artifact fanout

The `.xctestrun` file embeds absolute paths. Instead of rewriting them
fragilely, the build uses a **workspace-anchored DerivedData path**
(`$GITHUB_WORKSPACE/ci-derived-data`, i.e.
`/Users/runner/work/<repo>/<repo>/ci-derived-data`), which is byte-identical
on every GitHub-hosted runner of this repository. The whole `Build/` tree is
uploaded as an artifact and each lane restores it to the same absolute path
before running `test-without-building` - no compilation downstream.

`plan-tests.py audit-xctestrun` fails the run if any absolute path inside the
generated `.xctestrun` points outside the workspace root (or outside known
system locations), so non-portable products are caught at build time, not at
lane time. If Xcode ever produces inherently non-portable products, the audit
is the documented tripwire: revert to per-lane `build-for-testing` and keep
the rest of CI v2.

## Failure domains

1. **Ordinary test failures** never rerun healthy work. Every unit batch
   runs with Xcode-native flake retry (`-retry-tests-on-failure
   -test-iterations N`), which re-executes only the failing tests; if
   failures survive those iterations the LANE FAILS on that batch - no
   batch-level retry masquerades as recovery, and earlier batches keep
   their recorded passes. A failing UI batch gets one **targeted retry of
   exactly the non-passing tests** (methods when the xcresult identifies
   them, the class otherwise); if the retry passes, the classes involved
   are reported as runner-level flakes and the lane continues.
2. **Unclassifiable failure** - if an invocation exits nonzero and the
   XCTest result cannot be classified (timing/result extraction failed),
   the lane FAILS immediately (the batch fails its lane; later batches are
   recorded as `not_run`). Timing extraction is best-effort and must never
   decide test correctness, so an unclassifiable failure is never retried
   into a green lane.
3. **Infrastructure failure** - an invocation that exits nonzero with a
   KNOWN zero failing-test count (simulator crash, runner exit) gets
   exactly one bounded recovery. Units retry THAT BATCH once after the
   historical erase (recovery scoped to the batch instead of the whole
   lane); a second infrastructure failure fails the lane with the batch
   named. A UI batch cannot attribute a wedge to a class, so it erases the
   simulator and re-runs the affected classes through per-class diagnosis.
   If a class fails AGAIN as an infrastructure failure there, it is
   recorded as a **persistent infrastructure failure** and the lane fails -
   but the remaining classes still run after a clean simulator reset,
   because the culprit is fully identified and a wedge must not suppress
   otherwise-independent UI coverage. If that recovery itself cannot be
   trusted (erase failed, UDID unresolvable, boot never completed), later
   results would be misleading: the lane stops there and the remaining
   classes are recorded as `not_diagnosed`. A retry that times out falls
   through to hang handling (4).
4. **Hang / timeout** - a watchdog kill is positive identification of a
   hang. Units retry THAT BATCH once with a fresh xcodebuild process on the
   same runner and Simulator (bounded shutdown only - NO erase; the
   fresh-process boundary IS the recovery, per the sequential-invocation
   diagnostic). A second stall fails the lane with the batch as the
   identified culprit (`hung_batch` in the lane result); later batches are
   recorded as `not_run` so unexecuted tests stay visible. A UI batch
   timeout cannot name the hung class, so it erases and enters per-class
   diagnosis; a class that hangs twice names the hung class (`hung_class`
   in the lane result), fails the lane, and later classes are recorded as
   `not_diagnosed`. Recovery-to-green is only legitimate when the retried
   batch or class completed successfully.

### Destination readiness gate

The build job pins one known simulator name (`SIMULATOR_NAME`, no `simctl`
enumeration on the happy path). Fresh hosted runners occasionally reach the
build step before CoreSimulator has settled its device pairs; xcodebuild then
fails destination resolution with an **empty** available-destinations list
("Unable to find a device matching the provided destination specifier") and
every downstream lane is skipped. Before invoking xcodebuild,
`ci-build-for-testing.sh` now runs `wait_for_destination_device`
(`ci-lib.sh`): a bounded poll (default 180 s, `DESTINATION_SETTLE_TIMEOUT_S`)
of `simctl list devices available` that absorbs the settlement race and, if
the pinned device never appears, fails fast with the full device/runtime
inventory instead of a misleading xcodebuild error. The gate never
substitutes another device for the pinned name - an image refresh that
renames devices still fails, with an explicit diagnostic. The lookup behind
the gate (`simulator_udid`) is also OS-qualified: when `SIMULATOR_OS` is
set, only a device with the pinned name on that exact runtime satisfies it
(exact numeric-component match, so `26.1` never matches `26.10`), with no
fallback to another runtime - the resolved UDID always belongs to the
destination xcodebuild will use. `SIMULATOR_OS` must be numeric dotted
components (e.g. `26.0`); xcodebuild-only values such as `latest` are not
supported by the pin and fail the gate.

The resolved UDID is also what every invocation actually targets:
`build_destination` emits `platform=iOS Simulator,id=<UDID>,arch=arm64`
(falling back to the `name=` form only when the UDID cannot be resolved; the
arch is `SIMULATOR_ARCH`-overridable), so build and lane jobs can never
disambiguate a name that matches several runtimes and never have to choose
between the arm64 and Rosetta-x86_64 candidates every Apple Silicon
simulator registers - the source of the "multiple matching destinations"
warning, where xcodebuild silently uses the first match and can bypass the
OS pin.

## Watchdogs

Unit lanes execute as sequential batches; **`plan-tests.py` is the single
authority for the batch layout and every batch's budget** (the runner
refuses to start unless the batches reproduce the lane's class order):

```
unit_batch_timeout = max(600s, ceil((invocation_overhead 240s + predicted x 2.5)))
                   # computed in plan-tests.py only, per batch
```

The lane watchdog reported in the plan is the SUM of its batch budgets (the
total the lane may consume across invocations), and the outer GitHub job
ceiling is
`ceil((2 x sum(batch budgets) + n_batches x 600s recovery + (2 x n_batches
+ 1) x 300s extraction + 1200s) / 60)` minutes - every batch burning its
budget twice (attempt 1 plus its single batch-level retry), each retry
paying one bounded simulator recovery, every attempt's timing extraction
wedging to the xcresulttool subprocess bound, plus setup/download slack -
so the ceiling can never preempt legitimate in-script recovery (the
per-batch watchdogs inside the runner are the real enforcement; GitHub's
own 6-hour hosted-runner cap is the only thing above it).

UI classes each get their **own** watchdog, planned per class from the same
timing data that balances the lanes: the shard's batched invocation is
priced at the **sum** of those budgets, and the same table enforces every
per-class diagnosis fallback invocation. **`plan-tests.py` is the single
authority for this policy**: every UI lane receives an explicit budget table
(`--class-timeouts`) and the runner refuses to start unless it covers every
assigned class - there is no fallback formula in `ci-test-lane.sh` to drift
from the planner:

```
ui_class_timeout = max(420s, ceil(estimate x 3.0))   # computed in plan-tests.py only
```

- the floor carries the fixed xcodebuild/automation-session/simulator
  overhead that dominates small classes (~2.5 min before the first test +
  ~1 min of xcresult finalization on macos-26, measured - see the run #500
  history for why this floor must not be lower), plus headroom for the
  targeted retry of a legitimately slow class;
- the 3x multiplier gives slow-but-healthy classes proportional room on
  slower runners without letting any single class hold a lane hostage;
- a class normally taking 2-4 minutes is caught in ~7-17 minutes if it
  hangs, instead of the old single 2861s (~48 min) suite-level watchdog;
- estimates come from timing history (EWMA, outlier-clamped), so one
  anomalous run cannot inflate a class's watchdog;
- UI lane ceilings are `sum(per-class budgets)` - the batched shard
  invocation watchdog - and the outer GitHub job ceiling is
  `ceil((4 x sum + (n_classes + 1) x 600s + (2 x n_classes + 1) x 300s
  + 1200s) / 60)` minutes. Two reachable worst paths: the batch times out
  and per-class diagnosis follows (batch 1x + diagnosis 2x = 3x), or the
  batch completes with failures in every class, its targeted retry (a full
  budget sum) times out, and diagnosis of the retried classes follows
  (1x + 1x + 2x = 4x) - the latter prices the ceiling. Each failing class
  additionally pays one bounded erase/reboot recovery, and each attempt's
  timing extraction can wedge to the xcresulttool bound, plus setup slack.

**Finalize grace.** When a watchdog expires but the log already carries
xcodebuild's terminal result marker (`** TEST EXECUTE SUCCEEDED/FAILED **`),
the test session has ENDED and the process is only writing its xcresult.
Killing there converts a completed run into a timeout (run #500) and can
truncate the result bundle, so the deadline is extended once by a bounded
`XCODEBUILD_FINALIZE_GRACE_S` (default 180 s) and the process may exit on its
own. The verdict still comes exclusively from the real exit status - the
marker never declares success on its own - and a process that outlives the
grace is killed and classified as a timeout exactly as before.

Every `simctl` operation is deadline-bounded; the process-group watchdog kill
(xcodebuild + xctest + simulator agents) is preserved from the previous
architecture.

## Observability

Every lane uploads a `lane-<lane-name>` artifact (e.g. `lane-ui-1`,
`lane-unit-3`) containing `lane-result.json` (status, attempt chain, hung
class / hung batch, batch-level outcomes, retried classes, predicted vs
actual), the merged per-class timings (`observations.json`) and per-test
attempt details (`detail.json`), and a `logs/` directory. Unit lanes log
every batch invocation (`logs/batch-<n>-a<attempt>.log`); UI lanes log and
name every invocation by class and attempt
(`logs/class-<class>-a<N>.log`); both keep per-attempt `.xcresult` bundles
for failed lanes, and on a green lane preserve both attempt bundles of any
batch/class that needed its retry. The CI Test Report renders a
**"Unit lane batches"** section (`batch 3/5 watchdog -> retry PASS`) so a
stalled batch never requires reading raw Actions logs. Timing history is
recorded per class (UI included), which is what lets the planner balance
lanes and price batch watchdogs from real runtimes.

## CI Gate (branch protection)

The `CI Gate` job is the single stable required status check for branch
protection. It passes only when:

* `plan`, `build`, `self-test` and every dynamic `unit` lane succeed, and
* every dynamic `ui` lane succeeds (or is skipped entirely because the repo
  contains no UI tests).

The number of dynamic unit AND UI lanes can change between runs, so lane
jobs must never be pinned individually. Configure repository branch
protection to require **CI Gate**, replacing the obsolete **Build & Test**
check from the previous architecture. The `Report` job is best-effort and
must not be used as a required check.

Every run ends with a **CI Test Report** step summary: build duration,
per-lane predicted vs actual runtimes (unit and UI), retries/flake warnings
(native-test flakes, runner-level class retries, and infrastructure-wedge
recoveries - each labeled for what it is), hang results with the identified
class, slowest classes, predicted and actual lane imbalance, and overall
wall clock. On failure it names the failing test, the lane, whether a
simulator reset/erase occurred, whether the targeted retry passed, and any
classes left `not_diagnosed` after a confirmed hang.

## Local exhaustive gate (Mac, outside GitHub)

`scripts/local-ci-gate.sh` is the exhaustive gate. It runs on our own Mac over
SSH — never inside GitHub's self-hosted-runner system — and it always tests an
**exact commit**, resolved to a full SHA, in a throwaway detached worktree.

### Invocation

From any machine with the `ios-mac` SSH alias (see the workspace `AGENTS.md`):

```
ssh ios-mac 'bash ~/projects/conduit-gate-tooling/scripts/local-ci-gate.sh --ref <sha-or-ref>'
```

`~/projects/conduit-gate-tooling` is a scratch worktree **of the Conduit
repository itself** (created once with `git -C
~/projects/hermes-conduit-swiftui worktree add --detach
~/projects/conduit-gate-tooling origin/main`), not a separate clone: `--ref`
is resolved in the shared object store, so the SHA that gets reported is a
Conduit commit. The script refuses to run at all unless the checkout it is
invoked from looks like Conduit (`project.yml`, `ConduitTests/`,
`ConduitUITests/`), so pointing it at an unrelated repository fails fast
instead of certifying a meaningless SHA.

`--ref` accepts any ref or SHA that repository already has; add `--fetch` to
fetch `origin` first, which makes the whole thing one command:

```
ssh ios-mac 'bash ~/projects/conduit-gate-tooling/scripts/local-ci-gate.sh --ref origin/main --fetch'
```

The gate prints the full SHA it tested and writes
`gate-result.json` + `summary.md` under its run directory. Exit status is `0`
only when the entire gate passed. Run `--help` for every flag.

The device is pinned by name (`--simulator`, default `iPhone 17 Pro`; the
environment's `SIMULATOR_OS`/`SIMULATOR_ARCH` are honoured by ci-lib.sh as
usual) and the SAME device is exported to every phase, so the
simulator/runtime recorded in the result is the one the tests actually ran on.

### Policy (non-negotiable)

1. **Before approving a trusted PR for merge, or a release head for archive,
   run the local Mac gate on the exact head SHA.**
2. **A result for any other SHA is invalid.** The gate reports the commit it
   tested; if that is not the head you are approving, the result does not
   apply.
3. **Never use a developer's active worktree as the tested tree.** The gate
   creates its own detached worktree and never reads, writes, resets,
   stashes, or checks out anything in the invoking checkout.
4. **Rerun-until-green is not validation.** The gate invokes the lane runner
   with `--iterations 1` (no Xcode-native flake retry), and it fails the run
   outright if any work item recorded `test-failures` and then `passed`.
5. **Genuine failures and infrastructure failures are reported separately.**
   An infrastructure/simulator/AX failure still fails the gate, but it is
   reported as infrastructure — never dressed up as an assertion failure, and
   never as a pass.
6. **Never execute arbitrary or unreviewed external PR code on the Mac.** Only
   run heads we have explicitly decided are trusted enough for local
   execution. Fork PRs are covered by hosted CI, not by this gate.

### What it does

| Phase | What runs | Notes |
|---|---|---|
| resolve + worktree | `git worktree add --detach <sha>` outside the invoking checkout | HEAD is verified to equal the requested SHA; the worktree is removed afterwards and all diagnostics live in the run directory |
| generate | `xcodegen generate` | The generated `.xcodeproj` is never committed |
| static | `plan-tests.py validate`, `python3 -m unittest discover -s scripts/tests`, `check-l10n-coverage.py` | `--skip-static` exists for developer loops and marks the result **partial** |
| build | `ci-build-for-testing.sh` once, into a gate-specific DerivedData | The same build-once contract as hosted CI, without the artifact round trip |
| prepare | before each lane: ci-lib.sh's own bounded shutdown/**erase**/boot/wait-for-boot | Environment preparation, never a retry — it re-runs nothing and a lane that fails afterwards still fails. Without it, the host app's install/launch is refused (`Simulator device failed to launch com.milim.relay … Application failed preflight checks … reason: Busy`) and the batch is lost. An A/B probe on our Mac settled that the erase is the part that matters (shutdown+boot alone still refused the next lane; erase+boot passed it), but it is a **partial** mitigation: on a full run the refusal returned a batch or two into a lane, so it accumulates over successive launches of the same bundle on one device. Costs ~40 s per lane. `--no-simulator-erase` keeps the cheaper mode for observing the raw behavior; `--no-simulator-prep` skips preparation entirely. |

| unit | the **complete** `ConduitTests` suite | One exhaustive lane: the planner is forced to `--min-lanes 1 --max-lanes 1` so it still owns the sequential batches and every per-batch watchdog |
| ui | the **complete** `ConduitUITests` suite | One batched invocation over every UI class, with the planner's per-class watchdogs |
| repeats | the repeat policy below | Runs even when the unit or UI lane failed, so one red lane cannot hide the rest; skipped when the build failed (no test products), and left failing when the plan could not be produced (there is nothing to project the repeat tasks from) |

### The bounded recovery round (and the wedge it is for)

The gate runs on a dedicated simulator device ("Conduit CI Gate", created on
demand) precisely so it can erase that device freely: on our Mac the host
app's install/launch is periodically refused (`Simulator device failed to
launch com.milim.relay … Application failed preflight checks … reason: Busy`),
and the A/B probe that diagnosed it showed only `simctl erase` clears the
condition reliably.

Because the wedge accumulates again over successive launches, a one-time
pre-run erase is not enough. The gate therefore has exactly one bounded
recovery round, and it is allowed for exactly one infrastructure class:

* the refusal is reported as **infrastructure**, never as an assertion
  failure, with the affected batch named and the classes it hid listed as
  `not executed`;
* the **continuation pass** runs the batches the stopped lane never reached;
* if work is still incomplete and the evidence is the verified launch class
  (XCTest's synthetic `System Failures` entry and/or the Busy signature in the
  lane log), the gate erases its own simulator once (shutdown/erase/boot/wait,
  via ci-lib.sh) and retries exactly the incomplete work **once**;
* **a genuine assertion anywhere disqualifies the round entirely** — the
  projection refuses, so a product failure is never retried around;
* if the same class comes back after the round, the gate fails as
  infrastructure and makes **no third attempt**.

The wedge is worth knowing in detail, because it defeated every per-launch
mitigation and it shapes the round. Probes on our Mac (all on the gate's own
device) showed the refusal **alternates across app launches**: every other
launch is refused, and that held through `simctl terminate` + 5/10/15 s
settles, `simctl uninstall` between launches, and a fresh `erase` before a
retry alike - and it appears inside a single lane too (batch 1 passes,
batch 2 refused). Only an erase reliably clears the condition *once*. The
round therefore puts the whole retry set back in ONE invocation with one
batch, so the retry gets its single chance on a single launch instead of
spreading it across many launches that the alternation would thin out.

A run the round recovered is a PASS with the retry recorded
(`infrastructure.retries`, `recovered`, and a caveat naming the healed
wedge) — never a silently green run. A run that needed no recovery is the
normal case. Work that produced a result is never re-executed across passes,
so the aggregate execution counts are exact; a class that somehow did appear
in two passes is counted once and reported in `reread_classes`.

The lane runner, the planner and the timing extractor come from the **tested
commit's own tree**, so the policy that decides the verdict is the policy of
the revision being certified. Only the orchestrator and the result assembler
come from the invoking checkout.

### Repeat policy

Classes whose failures have historically depended on scheduling are executed
**K times unconditionally** (default `3`) and must pass **every** time. This
is repetition as *evidence*, not retry as *recovery*: the lane runner is
still called with `--iterations 1`, so nothing is retried until it agrees.
Every iteration gets its own result directory, its own execution and failure
counts, and its own watchdog — the planner's batch budget for that class,
capped by `--repeat-timeout-cap` (default 900 s) so one hung iteration cannot
burn an unbounded wall clock.

The default set is the settled-Markdown/dormancy and transcript-performance
families that have repeatedly failed in scheduling-dependent ways:
`SettledMessageIsolationTests`, `TranscriptPerfLedgerContractTests`,
`TranscriptPerformanceFixtureTests`, `MarkdownRichContentHostedTests`
(override with `--repeat-classes`). A repeat class that is no longer in the
suite **fails the gate**: a policy that quietly stopped covering what it
promises is a gate defect, not a warning.

### Failure classification

The gate classifies on the lane runner's own attempt tokens (`passed`,
`test-failures`, `infra-error`, `timeout`, `unclassified`, `incomplete`,
`not_run`, `not_diagnosed`) rather than re-deriving a verdict from logs. The
lane runner's own final verdict is a problem in its own right: a lane that
says anything other than `pass`/`skipped` fails the gate even if the event
vocabulary came up empty.

* **genuine assertion failures** — the invocation's extraction recorded a
  failing *test* (an entry naming a real test case), and the work item ended
  on `test-failures`. Fails the gate.
* **test-runner failures** — XCTest also files the *run* itself: when the
  Simulator refuses to install or launch the host app, the result bundle
  carries a synthetic entry under the pseudo-class `System Failures`
  (`Conduit encountered an error`), and the lane runner's status token cannot
  tell it from an assertion. The gate splits those apart using the
  per-invocation extraction parts, so a machine that never started the app is
  reported as infrastructure — never as an assertion failure. This is not
  hypothetical: it is what the gate's first runs on `main` produced.
* **assertions retried until green** — a work item recorded `test-failures`
  and later `passed`. Fails the gate in every mode, including
  `--allow-recovered-infrastructure`: a flake is a flake, not a pass. (A UI
  shard's targeted retry arrives as a second batch attempt and is grouped
  back onto the shard's work item for exactly this reason.)
* **infrastructure failures** — nonzero exit with a known zero failing-test
  count, or a result that could not be classified. Fails the gate. A
  *persistent* one (the environment never recovered) is always fatal. A
  *recovered* one is split by what recovered it: healed by the gate's own
  bounded recovery round (below) the run may PASS with the retry recorded and
  a caveat naming the healed wedge; healed by the lane runner's own retry
  inside one lane it is still fatal by default, because the run is not
  trustworthy evidence — the operator reruns the gate. That default is the
  only thing `--allow-recovered-infrastructure` downgrades, and it is then
  recorded as a **caveat** in `gate-result.json` and `summary.md`, the two
  documents a result is cited from. `--no-lock` and `--no-simulator-prep`, and
  a failed Simulator preparation, are recorded the same way.
* **watchdog timeouts (hangs)** — classified as timeouts, with the hung class
  or batch named by the runner.
* **not executed / not diagnosed** — work that never ran. Fails the gate:
  unexecuted tests may never masquerade as passed. Because a unit lane stops
  at the batch that failed, the gate then runs the batches it never reached as
  a **continuation pass** (diagnostic, never a retry of anything that already
  ran) so one failure cannot hide the rest of the suite; the coverage the gate
  certifies is the aggregate over the lane and its continuation, and the
  "never executed" evidence is recomputed against that aggregate rather than
  carried over from the stopped lane.

### Result document

`gate-result.json` is machine-readable and carries at least: `tested_sha`
(plus `requested_ref`), `xcode_version`, `simulator` (`name`, `runtime`,
`udid`), `unit` and `ui` blocks with `executions`, `failures`,
`classes_expected`/`classes_observed`, `batch_count` (`null` for a UI shard,
which is one batched invocation rather than a batch layout), per-phase
`assertion_failures`/`infrastructure_failures`/`timeouts`/`not_executed`,
`synthetic_failures` (XCTest reporting the run itself),
`focused_repeats` (per class and per iteration), an `infrastructure` roll-up
(`persistent`, `recovered`, `retries` = recovery rounds the gate used, `retry_detail`, `simulator_resets`/`erases`), a
`partial`/`partial_reasons` pair, `caveats` and `run_flags` (the operating
flags a run was given), `problems[]`, and the final `verdict`
(`PASS`/`FAIL`). The human `summary.md` next to it carries the same numbers.

A run is `partial` when the operator deliberately narrowed it
(`--skip-static`, or a disabled repeat policy): a partial run can pass, but it
must never be cited as the exhaustive result for a release head.

Both artifacts, every phase log, every per-iteration log and the `.xcresult`
bundles live under the run directory (default
`<parent of the repo>/conduit-local-gate/runs/<sha12>-<UTC>`), which is
**outside** the repository, so the gate never adds files to a working tree.

What is kept is the lane runner's existing retention policy, not a new one: a
clean pass prunes its own bundles (timings have already been extracted), a
failing or retried lane keeps them, and a red run therefore always carries the
bundles that explain it. The `.xcresult` paths the gate recorded for a passing
lane can legitimately be empty; the timings, counts and logs are the evidence
there, and the full run is reproducible from the printed SHA.

The throwaway worktree is removed at the end of the run, including on
`INT`/`TERM` (the gate then exits 130/143 rather than continuing); a `SIGKILL`
is the one case nothing can cover, and the gate prints the
`git worktree remove --force` command for it. Reproduce the exact tested tree
with the `git worktree add --detach` command the gate prints on failure.

`--fetch` (opt-in) rewrites the invoking repository's remote-tracking refs and
tags. It does not touch the working tree, the index or any stash — that is the
property the gate guarantees — but it is a fetch in that repository rather
than in a scratch clone, so a run without `--fetch` tests exactly the refs the
checkout already had.

### Simulator safety

The gate takes a single-gate-per-Mac lock (a `mkdir`-based lock under the gate
root) and refuses to start while another gate is running: two concurrent
`xcodebuild` chains on one Mac corrupt each other's Simulator state, and a
result from such a run would be meaningless. `--no-lock` exists and is
documented as unsafe. Stale locks (dead holder pid) are taken over with a
warning.

## Adding a test

Just add it. The planner discovers it on the next run, gives it the default
estimate (or its real history entry after the first main run), and balances
it into a lane. No lane-assignment files to maintain. To check locally:

```
python3 scripts/plan-tests.py validate
python3 -m unittest discover -s scripts/tests
```

New test classes need no gate changes either: the local gate asks the same
planner for the class inventory, so a new class joins the exhaustive unit or
UI lane automatically. A class added to `--repeat-classes` (or to the
default set) without existing in the suite fails the gate, so the repeat
policy cannot silently decay.

## Local run directories

The CI workspace uses `ci-derived-data/`, `ci-lane/`, `ci-artifacts/`,
`ci-timing/`, `ci-report/`, `ci-update/` (all gitignored); the same paths
work for local rehearsal of the scripts.