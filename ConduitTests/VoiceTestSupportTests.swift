//
//  VoiceTestSupportTests.swift
//  Conduit
//
//  Contract tests for the shared doubles in VoiceTestSupport.swift. The Voice
//  and CarPlay suites synchronize on these doubles' signals, so the signals
//  themselves are load-bearing: a double that reports a window it never opened
//  — or parks an operation nothing can release — invalidates the assertions
//  built on top of it.
//

import XCTest
@testable import Conduit

@MainActor
final class VoiceTestSupportTests: XCTestCase {

    // MARK: - MockSpeechStream parking

    /// Baseline for the cancellation tests below: a blocked append hands the
    /// text to the stream and then parks until something releases it.
    ///
    /// The handoff runs synchronously up to the park, so observing the handoff
    /// also means the park is installed; the append can then only finish with
    /// the cancellation `cancel()` delivers, which is what proves it parked.
    func testBlockedAppendRecordsHandoffThenParks() async {
        let handedOff = AwaitableCounter()
        let stream = MockSpeechStream(blocksAppend: true, onAppend: { _ in handedOff.increment() })
        let task = Task { @MainActor in
            do {
                try await stream.append("delta")
                return false
            } catch {
                return (error as? URLError)?.code == .cancelled
            }
        }

        await handedOff.waitUntil(1)
        XCTAssertEqual(stream.appended, ["delta"])
        XCTAssertEqual(stream.cancelCount, 0, "nothing has released the park yet")

        stream.cancel()
        let wasCancellation = await task.value
        XCTAssertTrue(wasCancellation, "the parked append finishes cancelled")
    }

    /// Cancelling the owning task must release a parked append. Production can
    /// cancel the speech drain without calling `stream.cancel()`; before this
    /// guarantee the continuation outlived its task and the test lane hung.
    func testCancellingOwningTaskReleasesParkedAppendAsCancelled() async {
        let handedOff = AwaitableCounter()
        let stream = MockSpeechStream(blocksAppend: true, onAppend: { _ in handedOff.increment() })
        let task = Task { @MainActor in
            do {
                try await stream.append("delta")
                return false
            } catch {
                return (error as? URLError)?.code == .cancelled
            }
        }

        await handedOff.waitUntil(1)
        task.cancel()

        let wasCancellation = await task.value
        XCTAssertTrue(wasCancellation, "task cancellation released the park as .cancelled")
        XCTAssertEqual(stream.cancelCount, 0, "released by cancellation, not by stream.cancel()")
    }

    /// Cancellation that lands before the append ever runs must fail fast
    /// instead of installing a park nobody is left to release.
    func testAlreadyCancelledTaskFailsFastWithoutParking() async {
        let stream = MockSpeechStream(blocksAppend: true)
        let task = Task { @MainActor in
            do {
                try await stream.append("delta")
                return false
            } catch {
                return (error as? URLError)?.code == .cancelled
            }
        }
        task.cancel()

        let wasCancellation = await task.value
        XCTAssertTrue(wasCancellation)
        XCTAssertEqual(stream.cancelCount, 0)
    }

    /// An explicit `stream.cancel()` releases the park exactly once. A second
    /// resume would trap on the checked continuation, so completing at all is
    /// part of the assertion.
    func testExplicitStreamCancelReleasesParkedAppendExactlyOnce() async {
        let handedOff = AwaitableCounter()
        let stream = MockSpeechStream(blocksAppend: true, onAppend: { _ in handedOff.increment() })
        let task = Task { @MainActor in
            do {
                try await stream.append("delta")
                return false
            } catch {
                return (error as? URLError)?.code == .cancelled
            }
        }

        await handedOff.waitUntil(1)
        stream.cancel()
        let wasCancellation = await task.value
        XCTAssertTrue(wasCancellation)

        stream.cancel()
        XCTAssertEqual(stream.cancelCount, 1, "cancel() is idempotent")

        var didThrow = false
        do {
            try await stream.append("after-cancel")
        } catch {
            didThrow = true
        }
        XCTAssertTrue(didThrow, "a cancelled stream refuses later appends")
        XCTAssertEqual(stream.appended, ["delta"], "a refused append is not recorded")
        XCTAssertEqual(stream.cancelCount, 1)
    }

