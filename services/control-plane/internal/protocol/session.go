package protocol

// SessionStatus represents the lifecycle state of a session.
type SessionStatus string

const (
	StatusCreating    SessionStatus = "creating"
	StatusResuming    SessionStatus = "resuming"
	StatusReady       SessionStatus = "ready"
	StatusRunning     SessionStatus = "running"
	StatusPaused      SessionStatus = "paused"
	StatusError       SessionStatus = "error"
	StatusInterrupted SessionStatus = "interrupted" // Agent disconnected during execution
)

// RepoAccess defines the permission level for repository operations.
type RepoAccess string

const (
	RepoAccessUnspecified RepoAccess = ""
	RepoAccessRead        RepoAccess = "read"
	RepoAccessWrite       RepoAccess = "write"
)

// Session represents a coding session with an AI agent.
type Session struct {
	ID           string        `json:"id"`
	Name         string        `json:"name"`
	Status       SessionStatus `json:"status"`
	Repo         *string       `json:"repo,omitempty"`
	RepoAccess   *RepoAccess   `json:"repoAccess,omitempty"`
	CreatedAt    string        `json:"createdAt"`
	LastActiveAt string        `json:"lastActiveAt"`
}

// SessionSummary includes session data plus metadata for list views.
// Renamed from SessionWithMeta for clarity.
type SessionSummary struct {
	Session
	MessageCount  *int    `json:"messageCount,omitempty"`
	LastMessageID *string `json:"lastMessageId,omitempty"`
}

// SessionCreateRequest contains parameters for creating a new session.
type SessionCreateRequest struct {
	Name       *string     `json:"name,omitempty"`
	Repo       *string     `json:"repo,omitempty"`
	RepoAccess *RepoAccess `json:"repoAccess,omitempty"`
}
