import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// Gerardo's report (2026-09-26): raising the text size resizes the chat
/// messages, but the clarify card's own letters stay the same size.
///
/// The card hands its body text to UIKit through `SelectableTextView`, whose
/// font is `UIFont.preferredFont(forTextStyle:)` — a UIKit API that reads the
/// app's content-size category, not SwiftUI's `\.dynamicTypeSize` environment,
/// which is what actually moves (the iOS text-size slider; the app has no
/// selector of its own anymore). The gap is closed by the read-side bridge
/// (`InterfaceScaleFont`). The header, every question title
/// and the question body go through that path (`ChatView.swift` ClarifyCard /
/// ClarifyQuestionRow); the small SwiftUI `.caption` labels do not.
///
/// So: mount the SAME card at the two Dynamic Type sizes, and the fonts its
/// text views end up with must grow. This fails while the card's letters
/// ignore the environment, which is exactly what Gerardo sees on the iPad.
@MainActor
final class ClarifyCardScaleTests: XCTestCase {
    private var window: UIWindow?

    private func makeAppState() throws -> AppState {
        let suiteName = "clarify-card-scale-tests"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName),
            "test UserDefaults suite must initialize"
        )
        defaults.removePersistentDomain(forName: suiteName)
        return AppState(defaults: defaults, loadSavedConnection: false)
    }

    private func clarifyMessage() -> ChatMessage {
        ChatMessage(
            id: "m1",
            role: .assistant,
            content: "Which route should the next step take?",
            timestamp: "2026-01-01T00:00:00Z",
            clarify: ClarifyActivity(
                requestId: "srq-1",
                questions: [
                    ClarifyQuestion(
                        id: "q1",
                        question: "Which of these two routes should I take next?",
                        choices: [
                            ClarifyChoice(label: "First option", value: "a"),
                            ClarifyChoice(label: "Second option", value: "b")
                        ]
                    )
                ]
            )
        )
    }

    /// Mounts the card at one scale in a live window and returns every
    /// `SelectableTextView` font point size it ended up painting with, in
    /// tree order — that list is the card's letters, measured where they are
    /// actually drawn.
    private func mountedFontPointSizes(
        at scale: DynamicTypeSize,
        message: ChatMessage,
        appState: AppState
    ) throws -> [CGFloat] {
        let root = ClarifyCard(message: message)
            .environmentObject(appState)
            .dynamicTypeSize(scale)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date())
        return Self.selectableTextFontPointSizes(in: host.view)
    }

    private static func selectableTextFontPointSizes(in view: UIView) -> [CGFloat] {
        var sizes: [CGFloat] = []
        for subview in view.subviews {
            if let hostView = subview as? SelectableTextViewHostView,
               let font = hostView.mountedTextView.font {
                sizes.append(font.pointSize)
            }
            sizes.append(contentsOf: selectableTextFontPointSizes(in: subview))
        }
        return sizes
    }

    func testClarifyCardLettersGrowWithInterfaceScale() throws {
        let appState = try makeAppState()
        let message = clarifyMessage()

        let atLarge = try mountedFontPointSizes(at: .large, message: message, appState: appState)
        let atXXXLarge = try mountedFontPointSizes(at: .xxxLarge, message: message, appState: appState)

        XCTAssertFalse(atLarge.isEmpty, "the card must mount its text views to measure anything")
        XCTAssertEqual(
            atLarge.count, atXXXLarge.count,
            "both scales must mount the same card, letter for letter"
        )

        for (small, large) in zip(atLarge, atXXXLarge) {
            XCTAssertGreaterThan(
                large, small,
                "the clarify card's letters must grow with the interface scale — "
                    + "Gerardo sees them stay put on the iPad (2026-09-26)"
            )
        }
    }
}
