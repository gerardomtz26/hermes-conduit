# Hermes Conduit

A native iOS client for [Hermes Agent](https://github.com/NousResearch/hermes-agent). Free, no ads, no tracking.

[![App Store](https://img.shields.io/badge/App_Store-Hermes_Conduit-blue)](https://apps.apple.com/us/app/hermes-conduit/id6790977764)
[![Website](https://img.shields.io/badge/Website-hermesconduit.app-blue)](https://hermesconduit.app)

<!-- ===== SECCIÓN DEL FORK · no existe en el original ===== -->
## Diferencias con el original (fork de gerardomtz26)

Este clon de [kaishi00/hermes-conduit](https://github.com/kaishi00/hermes-conduit) se trabaja en la rama **`build-local`**; el `main` de este repo no lleva trabajo propio, es solo espejo del `main` del original (por eso el aviso de «153 commits atrás»: no es una copia desfasada, es una rama que no se mueve). Los `.ipa` se firman con cuenta de desarrollo gratuita en esta máquina y se reparten por iCloud, no por la App Store.

Estado medido el **2026-09-26**: `build-local` va **22 commits delante** del original (21 propios + el merge de alineación) y **75 detrás**. Última alineación: **2026-09-25** (`826a3bb`, trajo 78 commits del original).

### Lo que este repo tiene y el original no

| Área | Diferencia |
|---|---|
| Clarify | Arreglo del contrato `server→client requests` (build 147): las fichas de clarify se contestan y llegan en vivo desde el gateway, no solo como JSON del historial; la fila de herramienta cruda ya no se dibuja junto a la ficha. Tests propios: `ServerRequestTests`. |
| Colores | Acento azul con una burbuja que sí sostiene texto blanco, selector de 5 paletas en Ajustes → Apariencia con contrato de contraste WCAG (`AccentPaletteTests` es el contrato). El modo AMOLED existió (builds 150–152) y se retiró. |
| Escala de texto | `InterfaceScaleFont` puentea el Dynamic Type del ambiente a las ~17 llamadas UIKit a `preferredFont`; los selectores propios de escala se retiraron — el slider de iOS es el único mando. |
| Markdown | Las tarjetas asentadas releen el dynamic type del ambiente (cierra el rojo viejo de SettledMessageIsolation). |
| Subagentes | Las tarjetas de delegados se identifican por el `subagent_id` del gateway: las terminadas se retiran solas en vez de quedarse hasta reiniciar. |
| Interfaz | Barra flotante Liquid Glass en la conversación (build 158); navegación por píldora chats · kanban · subagentes con punto de actividad en vivo, y retiro de la sidebar persistente de iPad (build 159). |
| Pruebas ciegas al fork | 3 tests leen el `Info.plist` del bundle anfitrión en vez del id original `com.milim.relay` (orientaciones de iPad/iPhone y ATS de Tailscale); `SidebarLayoutTests` se retiró junto con la sidebar. |

### Lo que el original tiene y aquí falta (75 commits · medido 2026-09-26)

Entran con la próxima alineación (merge, nunca rebase):

- **Chat sin conexión** (issue-99, #223/#227/#229): copia offline de transcripciones que sobrevive a cambio de cuenta o de dashboard, y filas guardadas que no caen al cerrar la sesión.
- **Medios** (#195/#225/#226): vista previa a pantalla completa con guardar y compartir; previsualizaciones más ligeras de memoria e hilo principal.
- **Voz**: recuperación del motor de audio — los errores −10868 se clasifican recuperables, los engines arrancan limpios y el reset de media-services ya no truena.
- **Compositor** (#194): el micrófono aparece solo si el perfil tiene voz habilitada; un solo slot mic/enviar.
- **Notificaciones** (#228): sonido de aprobación y de entrada (`attention_sound`).
- Correcciones de scroll (overshoot), del gate de tamaño de texto, consulta de menciones ASCII-only y etiquetas de Group Chat. El CI (`.github/workflows/ci.yml`) ya está al día — no falta.

> Esta sección pertenece al fork: si un merge con el original conflictúa aquí, se conserva esta versión y solo se actualizan sus cifras.

<!-- ===== FIN SECCIÓN DEL FORK ===== -->

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
