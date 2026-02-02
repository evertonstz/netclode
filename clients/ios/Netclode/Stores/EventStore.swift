import Foundation

@MainActor
@Observable
final class EventStore {
    private(set) var eventsBySession: [String: [AgentEvent]] = [:]
    
    /// Track accumulated inputDelta JSON strings by toolUseId
    private var streamingToolInput: [String: String] = [:]
    
    /// Track accumulated tool output by toolUseId (for merging into tool_end result)
    private var streamingToolOutput: [String: String] = [:]

    func events(for sessionId: String) -> [AgentEvent] {
        eventsBySession[sessionId] ?? []
    }

    func recentEvents(for sessionId: String, count: Int = 5) -> [AgentEvent] {
        Array((eventsBySession[sessionId] ?? []).suffix(count))
    }

    func appendEvent(sessionId: String, event: AgentEvent) {
        var events = eventsBySession[sessionId] ?? []
        events.append(event)
        eventsBySession[sessionId] = events
        print("[EventStore] appendEvent: session=\(sessionId), totalEvents=\(events.count), event=\(event)")
    }

    /// Append partial thinking content or create a new thinking event
    func appendThinkingPartial(sessionId: String, thinkingId: String, content: String, timestamp: Date) {
        var events = eventsBySession[sessionId] ?? []

        // Find existing thinking event with this thinkingId
        if let existingIndex = events.lastIndex(where: { event in
            if case .thinking(let e) = event, e.thinkingId == thinkingId {
                return true
            }
            return false
        }) {
            // Update existing thinking event by appending content
            if case .thinking(var thinkingEvent) = events[existingIndex] {
                thinkingEvent.content += content
                events[existingIndex] = .thinking(thinkingEvent)
            }
        } else {
            // Create new thinking event
            let newEvent = ThinkingEvent(
                id: UUID(),
                timestamp: timestamp,
                thinkingId: thinkingId,
                content: content,
                partial: true
            )
            events.append(.thinking(newEvent))
        }

        eventsBySession[sessionId] = events
    }

    /// Finalize a thinking event (mark as complete)
    func finalizeThinking(sessionId: String, thinkingId: String) {
        guard var events = eventsBySession[sessionId] else { return }

        if let index = events.lastIndex(where: { event in
            if case .thinking(let e) = event, e.thinkingId == thinkingId {
                return true
            }
            return false
        }) {
            if case .thinking(let thinkingEvent) = events[index] {
                // Create a new event with partial = false
                let finalizedEvent = ThinkingEvent(
                    id: thinkingEvent.id,
                    timestamp: thinkingEvent.timestamp,
                    thinkingId: thinkingEvent.thinkingId,
                    content: thinkingEvent.content,
                    partial: false
                )
                events[index] = .thinking(finalizedEvent)
                eventsBySession[sessionId] = events
            }
        }
    }

    func clearEvents(for sessionId: String) {
        eventsBySession.removeValue(forKey: sessionId)
    }

    /// Append streaming tool input delta and try to parse/update the tool_start event
    func appendToolInputDelta(sessionId: String, toolUseId: String, inputDelta: String) {
        // Accumulate the delta
        let accumulated = (streamingToolInput[toolUseId] ?? "") + inputDelta
        streamingToolInput[toolUseId] = accumulated
        
        // Try to parse as complete JSON first
        if let data = accumulated.data(using: .utf8),
           let parsed = try? JSONDecoder().decode([String: AnyCodableValue].self, from: data) {
            updateToolInput(sessionId: sessionId, toolUseId: toolUseId, input: parsed)
            return
        }
        
        // JSON not complete yet - try to extract partial values for display
        // This lets us show the command while it's still streaming
        let partialInput = extractPartialJsonValues(from: accumulated)
        if !partialInput.isEmpty {
            updateToolInputPartial(sessionId: sessionId, toolUseId: toolUseId, input: partialInput)
        }
    }
    
    /// Extract the first string value from incomplete JSON for early display
    /// Looks for common tool input keys like "command", "file_path", "pattern", etc.
    /// Returns partial value even if JSON is incomplete
    private func extractPartialJsonValues(from json: String) -> [String: AnyCodableValue] {
        // Keys we care about showing early, in priority order
        let keys = ["command", "file_path", "filePath", "pattern", "query", "url", "description"]
        
        for key in keys {
            if let value = extractStringValue(for: key, from: json) {
                return [key: .string(value)]
            }
        }
        
        return [:]
    }
    
