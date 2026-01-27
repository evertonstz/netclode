import Foundation

/// Store for managing OpenAI Codex SDK models
@MainActor
@Observable
final class CodexStore {
    /// Available Codex models (reuses CopilotModel since structure is identical)
    private(set) var models: [CopilotModel] = []
    
    /// Whether a fetch is in progress
    private(set) var isLoadingModels = false
    
    /// Error messages
    private(set) var modelsError: String?

    /// Default model ID (GPT 5.2 Codex High - Codex doesn't have Claude)
    static let defaultModelId = "gpt-5-2-codex:oauth:high"

    /// Update models from server response
    func updateModels(_ models: [CopilotModel]) {
        self.models = models
        isLoadingModels = false
        modelsError = nil
    }

    /// Mark models as loading
    func setLoadingModels(_ loading: Bool) {
        isLoadingModels = loading
    }

    /// Set models error
    func setModelsError(_ error: String) {
        modelsError = error
        isLoadingModels = false
    }
}
