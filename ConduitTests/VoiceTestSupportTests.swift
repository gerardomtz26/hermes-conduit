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
        XCTAssertEqual(stream.cancelCount, 1)
    }

    /// The double supports one parked append at a time. A second concurrent
    /// park must fail loudly rather than overwrite the slot and leak the first
    /// continuation — that would hang the drain with no diagnostic.
    func testSecondConcurrentParkFailsLoudlyInsteadOfLeakingTheFirst() async {
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

        var violation: MockSpeechStreamError?
        do {
            try await stream.append("second")
        } catch let error as MockSpeechStreamError {
            violation = error
        } catch {
            XCTFail("expected MockSpeechStreamError, got \(error)")
        }
        XCTAssertEqual(violation, .concurrentParkedAppend)

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
}
