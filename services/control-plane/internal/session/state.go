package session

import (
	"strings"

	"github.com/angristan/netclode/services/control-plane/internal/protocol"
)

// SessionState holds the in-memory state for a session.
// Real-time updates are handled via Redis Streams, not in-memory channels.
type SessionState struct {
	Session       *protocol.Session
	ServiceFQDN   string // DNS name of the agent service when running (legacy, kept for k8s)
	PendingPrompt string // Prompt queued before agent connected

	// Agent streaming state
	CurrentMessageID string
	ContentBuilder   strings.Builder
	TitleGenerated   bool
	OriginalPrompt   string
	ThinkingBuffers  map[string]string
}

// NewSessionState creates a new session state.
func NewSessionState(session *protocol.Session) *SessionState {
	return &SessionState{
		Session:         session,
		ThinkingBuffers: make(map[string]string),
	}
}

// Close is a no-op now that we use Redis Streams for real-time.
// Kept for backwards compatibility with existing code.
func (s *SessionState) Close() {
	// No-op - StreamSubscribers are closed by their context
}
