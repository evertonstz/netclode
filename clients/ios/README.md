# Netclode iOS

Native iOS 26 app for Netclode. Built with SwiftUI and the Liquid Glass API.

## Features

- Session management (create, pause, resume, delete)
- Real-time chat with streaming responses
- Terminal emulator via [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
- Connects over Tailscale

## Requirements

- iOS 26.2+ / macOS
- Xcode 17.0+
- Swift 6.2+

## Building

```bash
open Netclode.xcodeproj
# ⌘R
```

## Usage

1. Open the app
2. Settings → enter your server URL (e.g., `netclode.your-tailnet.ts.net`)
3. Connect
4. Tap + to create a session

## Architecture

```
Netclode/
├── App/                    # Entry point
├── Models/                 # Session, Messages, Events, ChatMessage
├── Services/               # WebSocketService, MessageRouter
├── Stores/                 # @Observable state (Session, Chat, Event, Terminal, Settings)
├── Features/
│   ├── Sessions/           # Session list, creation
│   ├── Workspace/          # Chat + Terminal tabs
│   ├── Chat/               # Chat UI
│   ├── Terminal/           # SwiftTerm wrapper
│   └── Settings/           # Server config
├── Components/             # GlassCard, GlassButton, GlassTextField
├── Design/                 # Theme, colors
└── Extensions/
```

## WebSocket protocol

The app communicates with the control plane via WebSocket.

Client → Server:

```swift
ClientMessage.sessionList
ClientMessage.sessionCreate(name: "My Project", repo: nil)
ClientMessage.sessionOpen(id: "xxx", lastNotificationId: nil)
ClientMessage.sessionResume(id: "xxx")
ClientMessage.sessionPause(id: "xxx")
ClientMessage.prompt(sessionId: "xxx", text: "Fix the bug")
ClientMessage.terminalInput(sessionId: "xxx", data: "ls\n")
```

Server → Client:

```swift
ServerMessage.sessionList(sessions: [...])
ServerMessage.sessionCreated(session: Session)
ServerMessage.agentMessage(sessionId: "xxx", content: "...", partial: true)
ServerMessage.agentEvent(sessionId: "xxx", event: AgentEvent)
ServerMessage.terminalOutput(sessionId: "xxx", data: "...")
```

On reconnect, the app sends `lastNotificationId` to resume from where it left off.

## State management

Uses `@Observable` + SwiftUI Environment:

```swift
@Observable
class SessionStore {
    var sessions: [Session] = []
    var currentSessionId: String?
}

@Environment(SessionStore.self) private var sessionStore
```

## Liquid Glass

The app uses iOS 26's glass effects:

```swift
.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
.glassEffect(.regular.interactive().tint(color), in: .capsule)
```

## Terminal

Terminal emulation uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). The app sends `terminal.input` messages to the control plane, which proxies them to the agent's PTY. Output comes back via `terminal.output`.

```
SwiftTerminalView ──► WebSocketService ──► Control Plane ──► Agent PTY
```

`SwiftTermBridge.swift` adapts SwiftTerm's `LocalProcessTerminalView` delegate to work over WebSocket instead of a local process.

## License

MIT
