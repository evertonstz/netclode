package session

import (
	"context"
	"log/slog"
	"time"

	v1 "github.com/angristan/netclode/services/control-plane/gen/netclode/v1"
	"github.com/angristan/netclode/services/control-plane/internal/protocol"
	"github.com/google/uuid"
)

// HandleAgentResponse processes streaming responses from the agent.
func (m *Manager) HandleAgentResponse(ctx context.Context, sessionID string, resp *v1.AgentStreamResponse) error {
	state := m.getState(sessionID)
	if state == nil {
		return nil
	}

	switch r := resp.Response.(type) {
	case *v1.AgentStreamResponse_TextDelta:
		return m.handleTextDelta(ctx, sessionID, state, r.TextDelta)
	case *v1.AgentStreamResponse_Event:
		return m.handleAgentEvent(ctx, sessionID, state, r.Event)
	case *v1.AgentStreamResponse_SystemMessage:
		slog.Debug("Agent system message", "sessionID", sessionID, "message", r.SystemMessage.Message)
		return nil
	case *v1.AgentStreamResponse_Result:
		return m.handleAgentResult(ctx, sessionID, state, r.Result)
	case *v1.AgentStreamResponse_Error:
		return m.handleAgentStreamError(ctx, sessionID, state, r.Error)
	default:
		slog.Warn("Unknown agent response type", "sessionID", sessionID)
		return nil
	}
}

// handleTextDelta processes text delta from agent streaming.
func (m *Manager) handleTextDelta(ctx context.Context, sessionID string, state *SessionState, delta *v1.AgentTextDelta) error {
	m.mu.Lock()
	// Use message ID from delta if provided, otherwise use current
	messageID := delta.MessageId
	if messageID == "" {
		messageID = state.CurrentMessageID
	}
	if messageID == "" {
		messageID = "msg_" + uuid.NewString()[:12]
		state.CurrentMessageID = messageID
	}

	state.ContentBuilder.WriteString(delta.Content)
	m.mu.Unlock()

	// Emit delta to clients (not accumulated content) - client accumulates
	m.emit(ctx, sessionID, protocol.NewAgentMessage(sessionID, delta.Content, delta.Partial, messageID))

	return nil
}

// handleAgentEvent processes events from agent execution.
func (m *Manager) handleAgentEvent(ctx context.Context, sessionID string, state *SessionState, event *v1.AgentEvent) error {
	// Convert proto event to protocol event
	protoEvent := convertProtoEventToProtocol(event)
	if protoEvent == nil {
		return nil
	}

	// Persist the event
	persistedEvent := &protocol.PersistedEvent{
		ID:        "evt_" + uuid.NewString()[:12],
		SessionID: sessionID,
		Event:     *protoEvent,
		Timestamp: time.Now().UTC().Format(time.RFC3339),
	}

	if err := m.storage.AppendEvent(ctx, persistedEvent); err != nil {
		slog.Warn("Failed to persist agent event", "sessionID", sessionID, "error", err)
	}

	// Emit to clients
	m.emit(ctx, sessionID, protocol.NewAgentEvent(sessionID, protoEvent))

	return nil
}

// handleAgentResult processes the final result from agent execution.
func (m *Manager) handleAgentResult(ctx context.Context, sessionID string, state *SessionState, result *v1.AgentResult) error {
	m.mu.Lock()
	content := state.ContentBuilder.String()
	messageID := state.CurrentMessageID
	originalPrompt := state.OriginalPrompt
	titleGenerated := state.TitleGenerated
	m.mu.Unlock()

	// Persist final assistant message if we have content
	if content != "" && messageID != "" {
		msg := &protocol.PersistedMessage{
			ID:        messageID,
			SessionID: sessionID,
			Role:      protocol.RoleAssistant,
			Content:   content,
			Timestamp: time.Now().UTC().Format(time.RFC3339),
		}
		if err := m.storage.AppendMessage(ctx, msg); err != nil {
			slog.Warn("Failed to persist assistant message", "sessionID", sessionID, "error", err)
		}

		// Emit final (non-partial) message
		m.emit(ctx, sessionID, protocol.NewAgentMessage(sessionID, content, false, messageID))
	}

	// Emit agent done
	m.emit(ctx, sessionID, protocol.NewAgentDone(sessionID))

	// Update status back to ready
	m.updateSessionStatus(ctx, sessionID, protocol.StatusReady)

	// Generate title if first prompt and not already generated
	if !titleGenerated && originalPrompt != "" {
		m.mu.Lock()
		state.TitleGenerated = true
		m.mu.Unlock()

		// Request title generation from agent
		agent := m.GetAgentConnection(sessionID)
		if agent != nil {
			requestID := uuid.NewString()[:12]
			if err := agent.GenerateTitle(requestID, originalPrompt); err != nil {
				slog.Warn("Failed to request title generation", "sessionID", sessionID, "error", err)
			}
		}
	}

	// Reset streaming state for next prompt
	m.mu.Lock()
	state.CurrentMessageID = ""
	state.ContentBuilder.Reset()
	state.OriginalPrompt = ""
	m.mu.Unlock()

	slog.Info("Agent prompt completed", "sessionID", sessionID,
		"inputTokens", result.InputTokens,
		"outputTokens", result.OutputTokens,
		"turns", result.TotalTurns)

	return nil
}

