import Foundation
import XCTest

final class InterfaceOrientationTests: XCTestCase {
    // The fork signs as com.gerardomtz26.conduit.dev (Gerardo's Personal Team)
    // while the original ships as com.milim.relay, so looking the app up by
    // that identifier returned nil and BOTH tests died at the unwrap without
    // ever reading an orientation. Read the host bundle instead — but keep
    // reading Info.plist as a FILE: `Bundle.main.infoDictionary` comes back
    // with the `~ipad` modifier already resolved on an iPad simulator, which
    // makes the iPhone assertion see the iPad rotation list.
    private func appInfoDictionary() throws -> [String: Any] {
        let infoData = try Data(
            contentsOf: Bundle.main.bundleURL.appendingPathComponent("Info.plist")
        )
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
        )
    }

    func testUniversalOrientationsRemainPortraitOnlyForIPhone() throws {
        let info = try appInfoDictionary()
        XCTAssertEqual(
            info["UISupportedInterfaceOrientations"] as? [String],
            ["UIInterfaceOrientationPortrait"]
        )
    }

    func testIPadOrientationsIncludeBothLandscapeDirections() throws {
        let info = try appInfoDictionary()
        XCTAssertEqual(
            info["UISupportedInterfaceOrientations~ipad"] as? [String],
            [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationPortraitUpsideDown",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight"
            ]
        )
        XCTAssertNil(info["UIRequiresFullScreen"])
    }
}
