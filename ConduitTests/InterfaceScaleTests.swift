//
//  InterfaceScaleTests.swift
//  ConduitTests
//
//  Contract for the whole-interface scale preference: the default must be a
//  strict no-op (existing users keep today's appearance), resolution must
//  never trap on stored garbage, and the steps must be monotonic so a step
//  up can never render smaller than the step below it.
//

import XCTest
import SwiftUI
@testable import Conduit

final class InterfaceScaleTests: XCTestCase {

    func testDefaultIsSystemAndAppliesNoOverride() {
        XCTAssertEqual(InterfaceScale.defaultScale, .system)
        XCTAssertNil(
            InterfaceScale.system.dynamicTypeSizeOverride,
            "System writes no Dynamic Type override — the device setting rules, byte for byte"
        )
    }

    func testResolveFallsBackToSystemInsteadOfTrapping() {
        XCTAssertEqual(InterfaceScale.resolve(rawValue: nil), .system)
        XCTAssertEqual(InterfaceScale.resolve(rawValue: -1), .system)
        XCTAssertEqual(InterfaceScale.resolve(rawValue: 99), .system)
        XCTAssertEqual(InterfaceScale.stored(in: UserDefaults(suiteName: "conduit.tests.empty.\(UUID().uuidString)")!), .system)
    }

    func testStepsAreMonotonicallyOrdered() {
        // Raw ordering is the persisted contract; Dynamic Type ordering is
        // the rendered one. Both must ascend with the enum declaration.
        var previousRaw = -1
        var previousSize: DynamicTypeSize?
        for scale in InterfaceScale.allCases {
            XCTAssertGreaterThan(scale.rawValue, previousRaw, "\(scale) must come after its predecessor")
            previousRaw = scale.rawValue

            guard let size = scale.dynamicTypeSizeOverride else {
                XCTAssertNil(previousSize, "Only .system may carry no override, and only before any sized step")
                continue
            }
            if let previousSize {
                XCTAssertLessThan(
                    previousSize, size,
                    "\(scale) must render at least as large as the step below it"
                )
            }
            previousSize = size
        }
    }

    func testStoredRoundTripUsesTheCallerDefaults() {
        let suiteName = "conduit.tests.interfaceScale.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(InterfaceScale.stored(in: defaults), .system, "Nothing written yet")

        defaults.set(InterfaceScale.larger.rawValue, forKey: InterfaceScale.preferenceKey)
        XCTAssertEqual(InterfaceScale.stored(in: defaults), .larger)
    }
}
