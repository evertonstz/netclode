import SwiftUI

struct PromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WebSocketService.self) private var webSocketService
    @Environment(SettingsStore.self) private var settingsStore

    @State private var promptText = ""
    @State private var isSubmitting = false
    @FocusState private var isTextFieldFocused: Bool

    var canSubmit: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Prompt input area
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Text("What would you like to build?")
                            .font(.netclodeTitle)
                            .padding(.top, Theme.Spacing.lg)

                        Text("Describe your project or task, and Claude will help you build it.")
                            .font(.netclodeBody)
                            .foregroundStyle(.secondary)

                        // Text editor
                        ZStack(alignment: .topLeading) {
                            if promptText.isEmpty {
                                Text("e.g., Build a REST API with authentication, Create a landing page, Fix a bug in my code...")
                                    .font(.netclodeBody)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, Theme.Spacing.md)
                                    .padding(.vertical, Theme.Spacing.md)
                            }

                            TextEditor(text: $promptText)
                                .font(.netclodeBody)
                                .scrollContentBackground(.hidden)
                                .focused($isTextFieldFocused)
                                .frame(minHeight: 200)
                                .padding(.horizontal, Theme.Spacing.sm)
                                .padding(.vertical, Theme.Spacing.sm)
                        }
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.xl))
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                }

                // Bottom action bar
                VStack(spacing: Theme.Spacing.md) {
                    Button {
                        submitPrompt()
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            if isSubmitting {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 18))
                            }
                            Text(isSubmitting ? "Creating session..." : "Start Session")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.md)
                        .foregroundStyle(canSubmit ? .white : .secondary)
                        .glassEffect(
                            canSubmit ? .regular.tint(Theme.Colors.brand.glassTint) : .regular,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.xl)
                        )
                    }
                    .disabled(!canSubmit)
                    .animation(.glassSpring, value: canSubmit)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
                .background(.ultraThinMaterial)
            }
            .background(Theme.Colors.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                }
            }
            .onAppear {
                isTextFieldFocused = true
            }
        }
    }

    private func submitPrompt() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isSubmitting = true

        if settingsStore.hapticFeedbackEnabled {
            HapticFeedback.medium()
        }

        // Create session with the prompt as the name (truncated)
        let sessionName = String(text.prefix(50))
        webSocketService.send(.sessionCreate(name: sessionName, repo: nil))

        // Dismiss after a short delay
        // The session will be created and the user will see it in the list
        // They can tap on it to open and continue the conversation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            dismiss()
        }
    }
}

// MARK: - Preview

#Preview {
    PromptSheet()
        .environment(WebSocketService())
        .environment(SettingsStore())
}
