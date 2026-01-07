package protocol

type MessageRole string

const (
	RoleUser      MessageRole = "user"
	RoleAssistant MessageRole = "assistant"
)

type PersistedMessage struct {
	ID        string      `json:"id"`
	SessionID string      `json:"sessionId"`
	Role      MessageRole `json:"role"`
	Content   string      `json:"content"`
	Timestamp string      `json:"timestamp"`
}

type PersistedEvent struct {
	ID        string     `json:"id"`
	SessionID string     `json:"sessionId"`
	Event     AgentEvent `json:"event"`
	Timestamp string     `json:"timestamp"`
}