    /// The double supports one parked append at a time. A refused second park
    /// must fail loudly rather than overwrite the slot and leak the first
    /// continuation — that would hang the drain with no diagnostic — and it
    /// must not be published as though the stream had accepted it.
    func testSecondConcurrentParkFailsLoudlyAndIsNotPublished() async {
        let handedOff = AwaitableCounter()
        let stream = MockSpeechStream(blocksAppend: true, onAppend: { _ in handedOff.increment() })
        let first = Task { @MainActor in
            do {
                try await stream.append("first")
                return false
            } catch {
                return (error as? URLError)?.code == .cancelled
            }
        }

        await handedOff.waitUntil(1)
        XCTAssertEqual(stream.appended, ["first"])

        var violation: MockSpeechStreamError?
        do {
            try await stream.append("second")
        } catch let error as MockSpeechStreamError {
            violation = error
        } catch {
            XCTFail("expected MockSpeechStreamError, got \(error)")
        }
        XCTAssertEqual(violation, .concurrentParkedAppend)

        // Acceptance is decided before the append is published, so a refused
        // append cannot satisfy anything that observes the stream — including
        // `waitUntilSpeechAppended`, which counts through `onAppend`.
        XCTAssertEqual(stream.appended, ["first"], "a refused append is not recorded")
        XCTAssertEqual(handedOff.value, 1, "a refused append does not fire onAppend")

        // The original park is still the live one and still releasable.
        stream.cancel()
        let wasCancellation = await first.value
        XCTAssertTrue(wasCancellation, "the first park survives the refused second park")
    }

    /// `cancel()` and task cancellation racing must still resume the park
    /// exactly once — a double resume traps on the checked continuation.
    func testStreamCancelRacingTaskCancellationResumesExactlyOnce() async {
        for cancelFirst in [true, false] {
            let handedOff = AwaitableCounter()
            let stream = MockSpeechStream(blocksAppend: true, onAppend: { _ in handedOff.increment() })
            let task = Task { @MainActor in
                do {
                    try await stream.append("delta")
                    return false
                } catch {
                    return (error as? URLError)?.code == .cancelled
                }
            }

            await handedOff.waitUntil(1)
            if cancelFirst {
                stream.cancel()
                task.cancel()
            } else {
                task.cancel()
                stream.cancel()
            }

            let wasCancellation = await task.value
            XCTAssertTrue(wasCancellation, "cancelFirst=\(cancelFirst)")
            XCTAssertEqual(stream.cancelCount, 1, "cancelFirst=\(cancelFirst)")
        }
    }

    // MARK: - ControlledSuspension

    /// The wait is bounded, and an already-suspended gate must take the fast
    /// path rather than wait out a fresh timeout. The deliberately short second
    /// timeout is what makes the two distinguishable: a missing fast path would
    /// report `false` there.
    func testSuspensionWaitReturnsImmediatelyWhenAlreadySuspended() async {
        let gate = ControlledSuspension()
        let parked = Task { @MainActor in await gate.suspend() }

        // This call cannot return before the suspension is installed, so once
        // it does the gate is provably parked.
        let observed = await gate.awaitSuspension(timeout: 5)
        XCTAssertTrue(observed, "the suspension arrived while a waiter was present")

        let immediate = await gate.awaitSuspension(timeout: 0.2)
        XCTAssertTrue(immediate, "an already-suspended gate must not wait again")

        gate.resume()
        await parked.value
    }

    /// A suspension arriving after the wait began must wake it — in either
    /// order, so the outcome is `true` whether the observer or the suspension
    /// landed first.
    func testSuspensionWaitWakesWhenTheSuspensionArrivesLater() async {
        let gate = ControlledSuspension()
        let waiting = Task { @MainActor in await gate.awaitSuspension(timeout: 5) }
        let parked = Task { @MainActor in await gate.suspend() }

        let observed = await waiting.value
        XCTAssertTrue(observed, "a suspension arriving after the wait must wake it")

        gate.resume()
        await parked.value
    }

