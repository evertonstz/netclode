package protocol

type SessionStatus string

const (
	StatusCreating SessionStatus = "creating"
	StatusReady    SessionStatus = "ready"
	StatusRunning  SessionStatus = "running"
	StatusPaused   SessionStatus = "paused"
	StatusError    SessionStatus = "error"
)

type Session struct {
	ID           string        `json:"id"`
	Name         string        `json:"name"`
	Status       SessionStatus `json:"status"`
	Repo         *string       `json:"repo,omitempty"`
	CreatedAt    string        `json:"createdAt"`
	LastActiveAt string        `json:"lastActiveAt"`
}

type SessionWithMeta struct {
	Session
	MessageCount  *int    `json:"messageCount,omitempty"`
	LastMessageID *string `json:"lastMessageId,omitempty"`
}

type SessionCreateRequest struct {
	Name *string `json:"name,omitempty"`
	Repo *string `json:"repo,omitempty"`
}
