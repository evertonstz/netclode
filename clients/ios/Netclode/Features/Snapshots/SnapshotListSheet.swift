import SwiftUI

/// Sheet displaying session snapshots with restore functionality
struct SnapshotListSheet: View {
    let sessionId: String
    let onRestore: (String) -> Void
    
    @Environment(SnapshotStore.self) private var snapshotStore
    @Environment(ConnectService.self) private var connectService
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var confirmingSnapshot: Snapshot?
    
    private var snapshots: [Snapshot] {
        snapshotStore.snapshots(for: sessionId)
    }
    
    private var isRestoring: Bool {
        snapshotStore.isRestoreInProgress(for: sessionId)
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if snapshots.isEmpty {
                    emptyState
                } else {
                    snapshotList
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            // Request snapshots when sheet appears
            connectService.send(.listSnapshots(sessionId: sessionId))
        }
        .confirmationDialog(
            "Restore Snapshot",
            isPresented: .init(
                get: { confirmingSnapshot != nil },
                set: { if !$0 { confirmingSnapshot = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let snapshot = confirmingSnapshot {
                Button("Restore to \"\(snapshot.name)\"", role: .destructive) {
                    performRestore(snapshot)
                }
                Button("Cancel", role: .cancel) {
                    confirmingSnapshot = nil
                }
            }
        } message: {
            Text("This will undo all changes made after this snapshot and restore the workspace and chat history.")
        }
    }
    
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Snapshots", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("Snapshots are created automatically after each turn. Send a message to create your first snapshot.")
        }
    }
    
    private var snapshotList: some View {
        let currentSnapshotId = snapshots.first?.id
        return List {
            ForEach(snapshots) { snapshot in
                SnapshotRow(snapshot: snapshot, isCurrent: snapshot.id == currentSnapshotId, isRestoring: isRestoring) {
                    if settingsStore.hapticFeedbackEnabled {
                        HapticFeedback.warning()
                    }
                    confirmingSnapshot = snapshot
                }
            }
        }
        .listStyle(.insetGrouped)
    }
    
    private func performRestore(_ snapshot: Snapshot) {
        if settingsStore.hapticFeedbackEnabled {
            HapticFeedback.medium()
        }
        snapshotStore.setRestoreInProgress(for: sessionId, inProgress: true)
        onRestore(snapshot.id)
        dismiss()
    }
}

/// Row displaying a single snapshot
struct SnapshotRow: View {
    let snapshot: Snapshot
    let isCurrent: Bool
    let isRestoring: Bool
    let onRestore: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(snapshot.name)
                        .font(.body)
                        .lineLimit(2)
                    
                    if isCurrent {
                        Text("Current")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.2), in: Capsule())
                    }
                }
                
                HStack(spacing: 8) {
                    Text(snapshot.createdAt, style: .relative)
                    
                    if snapshot.messageCount > 0 {
                        Text("\(snapshot.messageCount) messages")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if !isCurrent {
                Button {
                    onRestore()
                } label: {
                    Text("Restore")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(isRestoring)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    let store = SnapshotStore()
    
    return SnapshotListSheet(sessionId: "test") { _ in }
        .environment(store)
        .environment(ConnectService())
        .environment(SettingsStore())
}
