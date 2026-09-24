import Foundation
import XCTest
@testable import Conduit

/// Server→client requests are how the gateway asks the app a question
/// (clarify, approval): a JSON-RPC request with a STRING `srq-…` id, answered
/// by a response frame carrying the same id. Two things must hold or the poll
/// never reaches the screen: the frame decodes at all (`JsonRpcResponse`
/// rejects string ids, so without a second shape every question was logged as
/// "undecodable" and dropped), and a client that re-attaches rebuilds the card
/// from `open_requests`, because the one-shot request never reaches a
/// process that was detached when it fired.
final class ServerRequestTests: XCTestCase {

    private func decode(_ json: String) -> JsonRpcServerRequest? {
        try? JSONDecoder().decode(JsonRpcServerRequest.self, from: Data(json.utf8))
    }

    // MARK: - Frame decoding

    func testDecodesClarifyRequestWithStringId() {
        let request = decode(#"""
        {"jsonrpc":"2.0","id":"srq-0123456789ab","method":"clarify",
         "params":{"session_id":"s1","question":"Which env?","choices":["staging","prod"],"multi_select":false}}
        """#)
        XCTAssertEqual(request?.id, "srq-0123456789ab")
        XCTAssertEqual(request?.method, "clarify")
        XCTAssertEqual(request?.params?.objectValue?["question"]?.stringValue, "Which env?")
        XCTAssertEqual(request?.params?.objectValue?["session_id"]?.stringValue, "s1")
    }

    func testIntegerIdResponseIsNotARequest() {
        // Responses keep integer ids and are matched against `pending`,
        // never dispatched as questions.
        XCTAssertNil(decode(#"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#))
    }

    func testEventNotificationIsNotARequest() {
        // Notifications carry a `method` but no `id` at all: they route
        // through `handleStreamEvent`, and must not be mistaken for a
        // question that owes the gateway a response frame.
        XCTAssertNil(decode(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready"}}"#))
    }

    // MARK: - Reconnect replay (`open_requests`)

    func testReplayedClarifyBecomesPendingClarify() {
        let snapshot = SessionRuntimeSnapshot(object: [
            "running": .bool(true),
            "open_requests": .array([
                .object([
                    "id": .string("srq-aabbccddeeff"),
                    "method": .string("clarify"),
                    "params": .object([
                        "session_id": .string("s1"),
                        "question": .string("Which env?"),
                        "choices": .array([.string("staging"), .string("prod")])
                    ])
                ])
            ])
        ])

        let activity = snapshot.pendingClarify
        // The frame id becomes the card's request id: it is the only address
        // a response frame can be sent to.
        XCTAssertEqual(activity?.requestId, "srq-aabbccddeeff")
        XCTAssertEqual(activity?.questions.count, 1)
        XCTAssertEqual(activity?.questions.first?.question, "Which env?")
        XCTAssertEqual(activity?.questions.first?.choices.map(\.value), ["staging", "prod"])
    }

    func testReplayedBatchClarifyKeepsGatewayQids() {
        let snapshot = SessionRuntimeSnapshot(object: [
            "open_requests": .array([
                .object([
                    "id": .string("srq-000000000001"),
                    "method": .string("clarify"),
                    "params": .object([
                        "session_id": .string("s1"),
                        "questions": .array([
                            .object(["qid": .string("q1"), "question": .string("First?")]),
                            .object(["qid": .string("q2"), "question": .string("Second?")])
                        ])
                    ])
                ])
            ])
        ])

        XCTAssertEqual(snapshot.pendingClarify?.requestId, "srq-000000000001")
        // Real qids are what `clarify.lock` keys on; they must survive replay.
        XCTAssertEqual(snapshot.pendingClarify?.questions.map(\.id), ["q1", "q2"])
    }

    func testReplayedClarifyRestoresLockedAnswers() {
        let snapshot = SessionRuntimeSnapshot(object: [
            "open_requests": .array([
                .object([
                    "id": .string("srq-000000000002"),
                    "method": .string("clarify"),
                    "params": .object([
                        "session_id": .string("s1"),
                        "questions": .array([
                            .object(["qid": .string("q1"), "question": .string("First?")]),
                            .object(["qid": .string("q2"), "question": .string("Second?")])
                        ]),
                        "answers": .object(["q1": .string("staging")])
                    ])
                ])
            ])
        ])

        XCTAssertEqual(snapshot.pendingClarify?.questions.first?.status, .answered)
        XCTAssertEqual(snapshot.pendingClarify?.questions.first?.answer, "staging")
        XCTAssertEqual(snapshot.pendingClarify?.questions.last?.status, .pending)
    }

    func testReplayedApprovalBecomesPendingApproval() {
        let snapshot = SessionRuntimeSnapshot(object: [
            "open_requests": .array([
                .object([
                    "id": .string("srq-111122223333"),
                    "method": .string("approval"),
                    "params": .object([
                        "session_id": .string("s1"),
                        "request_id": .string("appr-9"),
                        "command": .string("rm -rf build"),
                        "description": .string("Delete the build directory")
                    ])
                ])
            ])
        ])

        XCTAssertEqual(snapshot.pendingApprovalPayload?["request_id"]?.stringValue, "appr-9")
        XCTAssertNil(snapshot.pendingClarify)
    }

    func testExplicitSnapshotsWinOverReplay() {
        let snapshot = SessionRuntimeSnapshot(object: [
            "pending_clarify": .object([
                "request_id": .string("explicit-1"),
                "question": .string("From the snapshot?")
            ]),
            "open_requests": .array([
                .object([
                    "id": .string("srq-999999999999"),
                    "method": .string("clarify"),
                    "params": .object(["session_id": .string("s1"), "question": .string("From the replay?")])
                ])
            ])
        ])

        XCTAssertEqual(snapshot.pendingClarify?.requestId, "explicit-1")
    }

    func testUnsupportedOpenRequestIsIgnored() {
        // `sudo` / `secret` / vault prompts have no card in this build: they
        // must not synthesise a decision the UI cannot render.
        let snapshot = SessionRuntimeSnapshot(object: [
            "open_requests": .array([
                .object([
                    "id": .string("srq-aaaaaaaaaaaa"),
                    "method": .string("sudo"),
                    "params": .object(["session_id": .string("s1"), "command": .string("whoami")])
                ])
            ])
        ])

        XCTAssertNil(snapshot.pendingClarify)
        XCTAssertNil(snapshot.pendingApprovalPayload)
    }
}
