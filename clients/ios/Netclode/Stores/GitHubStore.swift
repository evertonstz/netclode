import Foundation

/// Store for managing GitHub repository data with persistent caching.
@MainActor
@Observable
final class GitHubStore {
    /// All cached repositories
    private(set) var repos: [GitHubRepo] = []
    
    /// Whether a fetch is in progress
    private(set) var isLoading = false
    
    /// Last time repos were fetched
    private(set) var lastFetched: Date?
    
    /// Error message if last fetch failed
    private(set) var errorMessage: String?
    
    /// Cache TTL in seconds (5 minutes)
    private let cacheTTL: TimeInterval = 300
    
    /// UserDefaults keys for persistence
    private enum StorageKeys {
        static let repos = "github_repos_cache"
        static let lastFetched = "github_repos_last_fetched"
    }
    
    /// Whether the cache is stale
    var isCacheStale: Bool {
        guard let lastFetched else { return true }
        return Date().timeIntervalSince(lastFetched) > cacheTTL
    }
    
    init() {
        loadFromStorage()
    }
    
    // MARK: - Persistence
    
    /// Load cached repos from UserDefaults
    private func loadFromStorage() {
        if let data = UserDefaults.standard.data(forKey: StorageKeys.repos),
           let decoded = try? JSONDecoder().decode([GitHubRepo].self, from: data) {
            self.repos = decoded
        }
        
        if let timestamp = UserDefaults.standard.object(forKey: StorageKeys.lastFetched) as? Date {
            self.lastFetched = timestamp
        }
    }
    
    /// Save repos to UserDefaults
    private func saveToStorage() {
        if let encoded = try? JSONEncoder().encode(repos) {
            UserDefaults.standard.set(encoded, forKey: StorageKeys.repos)
        }
        
        if let lastFetched {
            UserDefaults.standard.set(lastFetched, forKey: StorageKeys.lastFetched)
        }
    }
    
    /// Filter repos by query string (matches name or fullName)
    func filteredRepos(query: String) -> [GitHubRepo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return repos }
        
        return repos.filter { repo in
            repo.name.lowercased().contains(trimmed) ||
            repo.fullName.lowercased().contains(trimmed)
        }
    }
    
    /// Request repos from server if cache is stale
    /// - Parameter webSocketService: The WebSocket service to send the request
    /// - Parameter force: Force refresh even if cache is valid
    func fetchIfNeeded(webSocketService: WebSocketService, force: Bool = false) {
        guard force || isCacheStale else { return }
        guard !isLoading else { return }
        guard webSocketService.connectionState.isConnected else { return }
        
        isLoading = true
        errorMessage = nil
        webSocketService.send(.githubReposList)
    }
    
    /// Handle incoming repos from server
    func handleReposReceived(_ repos: [GitHubRepo]) {
        self.repos = repos.sorted { $0.fullName.lowercased() < $1.fullName.lowercased() }
        self.lastFetched = Date()
        self.isLoading = false
        self.errorMessage = nil
        saveToStorage()
    }
    
    /// Handle error response
    func handleError(_ message: String) {
        self.isLoading = false
        self.errorMessage = message
    }
    
    /// Clear the cache
    func clearCache() {
        repos = []
        lastFetched = nil
        errorMessage = nil
        UserDefaults.standard.removeObject(forKey: StorageKeys.repos)
        UserDefaults.standard.removeObject(forKey: StorageKeys.lastFetched)
    }
}
