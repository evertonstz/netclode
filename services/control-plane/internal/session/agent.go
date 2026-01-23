package session

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/angristan/netclode/services/control-plane/internal/protocol"
	"github.com/google/uuid"
)

const (
	interruptTimeout = 5 * time.Second
)

// SendPrompt sends a prompt to the agent and streams the response.
// If the sandbox isn't ready yet, queues the prompt to be sent when ready.
func (m *Manager) SendPrompt(ctx context.Context, sessionID, text string) error {
	state := m.getState(sessionID)
	if state == nil {
		return fmt.Errorf("session %s not found", sessionID)
	}

	// Check if agent is connected
	agent := m.GetAgentConnection(sessionID)
	if agent == nil {
		// Agent not connected yet - queue the prompt
		slog.Info("Queueing prompt until agent connects", "sessionID", sessionID)
		m.mu.Lock()
		state.PendingPrompt = text
		m.mu.Unlock()
		// Still set status to running so UI shows activity
		m.updateSessionStatus(ctx, sessionID, protocol.StatusRunning)
		return nil
	}

	// Persist user message
	userMsg := &protocol.PersistedMessage{
		ID:        "msg_" + uuid.NewString()[:12],
		SessionID: sessionID,
		Role:      protocol.RoleUser,
		Content:   text,
		Timestamp: time.Now().UTC().Format(time.RFC3339),
	}
	if err := m.storage.AppendMessage(ctx, userMsg); err != nil {
		slog.Warn("Failed to persist user message", "sessionID", sessionID, "error", err)
	}

	// Broadcast user message to all subscribers (for cross-client sync)
	m.emit(ctx, sessionID, protocol.NewUserMessage(sessionID, text))

	// Update session status to running and last active time
	m.updateSessionStatus(ctx, sessionID, protocol.StatusRunning)
	m.updateLastActiveAt(ctx, sessionID)

	// Initialize streaming state
	m.mu.Lock()
	state.CurrentMessageID = "msg_" + uuid.NewString()[:12]
	state.ContentBuilder.Reset()
	state.OriginalPrompt = text
	m.mu.Unlock()

	// Send prompt to agent via bidirectional stream
	if err := agent.ExecutePrompt(text); err != nil {
		slog.Error("Failed to send prompt to agent", "sessionID", sessionID, "error", err)
		m.emit(ctx, sessionID, protocol.NewAgentError(sessionID, err.Error()))
		m.updateSessionStatus(ctx, sessionID, protocol.StatusReady)
		return err
	}

	return nil
}

func (m *Manager) handleAgentError(ctx context.Context, sessionID string, err error) {
	slog.Error("Agent error", "sessionID", sessionID, "error", err)
	m.emit(ctx, sessionID, protocol.NewAgentError(sessionID, err.Error()))
	m.updateSessionStatus(ctx, sessionID, protocol.StatusReady)
}

// pendingGitRequests tracks pending git status/diff requests with response channels
type gitStatusResult struct {
	files []protocol.GitFileChange
	err   error
}

type gitDiffResult struct {
	diff string
	err  error
}

var (
	pendingGitStatusRequests = make(map[string]chan gitStatusResult)
	pendingGitDiffRequests   = make(map[string]chan gitDiffResult)
	pendingGitMu             sync.Mutex
)

// GetGitStatus fetches git status from the agent.
func (m *Manager) GetGitStatus(ctx context.Context, sessionID string) ([]protocol.GitFileChange, error) {
	agent := m.GetAgentConnection(sessionID)
	if agent == nil {
		return nil, fmt.Errorf("no agent connected for session %s", sessionID)
	}

	requestID := uuid.NewString()[:12]
	resultCh := make(chan gitStatusResult, 1)

	pendingGitMu.Lock()
	pendingGitStatusRequests[requestID] = resultCh
	pendingGitMu.Unlock()

	defer func() {
		pendingGitMu.Lock()
		delete(pendingGitStatusRequests, requestID)
		pendingGitMu.Unlock()
	}()

	if err := agent.GetGitStatus(requestID); err != nil {
		return nil, fmt.Errorf("failed to request git status: %w", err)
	}

	select {
	case result := <-resultCh:
		return result.files, result.err
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-time.After(30 * time.Second):
		return nil, fmt.Errorf("git status request timed out")
	}
}

// GetGitDiff fetches git diff for a file from the agent.
func (m *Manager) GetGitDiff(ctx context.Context, sessionID, file string) (string, error) {
	agent := m.GetAgentConnection(sessionID)
	if agent == nil {
		return "", fmt.Errorf("no agent connected for session %s", sessionID)
	}

	requestID := uuid.NewString()[:12]
	resultCh := make(chan gitDiffResult, 1)

	pendingGitMu.Lock()
	pendingGitDiffRequests[requestID] = resultCh
	pendingGitMu.Unlock()

	defer func() {
		pendingGitMu.Lock()
		delete(pendingGitDiffRequests, requestID)
		pendingGitMu.Unlock()
	}()

	var filePtr *string
	if file != "" {
		filePtr = &file
	}

	if err := agent.GetGitDiff(requestID, filePtr); err != nil {
		return "", fmt.Errorf("failed to request git diff: %w", err)
	}

	select {
	case result := <-resultCh:
		return result.diff, result.err
	case <-ctx.Done():
		return "", ctx.Err()
	case <-time.After(30 * time.Second):
		return "", fmt.Errorf("git diff request timed out")
	}
}

// Interrupt sends an interrupt signal to the agent.
func (m *Manager) Interrupt(ctx context.Context, sessionID string) error {
	agent := m.GetAgentConnection(sessionID)
	if agent == nil {
		return fmt.Errorf("no agent connected for session %s", sessionID)
	}

	return agent.Interrupt()
}
