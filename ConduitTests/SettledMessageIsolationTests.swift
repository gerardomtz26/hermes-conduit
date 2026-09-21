import XCTest
import SwiftUI
@testable import Conduit

/// Regression tests for settled-row isolation (Fix 2): publishing unrelated
/// live state must not re-evaluate settled Markdown presentation. These use
/// the deterministic TranscriptPerf counters, not wall-clock timing.
///
/// The streaming-tick simulation publishes unrelated live state so the row's
/// body chain re-runs — exactly what ChatView's ForEach does to every mounted
/// row on each AppState publish — and asserts the Equatable gate skipped the
/// expensive settled subtree.
@MainActor
final class SettledMessageIsolationTests: XCTestCase {

    /// Retained for the full lifetime of each measurement so the hosted
    /// hierarchy stays genuinely mounted; torn down explicitly per test.
    private var testWindow: UIWindow?

    override func setUp() {
        super.setUp()
        TranscriptPerf.reset()
    }

    override func tearDown() {
        // Detach the window first so dismantle work is triggered, flush the
        // run loop so it completes within THIS test, then reset counters —
        // the next test starts from zero with no pending teardown updates.
        testWindow?.isHidden = true
        testWindow?.rootViewController = nil
        RunLoop.current.run(until: Date())
        testWindow = nil
        TranscriptPerf.reset()
        super.tearDown()
    }