    /// Extract a string value for a specific key from potentially incomplete JSON
    /// e.g. {"command":"apt-get install -> returns "apt-get install"
    /// e.g. {"command": "apt-get install -> also returns "apt-get install" (with space)
    private func extractStringValue(for key: String, from json: String) -> String? {
        // Look for "key":" or "key": " (with optional space after colon)
        let patterns = ["\"\(key)\":\"", "\"\(key)\": \""]
        var keyRange: Range<String.Index>?
        for pattern in patterns {
            if let range = json.range(of: pattern) {
                keyRange = range
                break
            }
        }
        guard let keyRange else {
            return nil
        }
        
        // Extract everything after the opening quote until closing quote or end
        let valueStart = keyRange.upperBound
        let remaining = json[valueStart...]
        
        // Find the closing quote (not escaped)
        var value = ""
        var escaped = false
        for char in remaining {
            if escaped {
                value.append(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "\"" {
                break // Found closing quote
            } else {
                value.append(char)
            }
        }
        
        return value.isEmpty ? nil : value
    }
    
    /// Update a tool_start event with partial input (for streaming display)
    private func updateToolInputPartial(sessionId: String, toolUseId: String, input: [String: AnyCodableValue]) {
        guard var events = eventsBySession[sessionId] else { return }

        if let index = events.lastIndex(where: { event in
            if case .toolStart(let e) = event, e.toolUseId == toolUseId {
                return true
            }
            return false
        }) {
            if case .toolStart(let existing) = events[index] {
                // Only update if we have more/better data than before
                // Merge new partial input with existing input
                var mergedInput = existing.input
                for (key, value) in input {
                    // Only update if the new value is longer (more complete)
                    if let existingValue = mergedInput[key],
                       case .string(let existingStr) = existingValue,
                       case .string(let newStr) = value,
                       newStr.count <= existingStr.count {
                        continue
                    }
                    mergedInput[key] = value
                }
                
                let updated = ToolStartEvent(
                    id: existing.id,
                    timestamp: existing.timestamp,
                    tool: existing.tool,
                    toolUseId: existing.toolUseId,
                    parentToolUseId: existing.parentToolUseId,
                    input: mergedInput
                )
                events[index] = .toolStart(updated)
                eventsBySession[sessionId] = events
            }
        }
    }
    
    /// Accumulate tool output for a toolUseId (will be merged into tool_end result)
    func appendToolOutput(sessionId: String, toolUseId: String, output: String) {
        let accumulated = (streamingToolOutput[toolUseId] ?? "") + output
        streamingToolOutput[toolUseId] = accumulated
    }
    
    /// Get accumulated tool output for a toolUseId and clear it
    func consumeToolOutput(toolUseId: String) -> String? {
        let output = streamingToolOutput[toolUseId]
        streamingToolOutput.removeValue(forKey: toolUseId)
        return output
    }
    
    /// Update a tool_end event with accumulated output (merged into result)
    func updateToolEndWithResult(sessionId: String, toolUseId: String, result: String?) {
        guard var events = eventsBySession[sessionId] else { return }
        
        // Find the tool_end event with this toolUseId and update its result
        if let index = events.lastIndex(where: { event in
            if case .toolEnd(let e) = event, e.toolUseId == toolUseId {
                return true
            }
            return false
        }) {
            if case .toolEnd(let existing) = events[index] {
                // Create updated event with result
                let updated = ToolEndEvent(
                    id: existing.id,
                    timestamp: existing.timestamp,
                    tool: existing.tool,
                    toolUseId: existing.toolUseId,
                    parentToolUseId: existing.parentToolUseId,
                    result: result ?? existing.result,
                    error: existing.error,
                    durationMs: existing.durationMs
                )
                events[index] = .toolEnd(updated)
                eventsBySession[sessionId] = events
            }
        }
    }
    
    /// Update a tool_start event with complete input (received after streaming started)
    func updateToolInput(sessionId: String, toolUseId: String, input: [String: AnyCodableValue]) {
        // Clear streaming state
        streamingToolInput.removeValue(forKey: toolUseId)
        
        guard var events = eventsBySession[sessionId] else { return }

        if let index = events.lastIndex(where: { event in
            if case .toolStart(let e) = event, e.toolUseId == toolUseId {
                return true
            }
            return false
        }) {
            if case .toolStart(let existing) = events[index] {
                // Create updated event with new input
                let updated = ToolStartEvent(
                    id: existing.id,
                    timestamp: existing.timestamp,
                    tool: existing.tool,
                    toolUseId: existing.toolUseId,
                    parentToolUseId: existing.parentToolUseId,
                    input: input
                )
                events[index] = .toolStart(updated)
                eventsBySession[sessionId] = events
            }
        }
    }

    /// Load events from server sync response
    func loadEvents(sessionId: String, events: [PersistedEvent]) {
        // Aggregate events:
        // 1. Thinking events by thinkingId to avoid fragmented display
        // 2. tool_input_complete input merged into tool_start events
        // 3. tool_output content merged into tool_end result
        var aggregatedEvents: [AgentEvent] = []
        var thinkingIndex: [String: Int] = [:] // thinkingId -> index in aggregatedEvents
        var toolStartIndex: [String: Int] = [:] // toolUseId -> index in aggregatedEvents
        var toolEndIndex: [String: Int] = [:] // toolUseId -> index in aggregatedEvents
        var accumulatedOutput: [String: String] = [:] // toolUseId -> accumulated output

        for persistedEvent in events {
            let event = persistedEvent.event.toAgentEvent()

            switch event {
            case .thinking(let thinkingEvent):
                // Skip tool output that was incorrectly converted to thinking events
                // These have thinkingId like "output_<toolUseId>"
                if thinkingEvent.thinkingId.hasPrefix("output_") {
                    // This is actually tool output - accumulate it
                    let toolUseId = String(thinkingEvent.thinkingId.dropFirst("output_".count))
                    let accumulated = (accumulatedOutput[toolUseId] ?? "") + thinkingEvent.content
                    accumulatedOutput[toolUseId] = accumulated
                    
                    // If we already have the tool_end, update it with the accumulated output
                    if let endIndex = toolEndIndex[toolUseId] {
                        if case .toolEnd(let existing) = aggregatedEvents[endIndex] {
                            let updated = ToolEndEvent(
                                id: existing.id,
                                timestamp: existing.timestamp,
                                tool: existing.tool,
                                toolUseId: existing.toolUseId,
                                parentToolUseId: existing.parentToolUseId,
                                result: accumulated,
                                error: existing.error,
                                durationMs: existing.durationMs
                            )
                            aggregatedEvents[endIndex] = .toolEnd(updated)
                        }
                    }
                } else if let existingIndex = thinkingIndex[thinkingEvent.thinkingId] {
                    // Append content to existing thinking event
                    if case .thinking(let existing) = aggregatedEvents[existingIndex] {
                        let updated = ThinkingEvent(
                            id: existing.id,
                            timestamp: existing.timestamp,
                            thinkingId: existing.thinkingId,
                            content: existing.content + thinkingEvent.content,
                            // Mark as not partial if we receive a final event
                            partial: thinkingEvent.partial && existing.partial
                        )
                        aggregatedEvents[existingIndex] = .thinking(updated)
                    }
                } else {
                    // New thinking event
                    thinkingIndex[thinkingEvent.thinkingId] = aggregatedEvents.count
                    aggregatedEvents.append(event)
                }

            case .toolStart(let toolStartEvent):
                // Track tool_start events for later input merging
                toolStartIndex[toolStartEvent.toolUseId] = aggregatedEvents.count
                aggregatedEvents.append(event)

            case .toolEnd(let toolEndEvent):
                // Check if we have accumulated output for this tool
                let result = accumulatedOutput[toolEndEvent.toolUseId] ?? toolEndEvent.result
                let updatedEvent: AgentEvent
                if result != toolEndEvent.result {
                    let updated = ToolEndEvent(
                        id: toolEndEvent.id,
                        timestamp: toolEndEvent.timestamp,
                        tool: toolEndEvent.tool,
                        toolUseId: toolEndEvent.toolUseId,
                        parentToolUseId: toolEndEvent.parentToolUseId,
                        result: result,
                        error: toolEndEvent.error,
                        durationMs: toolEndEvent.durationMs
                    )
                    updatedEvent = .toolEnd(updated)
                } else {
                    updatedEvent = event
                }
                toolEndIndex[toolEndEvent.toolUseId] = aggregatedEvents.count
                aggregatedEvents.append(updatedEvent)

            case .toolInputComplete(let inputCompleteEvent):
                // Merge input into corresponding tool_start event
                if let existingIndex = toolStartIndex[inputCompleteEvent.toolUseId] {
                    if case .toolStart(let existing) = aggregatedEvents[existingIndex] {
                        let updated = ToolStartEvent(
                            id: existing.id,
                            timestamp: existing.timestamp,
                            tool: existing.tool,
                            toolUseId: existing.toolUseId,
                            parentToolUseId: existing.parentToolUseId,
                            input: inputCompleteEvent.input
                        )
                        aggregatedEvents[existingIndex] = .toolStart(updated)
                    }
                }
                // Don't add tool_input_complete to aggregatedEvents (it's merged)

            case .toolInput:
                // Skip tool_input events (streaming deltas, not needed in history)
                break

            default:
                aggregatedEvents.append(event)
            }
        }

        eventsBySession[sessionId] = aggregatedEvents
        print("[EventStore] loadEvents: session=\(sessionId), loaded=\(events.count) raw, aggregated=\(aggregatedEvents.count)")
    }
}
