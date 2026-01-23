import XCTest
@testable import Netclode

final class EventStoreTests: XCTestCase {

    // MARK: - Thinking Event Aggregation Tests

    @MainActor
    func testLoadEventsAggregatesThinkingEventsWithSameId() {
        let store = EventStore()

        // Given: Multiple thinking partials with the same thinkingId
        let events = [
            makePersistedThinkingEvent(thinkingId: "t1", content: "Hello ", partial: true),
            makePersistedThinkingEvent(thinkingId: "t1", content: "world", partial: true),
            makePersistedThinkingEvent(thinkingId: "t1", content: "!", partial: false),
        ]

        // When: Loading events
        store.loadEvents(sessionId: "test", events: events)

        // Then: Should be aggregated into 1 event with combined content
        let result = store.events(for: "test")
        XCTAssertEqual(result.count, 1)

        if case .thinking(let thinking) = result.first {
            XCTAssertEqual(thinking.content, "Hello world!")
            XCTAssertEqual(thinking.thinkingId, "t1")
            XCTAssertFalse(thinking.partial, "Should be marked as not partial after final event")
        } else {
            XCTFail("Expected thinking event")
        }
    }

    @MainActor
    func testLoadEventsKeepsDistinctThinkingEventsSeparate() {
        let store = EventStore()

        // Given: Thinking events with different thinkingIds
        let events = [
            makePersistedThinkingEvent(thinkingId: "t1", content: "First thought", partial: false),
            makePersistedThinkingEvent(thinkingId: "t2", content: "Second thought", partial: false),
        ]

        // When: Loading events
        store.loadEvents(sessionId: "test", events: events)

        // Then: Should have 2 separate events
        let result = store.events(for: "test")
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - Tool Input Merging Tests

    @MainActor
    func testLoadEventsMergesToolInputCompleteIntoToolStart() {
        let store = EventStore()

        // Given: A tool_start followed by tool_input_complete
        let events = [
            makePersistedToolStartEvent(toolUseId: "tool1", tool: "Bash", input: [:]),
            makePersistedToolInputCompleteEvent(toolUseId: "tool1", input: ["command": .string("ls -la")]),
        ]

        // When: Loading events
        store.loadEvents(sessionId: "test", events: events)

        // Then: Should have 1 event with merged input
        let result = store.events(for: "test")
        XCTAssertEqual(result.count, 1, "tool_input_complete should be merged, not added separately")

        if case .toolStart(let toolStart) = result.first {
            XCTAssertEqual(toolStart.tool, "Bash")
            XCTAssertEqual(toolStart.toolUseId, "tool1")
            if case .string(let cmd) = toolStart.input["command"] {
                XCTAssertEqual(cmd, "ls -la")
            } else {
                XCTFail("Expected command input to be merged")
            }
        } else {
            XCTFail("Expected toolStart event")
        }
    }

    @MainActor
    func testLoadEventsSkipsToolInputEvents() {
        let store = EventStore()

        // Given: tool_start, tool_input (streaming delta), tool_end
        let events = [
            makePersistedToolStartEvent(toolUseId: "tool1", tool: "Bash", input: [:]),
            makePersistedToolInputEvent(toolUseId: "tool1", inputDelta: "ls"),
            makePersistedToolInputEvent(toolUseId: "tool1", inputDelta: " -la"),
            makePersistedToolEndEvent(toolUseId: "tool1", tool: "Bash", result: "file1\nfile2"),
        ]

        // When: Loading events
        store.loadEvents(sessionId: "test", events: events)

        // Then: Should have 2 events (start + end), tool_input skipped
        let result = store.events(for: "test")
        XCTAssertEqual(result.count, 2, "tool_input events should be skipped")

        XCTAssertTrue(result.contains { if case .toolStart = $0 { return true }; return false })
        XCTAssertTrue(result.contains { if case .toolEnd = $0 { return true }; return false })
    }

    @MainActor
    func testLoadEventsHandlesMixedEventTypes() {
        let store = EventStore()

        // Given: A realistic sequence of events
        let events = [
            makePersistedThinkingEvent(thinkingId: "t1", content: "Let me check ", partial: true),
            makePersistedThinkingEvent(thinkingId: "t1", content: "the files", partial: false),
            makePersistedToolStartEvent(toolUseId: "tool1", tool: "Bash", input: [:]),
            makePersistedToolInputCompleteEvent(toolUseId: "tool1", input: ["command": .string("ls")]),
            makePersistedToolEndEvent(toolUseId: "tool1", tool: "Bash", result: "file.txt"),
        ]

        // When: Loading events
        store.loadEvents(sessionId: "test", events: events)

        // Then: Should have 3 events (1 thinking, 1 tool_start, 1 tool_end)
        let result = store.events(for: "test")
        XCTAssertEqual(result.count, 3)

        // Verify thinking was aggregated
        if case .thinking(let thinking) = result[0] {
            XCTAssertEqual(thinking.content, "Let me check the files")
        } else {
            XCTFail("Expected aggregated thinking event first")
        }

        // Verify tool_start has merged input
        if case .toolStart(let toolStart) = result[1] {
            if case .string(let cmd) = toolStart.input["command"] {
                XCTAssertEqual(cmd, "ls")
            } else {
                XCTFail("Expected command to be merged")
            }
        } else {
            XCTFail("Expected toolStart event")
        }
    }

    // MARK: - Helpers

    private func makePersistedThinkingEvent(
        thinkingId: String,
        content: String,
        partial: Bool
    ) -> PersistedEvent {
        PersistedEvent(
            id: UUID().uuidString,
            sessionId: "test",
            event: PersistedEvent.RawAgentEventData(
                kind: "thinking",
                timestamp: Date(),
                tool: nil,
                toolUseId: nil,
                parentToolUseId: nil,
                input: nil,
                inputDelta: nil,
                result: nil,
                path: nil,
                action: nil,
                linesAdded: nil,
                linesRemoved: nil,
                command: nil,
                cwd: nil,
                exitCode: nil,
                output: nil,
                content: content,
                thinkingId: thinkingId,
                partial: partial,
                port: nil,
                process: nil,
                previewUrl: nil,
                repo: nil,
                stage: nil,
                message: nil,
                error: nil
            ),
            timestamp: Date()
        )
    }

    private func makePersistedToolStartEvent(
        toolUseId: String,
        tool: String,
        input: [String: AnyCodableValue]
    ) -> PersistedEvent {
        PersistedEvent(
            id: UUID().uuidString,
            sessionId: "test",
            event: PersistedEvent.RawAgentEventData(
                kind: "tool_start",
                timestamp: Date(),
                tool: tool,
                toolUseId: toolUseId,
                parentToolUseId: nil,
                input: input,
                inputDelta: nil,
                result: nil,
                path: nil,
                action: nil,
                linesAdded: nil,
                linesRemoved: nil,
                command: nil,
                cwd: nil,
                exitCode: nil,
                output: nil,
                content: nil,
                thinkingId: nil,
                partial: nil,
                port: nil,
                process: nil,
                previewUrl: nil,
                repo: nil,
                stage: nil,
                message: nil,
                error: nil
            ),
            timestamp: Date()
        )
    }

    private func makePersistedToolInputEvent(
        toolUseId: String,
        inputDelta: String
    ) -> PersistedEvent {
        PersistedEvent(
            id: UUID().uuidString,
            sessionId: "test",
            event: PersistedEvent.RawAgentEventData(
                kind: "tool_input",
                timestamp: Date(),
                tool: nil,
                toolUseId: toolUseId,
                parentToolUseId: nil,
                input: nil,
                inputDelta: inputDelta,
                result: nil,
                path: nil,
                action: nil,
                linesAdded: nil,
                linesRemoved: nil,
                command: nil,
                cwd: nil,
                exitCode: nil,
                output: nil,
                content: nil,
                thinkingId: nil,
                partial: nil,
                port: nil,
                process: nil,
                previewUrl: nil,
                repo: nil,
                stage: nil,
                message: nil,
                error: nil
            ),
            timestamp: Date()
        )
    }

    private func makePersistedToolInputCompleteEvent(
        toolUseId: String,
        input: [String: AnyCodableValue]
    ) -> PersistedEvent {
        PersistedEvent(
            id: UUID().uuidString,
            sessionId: "test",
            event: PersistedEvent.RawAgentEventData(
                kind: "tool_input_complete",
                timestamp: Date(),
                tool: nil,
                toolUseId: toolUseId,
                parentToolUseId: nil,
                input: input,
                inputDelta: nil,
                result: nil,
                path: nil,
                action: nil,
                linesAdded: nil,
                linesRemoved: nil,
                command: nil,
                cwd: nil,
                exitCode: nil,
                output: nil,
                content: nil,
                thinkingId: nil,
                partial: nil,
                port: nil,
                process: nil,
                previewUrl: nil,
                repo: nil,
                stage: nil,
                message: nil,
                error: nil
            ),
            timestamp: Date()
        )
    }

    private func makePersistedToolEndEvent(
        toolUseId: String,
        tool: String,
        result: String?
    ) -> PersistedEvent {
        PersistedEvent(
            id: UUID().uuidString,
            sessionId: "test",
            event: PersistedEvent.RawAgentEventData(
                kind: "tool_end",
                timestamp: Date(),
                tool: tool,
                toolUseId: toolUseId,
                parentToolUseId: nil,
                input: nil,
                inputDelta: nil,
                result: result,
                path: nil,
                action: nil,
                linesAdded: nil,
                linesRemoved: nil,
                command: nil,
                cwd: nil,
                exitCode: nil,
                output: nil,
                content: nil,
                thinkingId: nil,
                partial: nil,
                port: nil,
                process: nil,
                previewUrl: nil,
                repo: nil,
                stage: nil,
                message: nil,
                error: nil
            ),
            timestamp: Date()
        )
    }
}