    /// The timeout path must return instead of hanging, and must not leave the
    /// expired observer installed. A stale observer would be resumed a second
    /// time by the later `suspend()` and trap on the checked continuation, so
    /// reaching the final assertions at all is part of the proof.
    func testSuspensionWaitTimesOutWithoutLeavingAStaleObserver() async {
        let gate = ControlledSuspension()

        let timedOut = await gate.awaitSuspension(timeout: 0.15)
        XCTAssertFalse(timedOut, "no suspension arrived, so the bounded wait expires")

        // A later suspension is a fresh observation, not a resume of the waiter
        // that already gave up.
        let parked = Task { @MainActor in await gate.suspend() }
        let observed = await gate.awaitSuspension(timeout: 5)
        XCTAssertTrue(observed, "a post-timeout suspension must still be observable")

        gate.resume()
        await parked.value
    }

    /// `suspend()` is never bounded — the parked operation stays parked until
    /// the test releases it — and `resume()` clears the suspension.
    func testResumeStillReleasesAnObservedSuspension() async {
        let gate = ControlledSuspension()
        let parked = Task { @MainActor in await gate.suspend() }
        let observed = await gate.awaitSuspension(timeout: 5)
        XCTAssertTrue(observed)

        gate.resume()
        await parked.value

        let stillSuspended = await gate.awaitSuspension(timeout: 0.15)
        XCTAssertFalse(stillSuspended, "resume() clears the suspension")
    }

    // MARK: - InterruptParkingGate

    /// "Entered" means *at least* once: a gate entered twice before the waiter
    /// runs satisfies the condition. A strict `== 1` assertion belongs at the
    /// call site that owns that invariant, not in the generic waiter.
    func testParkingGateEntryWaitAcceptsMoreThanOneEntry() async {
        let gate = InterruptParkingGate()
        let first = Task { @MainActor in await gate.waitInInterrupt() }
        let second = Task { @MainActor in await gate.waitInInterrupt() }

        // Fence both entries before the waiter runs, so the count it observes
        // is genuinely above one.
        await gate.waitUntilEntryCount(2, timeout: 5)
        XCTAssertEqual(gate.count, 2, "both interruptions reached the gate")

        await gate.waitUntilEntered()
        XCTAssertEqual(gate.count, 2, "a count above one must not read as a missing entry")

        gate.release()
        await first.value
        await second.value
    }

    // MARK: - GatedTranscriptionGateway release contract

    private var sampleAudio: VoiceCapturedAudio {
        VoiceCapturedAudio(wavData: Data([1]), pcm16Data: Data([1, 0]), sampleRate: 16_000, duration: 0.01)
    }

    /// Normal release: the parked transcription completes and the gate stops
    /// accepting parks.
    func testReleaseTranscriptionCompletesTheParkAndDisarms() async {
        let gateway = GatedTranscriptionGateway(transcript: "late")
        let parked = Task { @MainActor in try? await gateway.transcribe(sampleAudio) }
        await gateway.waitUntilTranscribing()

        gateway.releaseTranscription()
        let first = await parked.value
        XCTAssertEqual(first, "late", "release completes the parked transcription")
        XCTAssertTrue(gateway.isReleased, "release disarms the gate")

        // Disarmed, the early guard in `transcribe` short-circuits — which is
        // why this second call cannot park.
        let second = try? await gateway.transcribe(sampleAudio)
        XCTAssertEqual(second, "late", "a disarmed gate returns without parking")
    }

    /// Regression: task cancellation consumes the parked continuation, so a
    /// release that returned early on a nil continuation left the gate armed —
    /// the next transcription then parked on a gate the test had already
    /// released. Release must disarm whether or not a continuation is parked.
    func testReleaseAfterCancellationStillDisarmsTheGate() async {
        let gateway = GatedTranscriptionGateway(transcript: "late")
        let parked = Task { @MainActor in
            do {
                _ = try await gateway.transcribe(sampleAudio)
                return "returned"
            } catch {
                return "cancelled"
            }
        }
        await gateway.waitUntilTranscribing()

        parked.cancel()
        let outcome = await parked.value
        XCTAssertEqual(outcome, "cancelled", "the cancellation handler consumed the park")
        XCTAssertFalse(gateway.isReleased, "cancellation alone must not disarm the gate")

        gateway.releaseTranscription()
        XCTAssertTrue(
            gateway.isReleased,
            "release must disarm even when no continuation was parked"
        )

        // A failed assertion above does not abort the test, and with the gate
        // still armed the call below would park forever — so make the hang
        // guard explicit.
        guard gateway.isReleased else { return }
        let later = try? await gateway.transcribe(sampleAudio)
        XCTAssertEqual(later, "late", "the disarmed gate returns without parking")
    }
}
