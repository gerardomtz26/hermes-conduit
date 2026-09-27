# Hermes Conduit

A native iOS client for [Hermes Agent](https://github.com/NousResearch/hermes-agent). Free, no ads, no tracking.

[![App Store](https://img.shields.io/badge/App_Store-Hermes_Conduit-blue)](https://apps.apple.com/us/app/hermes-conduit/id6790977764)
[![Website](https://img.shields.io/badge/Website-hermesconduit.app-blue)](https://hermesconduit.app)

<!-- ===== FORK SECTION · does not exist upstream ===== -->
## Differences from the original (gerardomtz26's fork)

This clone of [kaishi00/hermes-conduit](https://github.com/kaishi00/hermes-conduit) is worked on the **`build-local`** branch; this repo's `main` carries no work of its own — it is only a mirror of the original's `main`, so if GitHub ever shows it "N commits behind", that is why: it is a snapshot of the original, not a lagging copy. The `.ipa` builds are signed with a free local developer account and distributed over iCloud, not through the App Store.

Measured 2026-09-26: `build-local` runs **22 commits ahead** of the original (21 of its own plus the alignment merge) and **75 behind**. Last alignment: **2026-09-25** (`826a3bb`, which brought 78 commits from the original).

### What this repo has that the original doesn't

| Area | Difference |
|---|---|
| Clarify | Fix for the `server→client requests` contract (build 147): clarify cards are answered and arrive live from the gateway instead of only showing up as history JSON; the raw tool row no longer renders beside the card. Own tests: `ServerRequestTests`. |
| Colors | Blue accent with a bubble fill that can actually carry white text, plus a 5-palette picker in Settings → Appearance under a WCAG contrast contract (`AccentPaletteTests` is the contract). AMOLED mode existed (builds 150–152) and was retired. |
| Text scale | `InterfaceScaleFont` bridges the environment's Dynamic Type into the ~17 UIKit `preferredFont` call sites; the custom scale selectors were retired — the iOS slider is the only size control. |
| Markdown | Settled cards re-read the environment's dynamic type (closes the long-standing SettledMessageIsolation red). |
| Subagents | Delegate cards are keyed by the gateway's `subagent_id`: finished ones drop off on their own instead of lingering until relaunch. |
| Interface | Floating Liquid Glass bar over the conversation (build 158); segment-control navigation — chats · kanban · subagents with a live activity dot — and the persistent iPad sidebar retired (build 159). |
| Fork-blind tests | 3 tests read the host bundle's `Info.plist` instead of the original `com.milim.relay` id (iPad/iPhone orientations and the Tailscale ATS rule); `SidebarLayoutTests` was retired along with the sidebar. |

### What the original has that here is missing (75 commits · measured 2026-09-26)

They land with the next alignment (a merge, never a rebase):

- **Offline chat** (issue-99, #223/#227/#229): an offline copy of transcripts that survives account or dashboard switches, and saved rows that don't drop when a session closes.
- **Media** (#195/#225/#226): full-screen previews with save and share; previews that are lighter on memory and the main thread.
- **Voice**: audio-engine recovery — −10868 errors are classified as recoverable, engines start clean, and the media-services reset no longer blows up.
- **Composer** (#194): the microphone only appears when the profile has voice enabled; a single mic/send slot.
- **Notifications** (#228): approval and input sounds (`attention_sound`).
- Fixes for scroll (overshoot), the text-size gate, an ASCII-only mention query, and Group Chat labels. CI (`.github/workflows/ci.yml`) is already up to date — nothing missing there.

> This section belongs to the fork: if a merge with the original conflicts here, keep this version and only update its numbers.

<!-- ===== END FORK SECTION ===== -->

## What it does

Conduit connects directly to your self-hosted Hermes dashboard. Same sessions, same profiles, same capabilities as the desktop client. No relay service, no extra processes, no middleman.

Start a conversation on desktop, pick it up on your phone. The session list is the same because it is the same database.

## Features

- **Streaming chat** with full Markdown (code blocks, math, Mermaid, task lists)
- **Tool call inspection** and reasoning traces
- **Voice mode** with push-to-talk, on-device speech recognition, server-side Whisper
- **Image, PDF, and text attachments**
- **Model switching** and reasoning effort controls
- **Slash commands** and workspace file browsing
- **Session branching, pinning, and archiving**
- **Capabilities tab** to toggle skills, tools, and MCP servers
- **Scheduled jobs** viewer and connector monitoring
- **Multi-profile support** with per-profile settings
- **Push notifications** for approvals, completed turns, failures, and background tasks
- **Inline approvals** so you can approve or reject tool calls without typing
- **Face ID** lock and credential storage

## Requirements

- iOS 17 or later
- iPhone or iPad
- A running Hermes Agent instance with the native dashboard enabled (default port 9119)

## Connecting

1. Make sure your Hermes dashboard is running. If you are not sure, ask your agent: `is the dashboard running?`
2. Find your dashboard address. It is usually `http://your-server-ip:9119`.
3. Open Conduit and enter that address on the login screen.
4. Log in with your dashboard credentials.

**Note:** Conduit connects to the native Hermes dashboard, not the WebUI. The default port is 9119.

If your server is not on your local network, use Tailscale or a reverse proxy to reach it from your phone. Plain HTTP over Tailscale (MagicDNS `.ts.net` domains and `100.64.0.0/10` tailnet IPs) is supported — the traffic is already WireGuard-encrypted.

If the dashboard is behind Cloudflare Access, enable the optional service token on the login screen or in Settings > Connection > Gateway. Conduit stores the client secret in Keychain (scoped to the gateway origin), and injects both Access headers into native authentication requests, WebSocket handshakes, and all in-page WebKit fetches via a document-start user script. Credentials are bound to the gateway URL and cleared when switching to a different host.

**Native OAuth limitation:** service-token headers cannot be attached to the system Safari navigation that opens `/auth/native/authorize`. Native OAuth therefore requires that browser authorization route to be reachable through an interactive Cloudflare policy or without a service-token challenge. The token exchange, refresh, REST, and WebSocket-ticket requests still use the configured service-token headers. A service-token-only challenge in front of the authorize route cannot be bypassed by Conduit and must not silently fall back to embedded Google OAuth.

## Push Notifications

Push notifications require a small relay service because iOS does not allow apps to maintain persistent background connections. The relay source is in the `hermes-conduit-notifier` plugin and the push relay server.

To set up push notifications, install the notifier plugin on your Hermes instance:

```
hermes plugins install kaishi00/hermes-conduit-notifier --enable
hermes gateway restart
```

Then follow the in-app pairing flow under Settings > Notifications.

The app uses a shared relay by default (`push.milim.dev`) so notifications work out of the box with no extra setup. If you prefer to run your own relay, enter its URL under Settings > Notifications > Push relay.

## Building from source

```
git clone https://github.com/kaishi00/hermes-conduit.git
cd hermes-conduit
brew install xcodegen
xcodegen generate
open Conduit.xcodeproj
```

Select your team in Signing & Capabilities, then build and run on your device.

**Requirements:**
- Xcode 16 or later
- iOS 17 SDK
- [xcodegen](https://github.com/yonaskolb/XcodeGen)

## Releasing

See [the iOS release workflow](docs/RELEASE_WORKFLOW.md) for the TestFlight and App Store release process.

## Architecture

Conduit is pure SwiftUI targeting iOS 17+. The project uses xcodegen for Xcode project generation from `project.yml`.

The app connects to the Hermes dashboard WebSocket endpoint (`/api/ws`) after authenticating through the dashboard login page. All RPC calls route through the dashboard, same as the desktop client. The gateway is never contacted directly.

Key files:
- `Conduit/Services/HermesClient.swift` - WebSocket client and RPC layer
- `Conduit/Services/AppState.swift` - Main state management and session lifecycle
- `Conduit/Services/DashboardTicketBridge.swift` - Authentication bridge
- `Conduit/Views/ChatView.swift` - Chat interface with streaming
- `Conduit/Voice/` - Voice mode pipeline

## Privacy

Conduit does not collect, transmit, or store your data on any third-party server. All communication goes directly between the app and your own Hermes instance. The only external connection is the optional push relay, which you control and can self-host.

No analytics. No telemetry. No ad frameworks.

## Support

- Website: [hermesconduit.app](https://hermesconduit.app)
- Bug reports: [GitHub issues](https://github.com/kaishi00/hermes-conduit/issues)
- Email: [developer@hermesconduit.app](mailto:developer@hermesconduit.app)

## License

MIT

## Disclaimer

Hermes Conduit is an independent project and is not affiliated with or endorsed by Nous Research.