    private func makeAppState() throws -> AppState {
        let suiteName = "settled-isolation-tests"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName),
            "test UserDefaults suite must initialize"
        )
        defaults.removePersistentDomain(forName: suiteName)
        return AppState(defaults: defaults, loadSavedConnection: false)
    }

    private func markdownMessage(id: String = "m1") -> ChatMessage {
        ChatMessage(
            id: id,
            role: .assistant,
            content: """
            ## Heading one

            A settled paragraph with **bold**, *italic*, and `code` runs.

            - list item one
            - list item two

            > A quoted line for coverage.

            [A link](https://example.com)
            """,
            timestamp: "2026-01-01T00:00:00Z"
        )
    }

    /// Hosts an AssistantBubble row in a retained, live window. The Dynamic
    /// Type environment is PINNED: on a freshly booted CI simulator the
    /// hosting window's content-size category resolves asynchronously, and a
    /// late trait-sync transaction inside a measurement window would
    /// otherwise read as a spurious settled re-evaluation (the same failure
    /// mode testDynamicTypeChangeReOpensSettledContentGate was hardened
    /// against).
    private func mountRow(
        message: ChatMessage,
        appState: AppState,
        resolver: GatewayMediaDataURLResolver?
    ) -> UIHostingController<AnyView> {
        let row = AnyView(
            DormancyHarnessEnvironment.applying(
                AssistantBubble(
                    message: message,
                    readAloudController: appState.messageReadAloudController,
                    gatewayResolver: resolver
                )
                .environmentObject(appState)
            )
        )
        let host = UIHostingController(rootView: row)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        testWindow = window
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date())
        return host
    }

    /// Concrete-root hosting for the dormancy/gate tests. A stable concrete
    /// type (instead of an erased AnyView) gives UIHostingController direct
    /// value diffing and mirrors the production shape, where a streaming
    /// publish re-creates every mounted row as a concrete value through
    /// MessageBubble's switch inside an established hierarchy.
    private func makeHarnessRow(
        message: ChatMessage,
        appState: AppState,
        resolver: GatewayMediaDataURLResolver?,
        sizeCategory: ContentSizeCategory = .large
    ) -> SettledGateHarnessRow {
        SettledGateHarnessRow(
            message: message,
            readAloudController: appState.messageReadAloudController,
            gatewayResolver: resolver,
            appState: appState,
            sizeCategory: sizeCategory
        )
    }

    /// Hosts a concrete harness row in a retained, live window (see
    /// `makeHarnessRow` for why the root must stay concrete).
    private func mountConcreteRow(
        message: ChatMessage,
        appState: AppState,
        resolver: GatewayMediaDataURLResolver?,
        sizeCategory: ContentSizeCategory = .large
    ) -> UIHostingController<SettledGateHarnessRow> {
        let host = UIHostingController(
            rootView: makeHarnessRow(
                message: message,
                appState: appState,
                resolver: resolver,
                sizeCategory: sizeCategory
            )
        )
        testWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        testWindow?.rootViewController = host
        testWindow?.isHidden = false
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date())
        return host
    }

    func testIdenticalRowRecreationSkipsSettledMarkdownPresentation() throws {
        let appState = try makeAppState()
        let resolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")
        let message = markdownMessage()

        // Mount through the concrete harness root (see makeHarnessRow for
        // why the root stays concrete, and the tick simulation below for
        // why the tick itself is a publish rather than a root re-assignment).
        let host = mountConcreteRow(
            message: message,
            appState: appState,
            resolver: resolver
        )

        // Baseline: the initial mount performed the expensive work — and let
        // its full commit (including trait-sync follow-up transactions) land
        // BEFORE arming the measurement window, exactly like
        // testDynamicTypeChangeReOpensSettledContentGate. A zero-interval
        // run-loop tick observes only what flushed synchronously, so a late
        // first-mount transaction on a slow/cold runner otherwise lands
        // inside the window and reads as a spurious re-evaluation.
        drainUntil(2.0) { TranscriptPerf.settledMarkdownTextBodyEvaluations > 0 }
        // The first body evaluation is followed by a late trait-sync commit
        // on slow/cold runners; wait until the counters go quiet for over a
        // second so that commit lands BEFORE the measurement window arms.
        var quietFor: TimeInterval = 0
        var settleElapsed: TimeInterval = 0
        var lastTotal = TranscriptPerf.settledMarkdownTextBodyEvaluations
            + TranscriptPerf.textKitMeasurementCalls
            + TranscriptPerf.selectableTextViewUpdateCalls
        let settleStep: TimeInterval = 0.1
        var baselineSettled = false
        while settleElapsed < 10 {
            RunLoop.current.run(until: Date().addingTimeInterval(settleStep))
            settleElapsed += settleStep
            let current = TranscriptPerf.settledMarkdownTextBodyEvaluations
                + TranscriptPerf.textKitMeasurementCalls
                + TranscriptPerf.selectableTextViewUpdateCalls
            if current == lastTotal {
                quietFor += settleStep
                if quietFor >= 1.2 {
                    baselineSettled = true
                    break
                }
            } else {
                quietFor = 0
                lastTotal = current
            }
        }
        // Without a settled baseline the stay-at-zero assertion would race
        // against the still-draining first-mount commit.
        guard baselineSettled else {
            XCTFail("counters never reached a quiet state; the measurement window would be meaningless on this runner")
            return
        }
        let initialSTVUpdates = TranscriptPerf.selectableTextViewUpdateCalls
        XCTAssertGreaterThan(TranscriptPerf.settledMarkdownTextBodyEvaluations, 0, "initial mount must render the markdown")

        // Simulate a streaming tick the way production delivers it: an
        // unrelated AppState publish (@Published streamingText — the same
        // vector the transcript fixtures drive) invalidates the row's
        // @EnvironmentObject and re-runs its body chain, re-creating the
        // SettledAssistantMessageContent value with IDENTICAL inputs (equal
        // message value, same resolver identity, same pinned Dynamic Type
        // environment). Root re-assignment is deliberately NOT used: an
        // erased AnyView root replacement is a hosting shape no production
        // path exercises, and its erased diff remounts the identical row
        // under a loaded scheduler — the hosted artifact this suite chased
        // — while an identical CONCRETE root is pruned wholesale by value
        // diffing before the gate is ever consulted, which would make the
        // stay-at-zero assertion vacuous.
        TranscriptPerf.reset()
        let bubbleBodiesBeforeRecreation = TranscriptPerf.settledMessageBubbleBodyEvaluations
        for tick in 1...3 {
            appState.streamingText = "unrelated live-state tick \(tick)"
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date())
        }

        // Give any (incorrect) re-evaluation time to surface before
        // asserting; draining past the re-creation commit makes the
        // stay-at-zero assertion meaningful instead of vacuously passing.
        drainUntil(1.0) { TranscriptPerf.settledMarkdownTextBodyEvaluations > 0 }

        // Anti-vacuity guard: the publish must have actually re-run the
        // row's body chain (AssistantBubble notes its body, mirroring
        // MessageBubble). If SwiftUI ever prunes an identical row update
        // before reaching the gate, this fails and the stay-at-zero
        // assertion below would be measuring nothing.
        XCTAssertGreaterThan(
            TranscriptPerf.settledMessageBubbleBodyEvaluations,
            bubbleBodiesBeforeRecreation,
            "recreation must reach the row's body chain; a fully-pruned update makes the dormancy assertion vacuous"
        )

        let recreations = TranscriptPerf.settledMarkdownTextBodyEvaluations
        let spanSuffix = TranscriptPerf.windowEvaluationSpans.isEmpty
            ? ""
            : " (evaluations: \(recreations); spans:\n"
                + TranscriptPerf.windowEvaluationSpans.joined(separator: "\n") + ")"
        XCTAssertEqual(
            recreations, 0,
            "a streaming publish re-creating an identical settled row must not re-evaluate its Markdown"
                + spanSuffix
        )
        XCTAssertEqual(
            TranscriptPerf.selectableTextViewUpdateCalls, 0,
            "a streaming publish re-creating an identical settled row must not touch SelectableTextView"
        )
        _ = initialSTVUpdates
    }

    func testContentChangeStillReRendersSettledContent() throws {
        let appState = try makeAppState()
        let resolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")

        let host = mountRow(message: markdownMessage(), appState: appState, resolver: resolver)

        // A genuinely changed message must open the gate. The content must
        // actually differ (not just the id) so the selectable text view
        // receives a new attributed string.
        TranscriptPerf.reset()
        var changed = markdownMessage(id: "m2")
        changed.content += "\n\nA second paragraph with different content."
        host.rootView = AnyView(AssistantBubble(
            message: changed,
            readAloudController: appState.messageReadAloudController,
            gatewayResolver: resolver
        )
        .environmentObject(appState)
        .environment(\.sizeCategory, .large))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        drainUntil(2.0) { TranscriptPerf.settledMarkdownTextBodyEvaluations > 0 }

        XCTAssertGreaterThan(
            TranscriptPerf.settledMarkdownTextBodyEvaluations, 0,
            "changed content must re-evaluate settled presentation"
        )
        XCTAssertGreaterThan(
            TranscriptPerf.selectableTextViewUpdateCalls, 0,
            "changed content must update the selectable text view"
        )
    }

    func testResolverChangeStillReRendersSettledContent() throws {
        let appState = try makeAppState()
        let resolverA = GatewayMediaDataURLResolver(appState: appState, profile: "default")
        let resolverB = GatewayMediaDataURLResolver(appState: appState, profile: "other")

        let host = mountRow(message: markdownMessage(), appState: appState, resolver: resolverA)

        // A different resolver identity (profile switch) must open the gate.
        TranscriptPerf.reset()
        host.rootView = AnyView(AssistantBubble(
            message: markdownMessage(),
            readAloudController: appState.messageReadAloudController,
            gatewayResolver: resolverB
        )
        .environmentObject(appState)
        .environment(\.sizeCategory, .large))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        drainUntil(2.0) { TranscriptPerf.settledMarkdownTextBodyEvaluations > 0 }

        XCTAssertGreaterThan(
            TranscriptPerf.settledMarkdownTextBodyEvaluations, 0,
            "resolver identity change (profile switch) must re-evaluate settled presentation"
        )
    }

    func testEquatableConformanceComparesMessageAndResolverIdentity() throws {
        let appState = try makeAppState()
        let resolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")
        let otherResolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")

        let a = SettledAssistantMessageContent(
            message: markdownMessage(),
            displayName: "Hermes",
            avatarURL: nil,
            gatewayResolver: resolver,
            sizeCategory: .large,
            chatTextSize: .default
        )
        let sameInputs = SettledAssistantMessageContent(
            message: markdownMessage(),
            displayName: "Hermes",
            avatarURL: nil,
            gatewayResolver: resolver,
            sizeCategory: .large,
            chatTextSize: .default
        )
        let differentResolver = SettledAssistantMessageContent(
            message: markdownMessage(),
            displayName: "Hermes",
            avatarURL: nil,
            gatewayResolver: otherResolver,
            sizeCategory: .large,
            chatTextSize: .default
        )
        let differentMessage = SettledAssistantMessageContent(
            message: markdownMessage(id: "m2"),
            displayName: "Hermes",
            avatarURL: nil,
            gatewayResolver: resolver,
            sizeCategory: .large,
            chatTextSize: .default
        )
        let differentSizeCategory = SettledAssistantMessageContent(
            message: markdownMessage(),
            displayName: "Hermes",
            avatarURL: nil,
            gatewayResolver: resolver,
            sizeCategory: .extraExtraLarge,
            chatTextSize: .default
        )

        XCTAssertEqual(a, sameInputs, "equal message + same resolver identity must compare equal")
        XCTAssertNotEqual(a, differentResolver, "different resolver instance must compare unequal even with equal contents")
        XCTAssertNotEqual(a, differentMessage, "different message must compare unequal")
        XCTAssertNotEqual(a, differentSizeCategory, "a Dynamic Type change must compare unequal and re-open the gate")
    }

    /// Dynamic Type invalidation (#4): a size-category change must re-open
    /// the settled-content gate so the settled Markdown body re-evaluates.
    ///
    /// Same-category dormancy (the streaming-tick shape) has dedicated
    /// coverage in
    /// testIdenticalRowRecreationSkipsSettledMarkdownPresentation; this test
    /// exercises only the gate-reopening half.
    ///
    /// Structurally deterministic: after each mutation the run loop is
    /// drained until the asserted condition holds or a bounded deadline
    /// expires. SwiftUI hosting commits are driven by display links, which
    /// need real elapsed time — a zero-interval `RunLoop.run(until: Date())`
    /// tick observes only whatever flushed synchronously and made the
    /// previous version of this test flaky on slower CI runners (a late
    /// transaction from the initial mount landed inside the measurement
    /// window). Actual font delivery cannot be asserted in-process:
    /// UIFontMetrics resolve against UIApplication's
    /// preferredContentSizeCategory, which is process-global. The Equatable
    /// input contract (including sizeCategory) is covered directly by
    /// testEquatableConformanceComparesMessageAndResolverIdentity.
    func testDynamicTypeChangeReOpensSettledContentGate() throws {
        let appState = try makeAppState()
        let resolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")
        let message = markdownMessage()

        let host = mountConcreteRow(
            message: message,
            appState: appState,
            resolver: resolver,
            sizeCategory: .large
        )
        // Let the initial mount fully settle — including trait-sync follow-up
        // transactions — before arming the measurement window.
        drainUntil(2.0) { TranscriptPerf.settledMarkdownTextBodyEvaluations > 0 }

        TranscriptPerf.reset()
        host.rootView = makeHarnessRow(
            message: message,
            appState: appState,
            resolver: resolver,
            sizeCategory: .extraExtraLarge
        )
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        drainUntil(2.0) { TranscriptPerf.settledMarkdownTextBodyEvaluations > 0 }

        XCTAssertGreaterThan(
            TranscriptPerf.settledMarkdownTextBodyEvaluations, 0,
            "a Dynamic Type change must re-open the settled-content gate and re-evaluate settled content"
        )
    }

    /// Drains the run loop in short real intervals until `condition` holds or
    /// the bounded deadline passes. Display-link-driven SwiftUI commits need
    /// elapsed time to fire, so draining until the observable state is
    /// reached is deterministic where a fixed zero-interval tick is not: it
    /// exits as early as possible and fails only when the state genuinely
    /// never arrives.
    private func drainUntil(_ seconds: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - Window trait churn (the hosted determinism vector)

    /// Records the ambient sizeCategory its body sees. Mounted OUTSIDE the
    /// harness pin as a sibling, it proves a window trait churn actually
    /// reached the hosted hierarchy — without it, a churn that no-op'd
    /// would let the dormancy assertion below pass vacuously.
    private final class AmbientObservationBox {
        var observed: [ContentSizeCategory] = []
    }

    private struct AmbientSizeCategoryCanary: View {
        @Environment(\.sizeCategory) private var ambient
        let box: AmbientObservationBox

        var body: some View {
            let _ = box.observed.append(ambient)
            Color.clear.frame(height: 0)
        }
    }

    /// Deterministic regression for the build-147 hosted blocker (Sep 2026):
    /// environment churn in the ancestry ABOVE the harness pin — the shape
    /// hosting-level trait sync takes (freshly booted CI simulators re-push
    /// window traits under the app root) — must NOT re-open the settled
    /// gate, because the harness re-asserts the gate's environment inputs
    /// BELOW the churn point.
    ///
    /// Delivery vehicle: rootView re-assignment mutating ONLY the ambient
    /// environment above the pinned subtree (the pinned values are
    /// re-applied unchanged). This is the same structural relationship as
    /// window→root churn in production, delivered deterministically; the
    /// row subtree itself is never re-created through an erased root, and
    /// the vehicle matches testDynamicTypeChangeReOpensSettledContentGate's
    /// precedent for first-class environment mutation.
    ///
    /// Mutation-sensitive: strip the DormancyHarnessEnvironment pinning and
    /// the same churn flows into `AssistantBubble`'s `\.sizeCategory`
    /// environment read, opens the SettledAssistantMessageContent gate
    /// (field: sizeCategory — visible in the gate-reopen report), and
    /// re-evaluates MarkdownText, failing the zero assertions.
    func testWindowTraitChurnDoesNotReopenSettledGate() throws {
        let appState = try makeAppState()
        let resolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")
        let message = markdownMessage()
        let canary = AmbientObservationBox()

        // Ambient environment ABOVE the pin (stands in for the window's);
        // the pin below it stays constant across the churn.
        struct ChurnableRoot: View {
            let ambient: ContentSizeCategory
            let canary: AmbientObservationBox
            let row: SettledGateHarnessRow

            var body: some View {
                VStack(spacing: 0) {
                    AmbientSizeCategoryCanary(box: canary)
                        .environment(\.sizeCategory, ambient)
                    DormancyHarnessEnvironment.applying(row)
                }
            }
        }

        let row = makeHarnessRow(
            message: message,
            appState: appState,
            resolver: resolver
        )
        let host = UIHostingController(
            rootView: AnyView(ChurnableRoot(ambient: .large, canary: canary, row: row))
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        testWindow = window
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        // Initial mount performed the settled work; wait it out so the
        // measurement window opens on a quiet hierarchy.
        drainUntil(2.0) { TranscriptPerf.settledMarkdownTextBodyEvaluations > 0 }
        let settled = PerformanceFixtureWait.settleUntilCountersQuiet(quietFor: 1.2)
        guard settled else {
            XCTFail("counters never reached a quiet state; the churn measurement would be meaningless")
            return
        }

        TranscriptPerf.reset()

        // The churn: ambient environment above the pin changes; the pin
        // itself is re-applied unchanged below it.
        host.rootView = AnyView(
            ChurnableRoot(ambient: .extraExtraExtraLarge, canary: canary, row: row)
        )
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // Give any (incorrect) re-evaluation time to surface before
        // asserting, so the zero assertions measure reality.
        drainUntil(1.0) { TranscriptPerf.settledMarkdownTextBodyEvaluations > 0 }

        // Vacuity guard: the churn MUST have reached the hierarchy — the
        // unpinned canary (above the pin) must have observed the churned
        // category. Without this, a churn that no-op'd would make the zero
        // assertions below pass without testing anything.
        guard canary.observed.last == .extraExtraExtraLarge else {
            XCTFail(
                "ambient churn never reached the hosted hierarchy " +
                "(canary saw \(canary.observed.last.map(String.init(describing:)) ?? "nothing")); " +
                "test measures nothing"
            )
            return
        }

        // THE INVARIANT: pinned settled content stays dormant under the
        // same churn that reached the unpinned canary.
        let evaluations = TranscriptPerf.settledMarkdownTextBodyEvaluations
        let reopenSuffix = TranscriptPerf.recentGateReopenReports.isEmpty
            ? ""
            : " (gate reopens: \(TranscriptPerf.recentGateReopenReports.joined(separator: "; ")))"
        XCTAssertEqual(
            evaluations, 0,
            "ancestry environment churn must not re-evaluate pinned settled Markdown"
                + " (evaluations: \(evaluations)\(reopenSuffix)"
                + (TranscriptPerf.windowEvaluationSpans.isEmpty
                    ? ")"
                    : "; spans: \(TranscriptPerf.windowEvaluationSpans.joined(separator: " | "))")
        )
        XCTAssertEqual(
            TranscriptPerf.selectableTextViewUpdateCalls, 0,
            "ancestry environment churn must not touch SelectableTextView for settled content"
        )
    }
}

/// Concrete hosted root for the gate tests. A stable concrete type (instead
/// of an erased AnyView) gives UIHostingController direct value diffing:
/// changing `sizeCategory` is a first-class rootView value change, and the
/// environment write happens inside `body` exactly once per value.
///
/// MUST stay non-Equatable: the dormancy fixture relies on the root's body
/// re-running (and re-diffing `AssistantBubble`) on every re-assignment so
/// the inner `SettledAssistantMessageContent.equatable()` gate is what
/// actually holds the row at rest. An Equatable root could let SwiftUI prune
/// the update above the gate and make the stay-at-zero assertion vacuous —
/// the fixture guards this with its bubble-body anti-vacuity check.
private struct SettledGateHarnessRow: View {
    let message: ChatMessage
    let readAloudController: MessageReadAloudController
    let gatewayResolver: GatewayMediaDataURLResolver?
    let appState: AppState
    let sizeCategory: ContentSizeCategory

    var body: some View {
        DormancyHarnessEnvironment.applying(
            AssistantBubble(
                message: message,
                readAloudController: readAloudController,
                gatewayResolver: gatewayResolver
            )
            .environmentObject(appState),
            sizeCategory: sizeCategory
        )
        // Note: DormancyHarnessEnvironment.applying pins BOTH gate
        // environment inputs; the explicit sizeCategory parameter preserves
        // the Dynamic Type mutation vector for
        // testDynamicTypeChangeReOpensSettledContentGate. The pinning
        // contract is held by
        // testDormancyHarnessPinsGateEnvironmentInputs.
    }
}