// handleAgentStreamError processes errors during agent execution.
func (m *Manager) handleAgentStreamError(ctx context.Context, sessionID string, state *SessionState, agentErr *v1.AgentError) error {
	slog.Error("Agent execution error", "sessionID", sessionID, "error", agentErr.Message)

	m.emit(ctx, sessionID, protocol.NewAgentError(sessionID, agentErr.Message))
	m.updateSessionStatus(ctx, sessionID, protocol.StatusReady)

	// Reset streaming state
	m.mu.Lock()
	state.CurrentMessageID = ""
	state.ContentBuilder.Reset()
	state.OriginalPrompt = ""
	m.mu.Unlock()

	return nil
}

// HandleTerminalOutput broadcasts terminal output to clients.
func (m *Manager) HandleTerminalOutput(ctx context.Context, sessionID string, data string) error {
	m.emitTerminalOutput(ctx, sessionID, data)
	return nil
}

// HandleTitleResponse processes title generation response from agent.
func (m *Manager) HandleTitleResponse(ctx context.Context, sessionID string, requestID string, title string) error {
	if title != "" {
		m.updateSessionName(ctx, sessionID, title)
		slog.Info("Session title generated", "sessionID", sessionID, "title", title)
	}
	return nil
}

// HandleGitStatusResponse processes git status response from agent.
func (m *Manager) HandleGitStatusResponse(ctx context.Context, sessionID string, requestID string, files []*v1.GitFileChange) error {
	// Convert proto files to protocol files
	protoFiles := make([]protocol.GitFileChange, len(files))
	for i, f := range files {
		protoFiles[i] = protocol.GitFileChange{
			Path:   f.Path,
			Status: convertGitFileStatus(f.Status),
			Staged: f.Staged,
		}
	}

	// Send to waiting request
	pendingGitMu.Lock()
	if ch, ok := pendingGitStatusRequests[requestID]; ok {
		ch <- gitStatusResult{files: protoFiles, err: nil}
	}
	pendingGitMu.Unlock()

	return nil
}

// HandleGitDiffResponse processes git diff response from agent.
func (m *Manager) HandleGitDiffResponse(ctx context.Context, sessionID string, requestID string, diff string) error {
	pendingGitMu.Lock()
	if ch, ok := pendingGitDiffRequests[requestID]; ok {
		ch <- gitDiffResult{diff: diff, err: nil}
	}
	pendingGitMu.Unlock()

	return nil
}

// convertProtoEventToProtocol converts a proto AgentEvent to protocol AgentEvent.
// Handles the new oneof payload structure.
func convertProtoEventToProtocol(event *v1.AgentEvent) *protocol.AgentEvent {
	if event == nil {
		return nil
	}

	var timestamp string
	if event.Timestamp != nil {
		timestamp = event.Timestamp.AsTime().UTC().Format(time.RFC3339)
	} else {
		timestamp = time.Now().UTC().Format(time.RFC3339)
	}

	pe := &protocol.AgentEvent{
		Kind:      convertEventKind(event.Kind),
		Timestamp: timestamp,
	}

	// Extract payload based on type
	switch payload := event.Payload.(type) {
	case *v1.AgentEvent_Tool:
		if payload.Tool != nil {
			pe.Tool = payload.Tool.Tool
			pe.ToolUseID = payload.Tool.ToolUseId
			if payload.Tool.ParentToolUseId != nil {
				pe.ParentToolUseID = *payload.Tool.ParentToolUseId
			}
			if payload.Tool.Input != nil {
				pe.Input = payload.Tool.Input.AsMap()
			}
			if payload.Tool.InputDelta != nil {
				pe.InputDelta = *payload.Tool.InputDelta
			}
			if payload.Tool.Result != nil {
				pe.Result = payload.Tool.Result
			}
			if payload.Tool.Error != nil {
				pe.Error = payload.Tool.Error
			}
		}

	case *v1.AgentEvent_FileChange:
		if payload.FileChange != nil {
			pe.Path = payload.FileChange.Path
			pe.Action = convertFileAction(payload.FileChange.Action)
			if payload.FileChange.LinesAdded != nil {
				la := int(*payload.FileChange.LinesAdded)
				pe.LinesAdded = &la
			}
			if payload.FileChange.LinesRemoved != nil {
				lr := int(*payload.FileChange.LinesRemoved)
				pe.LinesRemoved = &lr
			}
		}

	case *v1.AgentEvent_Command:
		if payload.Command != nil {
			pe.Command = payload.Command.Command
			if payload.Command.Cwd != nil {
				pe.Cwd = payload.Command.Cwd
			}
			if payload.Command.ExitCode != nil {
				ec := int(*payload.Command.ExitCode)
				pe.ExitCode = &ec
			}
			if payload.Command.Output != nil {
				pe.Output = payload.Command.Output
			}
		}

	case *v1.AgentEvent_Thinking:
		if payload.Thinking != nil {
			pe.ThinkingID = payload.Thinking.ThinkingId
			pe.Content = payload.Thinking.Content
			pe.Partial = payload.Thinking.Partial
		}

	case *v1.AgentEvent_PortExposed:
		if payload.PortExposed != nil {
			pe.Port = int(payload.PortExposed.Port)
			if payload.PortExposed.Process != nil {
				pe.Process = payload.PortExposed.Process
			}
			if payload.PortExposed.PreviewUrl != nil {
				pe.PreviewURL = payload.PortExposed.PreviewUrl
			}
		}

	case *v1.AgentEvent_RepoClone:
		if payload.RepoClone != nil {
			pe.Repo = payload.RepoClone.Repo
			pe.Stage = convertRepoCloneStage(payload.RepoClone.Stage)
			pe.Message = payload.RepoClone.Message
		}
	}

	return pe
}

