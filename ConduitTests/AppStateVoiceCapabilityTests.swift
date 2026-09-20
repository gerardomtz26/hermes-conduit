//
//  AppStateVoiceCapabilityTests.swift
//  Conduit
//
//  AppState-level voice capability gating: Hermes transcription availability
//  follows the profile config and the live transcription attempt — never the
//  provider picker's readiness metadata — while the Apple on-device route
//  stays gated only by its own permission/availability checks.
//

import XCTest
@testable import Conduit

@MainActor
final class AppStateVoiceCapabilityTests: XCTestCase {
    /// The Reddit reproduction at the AppState layer: with the selected
    /// OpenAI provider ready (and the parser keeping the Nous Subscription
    /// row's needs_auth state on its own row), the composer mic stays usable.
    func testReadySelectedTranscriptionKeepsVoiceConversationAvailable() {
        let appState = makeAppState(
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: true,
                supportsSpeech: true,
                unavailableReason: nil
            )
        )

        XCTAssertNil(appState.voiceUnavailableReason)
        XCTAssertTrue(appState.canStartVoiceConversation)
    }

    func testDisabledHermesTranscriptionStillBlocksVoiceConversation() {
        let appState = makeAppState(
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: false,
                supportsSpeech: true,
                unavailableReason: "Speech-to-text is disabled for this Hermes profile."
            )
        )

        XCTAssertEqual(appState.voiceUnavailableReason, "Speech-to-text is disabled for this Hermes profile.")
        XCTAssertFalse(appState.canStartVoiceConversation)
    }

    /// The Apple on-device route must not consult Hermes provider readiness:
    /// a profile with no ready Hermes STT still allows on-device dictation.
    func testAppleOnDeviceModeDoesNotConsultHermesTranscriptionReadiness() {
        let appState = makeAppState(
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: false,
                supportsSpeech: true,
                unavailableReason: nil
            ),
            transcriptionMode: .appleOnDevice,
            appleSpeechAvailability: .ready(localeIdentifier: "en-US")
        )

        XCTAssertNil(appState.voiceUnavailableReason)
        XCTAssertTrue(appState.canStartVoiceConversation)
    }

    /// Independence cuts both ways: the Apple route is still gated by its own
    /// Speech Recognition permission state, not by Hermes metadata.
    func testAppleOnDeviceModeStillHonorsItsOwnPermissionGate() {
        let appState = makeAppState(
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: true,
                supportsSpeech: true,
                unavailableReason: nil
            ),
            transcriptionMode: .appleOnDevice,
            appleSpeechAvailability: .permissionDenied
        )

        XCTAssertEqual(
            appState.voiceUnavailableReason,
            "Allow Speech Recognition in iOS Settings to use on-device transcription."
        )
    }

    /// Uncertainty on the Apple route (permission not yet granted) does not
    /// block the mic — only an outright denial or unsupported locale does.
    func testApplePermissionRequiredDoesNotBlockVoiceConversation() {
        let appState = makeAppState(
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: false,
                supportsSpeech: true,
                unavailableReason: nil
            ),
            transcriptionMode: .appleOnDevice,
            appleSpeechAvailability: .permissionRequired(localeIdentifier: "en-US")
        )

        XCTAssertNil(appState.voiceUnavailableReason)
        XCTAssertTrue(appState.canStartVoiceConversation)
    }

    /// Build-146 regression guard. Voice settings is a foreground screen that
    /// presents no Voice sheet, so the *capture* gate is closed there while
    /// the app-foreground gate must stay open: selecting "On this iPhone"
    /// asks iOS for permissions, and the settings-launched provider tests run
    /// capture — all legitimate with the app on screen. Reading the capture
    /// gate for those silently refused the selection (no mode change, no
    /// surfaced error), which is the regression this pins.
    func testVoiceSettingsSurfaceStateKeepsTheApplicationForegroundGateOpen() {
        let appState = makeReadyAppState()

        // Leave and re-enter the foreground — the transition that republishes
        // both gates — with the phone Voice sheet closed throughout: exactly
        // the state Voice settings is in.
        _ = appState.handleScenePhase(.background)
        XCTAssertFalse(appState.voiceConversationController.isApplicationForegroundGateOpen)
        let foreground = appState.handleScenePhase(.active)
        // The gate publication is synchronous; the reconciliation task it
        // also starts is not what this test covers.
        foreground?.cancel()

        XCTAssertFalse(appState.hasActiveVoiceSurface, "No Voice surface presents while the user is in Voice settings")
        XCTAssertTrue(appState.hasForegroundApplicationSurface)
        XCTAssertTrue(appState.voiceConversationController.isApplicationForegroundGateOpen)
    }

    /// The gate that must still close: iOS presents permission alerts only
    /// for a foreground app.
    func testBackgroundingClosesTheApplicationForegroundGate() {
        let appState = makeReadyAppState()
        appState.reassertVoiceSurfaceGate()

        _ = appState.handleScenePhase(.background)

        XCTAssertFalse(appState.voiceConversationController.isApplicationForegroundGateOpen)
    }

    /// CarPlay is the other app-foreground surface: presenting it keeps the
    /// gate open with the phone locked, and losing it closes the gate again.
    func testCarPlaySurfaceDrivesTheApplicationForegroundGateWhileThePhoneIsBackgrounded() {
        let appState = makeReadyAppState()
        _ = appState.handleScenePhase(.background)

        appState.setCarPlayVoiceSurfaceActive(true)
        XCTAssertTrue(appState.voiceConversationController.isApplicationForegroundGateOpen)

        appState.setCarPlayVoiceSurfaceActive(false)
        XCTAssertFalse(appState.voiceConversationController.isApplicationForegroundGateOpen)
    }

    private func makeReadyAppState() -> AppState {
        makeAppState(
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: true,
                supportsSpeech: true,
                unavailableReason: nil
            )
        )
    }

    private func makeAppState(
        snapshot: VoiceCapabilitySnapshot,
        transcriptionMode: VoiceTranscriptionMode = .hermes,
        appleSpeechAvailability: AppleSpeechRecognitionAvailability = .ready(localeIdentifier: "en-US")
    ) -> AppState {
        let suite = "AppStateVoiceCapabilityTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }

        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        appState.isConnected = true
        appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            snapshot: snapshot,
            isVoiceEnabled: true,
            transcriptionMode: transcriptionMode,
            appleSpeechAvailability: appleSpeechAvailability
        )
        return appState
    }
}
