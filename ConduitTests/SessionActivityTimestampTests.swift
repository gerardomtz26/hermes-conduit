import XCTest
@testable import Conduit

/// The ordering instant session rows carry for "jump to latest activity".
/// Values are normalized (milliseconds → seconds) and a row whose FIRST
/// activity field is present but unusable has NO ordering evidence — falling
/// through to a weaker field would substitute a different instant for the one
/// the gateway chose.
@MainActor
final class SessionActivityTimestampTests: XCTestCase {
    func testNumericSecondsAndMillisecondsNormalizeToTheSameInstant() throws {
        let seconds = try XCTUnwrap(
            MessageNormalizer.sessionActivityTimestamp(in: ["last_active": .number(1_700_000_000)])
        )
        let milliseconds = try XCTUnwrap(
            MessageNormalizer.sessionActivityTimestamp(in: ["last_active": .number(1_700_000_000_000)])
        )

        XCTAssertEqual(seconds, 1_700_000_000)
        XCTAssertEqual(milliseconds, 1_700_000_000)
    }

    func testNumericStringsAreAccepted() throws {
        XCTAssertEqual(
            try XCTUnwrap(
                MessageNormalizer.sessionActivityTimestamp(in: ["updated_at": .string("1700000000")])
            ),
            1_700_000_000
        )
    }

    func testMissingOrNullFieldFallsThroughToTheNextKey() throws {
        XCTAssertEqual(
            try XCTUnwrap(
                MessageNormalizer.sessionActivityTimestamp(in: [
                    "last_active": .null,
                    "created_at": .number(1_700_000_000)
                ])
            ),
            1_700_000_000
        )
        XCTAssertEqual(
            try XCTUnwrap(
                MessageNormalizer.sessionActivityTimestamp(in: [
                    "updated_at": .number(1_700_000_000)
                ])
            ),
            1_700_000_000
        )
    }

    /// A present but unusable preferred value stops the scan: the row is
    /// treated as undated rather than given an older `created_at` instant that
    /// describes a different moment.
    func testUnusablePreferredValueYieldsNoInstantInsteadOfAnOlderField() {
        XCTAssertNil(
            MessageNormalizer.sessionActivityTimestamp(in: [
                "last_active": .string("yesterday"),
                "created_at": .number(1_700_000_000)
            ])
        )
        XCTAssertNil(
            MessageNormalizer.sessionActivityTimestamp(in: [
                "last_active": .bool(true),
                "created_at": .number(1_700_000_000)
            ])
        )
    }

    func testZeroAndNonFiniteValuesAreRejected() {
        XCTAssertNil(MessageNormalizer.sessionActivityTimestamp(in: ["last_active": .number(0)]))
        XCTAssertNil(MessageNormalizer.sessionActivityTimestamp(in: ["last_active": .number(-5)]))
        XCTAssertNil(MessageNormalizer.sessionActivityTimestamp(in: ["last_active": .number(.infinity)]))
        XCTAssertNil(MessageNormalizer.sessionActivityTimestamp(in: ["last_active": .number(.nan)]))
    }

    func testNoActivityKeysYieldsNoInstant() {
        XCTAssertNil(MessageNormalizer.sessionActivityTimestamp(in: ["title": .string("Design review")]))
    }
}