// convertFileAction converts proto FileAction to protocol FileAction.
func convertFileAction(action v1.FileAction) protocol.FileAction {
	switch action {
	case v1.FileAction_FILE_ACTION_CREATE:
		return protocol.FileActionCreate
	case v1.FileAction_FILE_ACTION_EDIT:
		return protocol.FileActionEdit
	case v1.FileAction_FILE_ACTION_DELETE:
		return protocol.FileActionDelete
	default:
		return protocol.FileActionUnspecified
	}
}

// convertRepoCloneStage converts proto RepoCloneStage to protocol RepoCloneStage.
func convertRepoCloneStage(stage v1.RepoCloneStage) protocol.RepoCloneStage {
	switch stage {
	case v1.RepoCloneStage_REPO_CLONE_STAGE_STARTING:
		return protocol.RepoCloneStageStarting
	case v1.RepoCloneStage_REPO_CLONE_STAGE_CLONING:
		return protocol.RepoCloneStageCloning
	case v1.RepoCloneStage_REPO_CLONE_STAGE_DONE:
		return protocol.RepoCloneStageDone
	case v1.RepoCloneStage_REPO_CLONE_STAGE_ERROR:
		return protocol.RepoCloneStageError
	default:
		return protocol.RepoCloneStageUnspecified
	}
}

// convertEventKind converts proto AgentEventKind to protocol AgentEventKind.
func convertEventKind(kind v1.AgentEventKind) protocol.AgentEventKind {
	switch kind {
	case v1.AgentEventKind_AGENT_EVENT_KIND_TOOL_START:
		return protocol.EventKindToolStart
	case v1.AgentEventKind_AGENT_EVENT_KIND_TOOL_INPUT:
		return protocol.EventKindToolInput
	case v1.AgentEventKind_AGENT_EVENT_KIND_TOOL_INPUT_COMPLETE:
		return protocol.EventKindToolInputComplete
	case v1.AgentEventKind_AGENT_EVENT_KIND_TOOL_END:
		return protocol.EventKindToolEnd
	case v1.AgentEventKind_AGENT_EVENT_KIND_FILE_CHANGE:
		return protocol.EventKindFileChange
	case v1.AgentEventKind_AGENT_EVENT_KIND_COMMAND_START:
		return protocol.EventKindCommandStart
	case v1.AgentEventKind_AGENT_EVENT_KIND_COMMAND_END:
		return protocol.EventKindCommandEnd
	case v1.AgentEventKind_AGENT_EVENT_KIND_THINKING:
		return protocol.EventKindThinking
	case v1.AgentEventKind_AGENT_EVENT_KIND_PORT_EXPOSED:
		return protocol.EventKindPortExposed
	case v1.AgentEventKind_AGENT_EVENT_KIND_REPO_CLONE:
		return protocol.EventKindRepoClone
	default:
		return protocol.AgentEventKind("unknown")
	}
}

// convertGitFileStatus converts proto GitFileStatus to string.
func convertGitFileStatus(status v1.GitFileStatus) string {
	switch status {
	case v1.GitFileStatus_GIT_FILE_STATUS_MODIFIED:
		return "modified"
	case v1.GitFileStatus_GIT_FILE_STATUS_ADDED:
		return "added"
	case v1.GitFileStatus_GIT_FILE_STATUS_DELETED:
		return "deleted"
	case v1.GitFileStatus_GIT_FILE_STATUS_RENAMED:
		return "renamed"
	case v1.GitFileStatus_GIT_FILE_STATUS_UNTRACKED:
		return "untracked"
	case v1.GitFileStatus_GIT_FILE_STATUS_COPIED:
		return "copied"
	case v1.GitFileStatus_GIT_FILE_STATUS_IGNORED:
		return "ignored"
	case v1.GitFileStatus_GIT_FILE_STATUS_UNMERGED:
		return "unmerged"
	default:
		return "unknown"
	}
}
