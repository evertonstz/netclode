import SwiftUI

/// Inline expandable picker for GitHub repository selection (matches InlineModelPicker style).
struct InlineRepoPicker: View {
    @Binding var selectedRepos: [String]
    @Binding var isExpanded: Bool
    var onSearchFocused: (() -> Void)?
    var onExpanded: (() -> Void)?

    @Environment(GitHubStore.self) private var githubStore
    @Environment(ConnectService.self) private var connectService
    @Environment(SettingsStore.self) private var settingsStore

    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var filteredRepos: [GitHubRepo] {
        githubStore.filteredRepos(query: searchText)
    }

    private var selectedRepoSet: Set<String> {
        Set(selectedRepos)
    }

    private var firstSelectedRepo: String? {
        selectedRepos.first
    }

    private var firstSelectedRepoObject: GitHubRepo? {
        guard let first = firstSelectedRepo else { return nil }
        return githubStore.repos.first { $0.fullName == first }
    }

    private var baseSelectionLabel: String? {
        guard let first = firstSelectedRepo else { return nil }
        return firstSelectedRepoObject?.fullName ?? first
    }

    private var extraSelectionCount: Int {
        max(0, selectedRepos.count - 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Collapsed state - shows selected repos summary
            Button {
                withAnimation(.smooth(duration: 0.25)) {
                    isExpanded.toggle()
                    if isExpanded {
                        githubStore.fetchIfNeeded(connectService: connectService)
                        onExpanded?()
                    } else {
                        isSearchFocused = false
                        searchText = ""
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    if let repo = firstSelectedRepoObject, let label = baseSelectionLabel {
                        Image(systemName: repo.isPrivate ? "lock.fill" : "globe")
                            .font(.system(size: 16))
                            .frame(width: 20)
                            .foregroundStyle(repo.isPrivate ? Theme.Colors.warning : .secondary)
                        Text(label)
                            .font(.netclodeBody)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                        if extraSelectionCount > 0 {
                            Text("+\(extraSelectionCount)")
                                .font(.netclodeCaption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let label = baseSelectionLabel {
                        // Manual entry (not in list)
                        Image(systemName: "folder")
                            .font(.system(size: 16))
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                        Text(label)
                            .font(.netclodeBody)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                        if extraSelectionCount > 0 {
                            Text("+\(extraSelectionCount)")
                                .font(.netclodeCaption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Select repositories")
                            .font(.netclodeBody)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(Theme.Spacing.sm)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .animation(.smooth(duration: 0.2), value: selectedRepos)
            }
            .buttonStyle(.plain)
            .glassEffect(
                isExpanded ? .regular.tint(Theme.Colors.brand.glassTint).interactive() : .regular.interactive(),
                in: RoundedRectangle(cornerRadius: Theme.Radius.md)
            )

            // Expanded state - search field + repo list
            if isExpanded {
                VStack(spacing: 0) {
                    // Search field with refresh button
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)

                        TextField("Search repositories...", text: $searchText)
                            .font(.netclodeBody)
                            .tint(Theme.Colors.brand)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($isSearchFocused)
                            .onChange(of: isSearchFocused) { _, focused in
                                if focused {
                                    onSearchFocused?()
                                }
                            }

                        if githubStore.isLoading {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                        } else {
                            Button {
                                if settingsStore.hapticFeedbackEnabled {
                                    HapticFeedback.light()
                                }
                                githubStore.fetchIfNeeded(connectService: connectService, force: true)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12))
                                    .foregroundStyle(githubStore.isCacheStale ? AnyShapeStyle(Theme.Colors.brand) : AnyShapeStyle(.tertiary))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)

                    Divider()
                        .padding(.horizontal, Theme.Spacing.sm)

                    // Repo list
                    if let error = githubStore.errorMessage {
                        Text(error)
                            .font(.netclodeCaption)
                            .foregroundStyle(.red)
                            .padding(Theme.Spacing.sm)
                    } else if githubStore.repos.isEmpty && !githubStore.isLoading {
                        Text("No repositories available")
                            .font(.netclodeCaption)
                            .foregroundStyle(.secondary)
                            .padding(Theme.Spacing.sm)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(filteredRepos) { repo in
                                    Button {
                                        toggleRepo(repo)
                                    } label: {
                                        HStack(spacing: Theme.Spacing.xs) {
                                            let isSelected = selectedRepoSet.contains(repo.fullName)
                                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(isSelected ? Theme.Colors.brand : .secondary)
                                                .font(.system(size: 16))
                                                .contentTransition(.symbolEffect(.replace))

                                            Image(systemName: repo.isPrivate ? "lock.fill" : "globe")
                                                .font(.system(size: 14))
                                                .foregroundStyle(repo.isPrivate ? Theme.Colors.warning : .secondary)
                                                .frame(width: 16)

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(repo.fullName)
                                                    .font(.netclodeBody)
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)

                                                if let description = repo.description, !description.isEmpty {
                                                    Text(description)
                                                        .font(.netclodeCaption)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                }
                                            }

                                            Spacer()
                                        }
                                        .padding(.horizontal, Theme.Spacing.sm)
                                        .padding(.vertical, Theme.Spacing.xs)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, Theme.Spacing.xs)
                        }
                        .frame(maxHeight: 280)
                    }
                }
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .top)),
                    removal: .opacity
                ))
                .padding(.top, Theme.Spacing.xs)
            }
        }
        .animation(.smooth(duration: 0.25), value: isExpanded)
    }

    private func toggleRepo(_ repo: GitHubRepo) {
        if settingsStore.hapticFeedbackEnabled {
            HapticFeedback.light()
        }
        withAnimation(.smooth(duration: 0.2)) {
            if let index = selectedRepos.firstIndex(of: repo.fullName) {
                selectedRepos.remove(at: index)
            } else {
                selectedRepos.append(repo.fullName)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    VStack {
        InlineRepoPicker(
            selectedRepos: .constant([]),
            isExpanded: .constant(true)
        )
        .padding()
    }
}
