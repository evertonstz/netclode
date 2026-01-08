import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            SessionsView()
        }
    }
}

#Preview {
    ContentView()
        .environment(SessionStore())
        .environment(ChatStore())
        .environment(EventStore())
        .environment(TerminalStore())
        .environment(SettingsStore())
        .environment(WebSocketService())
        .environment(MessageRouter.preview)
}
