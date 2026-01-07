import SwiftUI

struct ContentView: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(WebSocketService.self) private var webSocketService
    @State private var selectedTab: AppTab = .sessions

    enum AppTab: String, CaseIterable {
        case sessions = "Sessions"
        case settings = "Settings"
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Sessions", systemImage: "rectangle.stack.fill", value: .sessions) {
                NavigationStack {
                    SessionsView()
                }
            }

            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .tabViewStyle(.tabBarOnly)
        .tabBarMinimizeBehavior(.onScrollDown)
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
