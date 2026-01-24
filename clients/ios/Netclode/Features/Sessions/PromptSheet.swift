import SwiftUI

struct PromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ConnectService.self) private var connectService
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(SessionStore.self) private var sessionStore
    @Environment(GitHubStore.self) private var githubStore
    @Environment(ModelsStore.self) private var modelsStore
    @Environment(CopilotStore.self) private var copilotStore

    @State private var promptText = ""
    @State private var repoURL = ""
    @State private var repoAccess: RepoAccess = .write
    @State private var selectedSdkType: SdkType = .claude
    @State private var selectedClaudeModelId: String = ModelsStore.defaultModelId
    @State private var selectedOpenCodeModelId: String = ModelsStore.defaultModelId
    @State private var selectedCopilotBackend: CopilotBackend = .anthropic
    @State private var selectedCopilotModelId: String = CopilotStore.defaultAnthropicModelId
    @State private var isSubmitting = false
    @State private var canSubmit = false
    @State private var showModelDropdown = false
    @FocusState private var isFocused: Bool

    /// Get available models as PickerModels based on current SDK selection
    private var availablePickerModels: [PickerModel] {
        switch selectedSdkType {
        case .claude, .opencode:
            return modelsStore.anthropicModels.map { PickerModel.from($0) }
        case .copilot:
            return copilotStore.models(for: selectedCopilotBackend).map { PickerModel.from($0) }
        }
    }

    /// Binding to the appropriate model ID based on SDK type
    private var selectedModelIdBinding: Binding<String> {
        switch selectedSdkType {
        case .claude:
            return $selectedClaudeModelId
        case .opencode:
            return $selectedOpenCodeModelId
        case .copilot:
            return $selectedCopilotModelId
        }
    }

    /// Whether models are loading
    private var isLoadingModels: Bool {
        switch selectedSdkType {
        case .claude, .opencode:
            return modelsStore.isLoading
        case .copilot:
            return copilotStore.isLoadingModels
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Text input area
                TextField(
                    "What do you want to build?",
                    text: $promptText,
                    axis: .vertical
                )
                .font(.netclodeBody)
                .tint(Theme.Colors.brand)
                .lineLimit(3...12)
                .padding(Theme.Spacing.md)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.md)
                .focused($isFocused)

                // SDK and Model section
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "cpu")
                            .foregroundStyle(.secondary)
                        Text("Agent SDK")
                            .font(.netclodeCaption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("SDK", selection: $selectedSdkType) {
                        ForEach(SdkType.allCases, id: \.self) { sdk in
                            Text(sdk.displayName).tag(sdk)
                        }
                    }
                    .pickerStyle(.segmented)

                    // Backend picker (only for Copilot)
                    if selectedSdkType == .copilot {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "server.rack")
                                .foregroundStyle(.secondary)
                            Text("Backend")
                                .font(.netclodeCaption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, Theme.Spacing.xs)

                        Picker("Backend", selection: $selectedCopilotBackend) {
                            ForEach(CopilotBackend.allCases, id: \.self) { backend in
                                Text(backend.displayName).tag(backend)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: selectedCopilotBackend) { _, newBackend in
                            // Reset model selection when backend changes
                            selectedCopilotModelId = copilotStore.defaultModelId(for: newBackend)
                            // Fetch models for the new backend
                            fetchCopilotModels(for: newBackend)
                        }
                    }

                    // Model picker (shown for all SDK types)
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.secondary)
                        Text("Model")
                            .font(.netclodeCaption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, Theme.Spacing.xs)

                    if isLoadingModels {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Loading models...")
                                .font(.netclodeCaption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(Theme.Spacing.sm)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                    } else {
                        InlineModelPicker(
                            selectedModelId: selectedModelIdBinding,
                            models: availablePickerModels,
                            isExpanded: $showModelDropdown
                        )
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.md)

                // Repository section
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image("github-mark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                            .foregroundStyle(.secondary)
                        Text("Repository (optional)")
                            .font(.netclodeCaption)
                            .foregroundStyle(.secondary)
                    }
                    
                    RepoAutocomplete(text: $repoURL)
                    
                    if !repoURL.isEmpty {
                        Picker("Access", selection: $repoAccess) {
                            Text("Read & Write").tag(RepoAccess.write)
                            Text("Read Only").tag(RepoAccess.read)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.md)

                Spacer()
            }
            .background(Theme.Colors.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if settingsStore.hapticFeedbackEnabled {
                            HapticFeedback.light()
                        }
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(.red)
                    .accessibilityLabel("Cancel")
                }

                ToolbarItem(placement: .principal) {
                    Text("New Session")
                        .font(.netclodeHeadline)
                }

                ToolbarSpacer(placement: .topBarTrailing)

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        submitPrompt()
                    } label: {
                        if isSubmitting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "paperplane")
                                .symbolVariant(canSubmit ? .fill : .none)
                                .bold()
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .tint(Theme.Colors.brand)
                    .disabled(!canSubmit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Send")
                }
            }
            .onAppear {
                isFocused = true
                // Fetch Copilot models if Copilot SDK is selected
                if selectedSdkType == .copilot {
                    fetchCopilotModels(for: selectedCopilotBackend)
                }
            }
            .onChange(of: selectedSdkType) { _, newSdkType in
                // Fetch models when switching to Copilot
                if newSdkType == .copilot {
                    fetchCopilotModels(for: selectedCopilotBackend)
                }
            }
            .onChange(of: promptText) { _, newValue in
                canSubmit = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
            }
            .onChange(of: isSubmitting) { _, newValue in
                canSubmit = !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !newValue
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSubmitting)
    }

    @ViewBuilder
    private func modelLabel(for model: PickerModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                if let provider = model.provider {
                    Text(provider)
                        .font(.netclodeCaption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let multiplier = model.billingMultiplier, multiplier != 1.0 {
                Text(multiplier < 1.0 ? String(format: "%.2fx", multiplier) : String(format: "%.0fx", multiplier))
                    .font(.netclodeCaption)
                    .foregroundStyle(multiplier < 1.0 ? .green : (multiplier <= 2.0 ? .orange : .red))
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

        // Store prompt text - will be associated with session when sessionCreated arrives
        sessionStore.pendingPromptText = text
        
        // Parse repo URL if provided
        let repo = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let repoParam = repo.isEmpty ? nil : repo
        let accessParam = repoParam != nil ? repoAccess : nil

        // SDK, model, and backend params
        let sdkParam = selectedSdkType
        let modelParam: String?
        let copilotBackendParam: CopilotBackend?
        
        switch selectedSdkType {
        case .claude:
            modelParam = selectedClaudeModelId
            copilotBackendParam = nil
        case .opencode:
            modelParam = selectedOpenCodeModelId
            copilotBackendParam = nil
        case .copilot:
            modelParam = selectedCopilotModelId
            copilotBackendParam = selectedCopilotBackend
        }
        
        // Create session
        connectService.send(.sessionCreate(
            name: nil,
            repo: repoParam,
            repoAccess: accessParam,
            initialPrompt: text,
            sdkType: sdkParam,
            model: modelParam,
            copilotBackend: copilotBackendParam
        ))

        dismiss()
    }

    private func fetchCopilotModels(for backend: CopilotBackend) {
        copilotStore.setLoadingModels(true)
        connectService.send(.listModels(sdkType: .copilot, copilotBackend: backend))
    }
}

// MARK: - Preview

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            PromptSheet()
                .environment(ConnectService())
                .environment(SettingsStore())
                .environment(SessionStore())
                .environment(GitHubStore())
                .environment(ModelsStore())
                .environment(CopilotStore())
        }
}
