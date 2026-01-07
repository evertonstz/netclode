package storage

import (
	"context"

	"github.com/angristan/netclode/apps/control-plane/internal/protocol"
)

// Storage defines the interface for session persistence.
type Storage interface {
	// Sessions
	SaveSession(ctx context.Context, s *protocol.Session) error
	GetSession(ctx context.Context, id string) (*protocol.Session, error)
	GetAllSessions(ctx context.Context) ([]*protocol.Session, error)
	UpdateSessionStatus(ctx context.Context, id string, status protocol.SessionStatus) error
	UpdateSessionField(ctx context.Context, id, field, value string) error
	DeleteSession(ctx context.Context, id string) error

	// Messages
	AppendMessage(ctx context.Context, msg *protocol.PersistedMessage) error
	GetMessages(ctx context.Context, sessionID string, afterID *string) ([]*protocol.PersistedMessage, error)
	GetLastMessage(ctx context.Context, sessionID string) (*protocol.PersistedMessage, error)
	GetMessageCount(ctx context.Context, sessionID string) (int, error)

	// Events
	AppendEvent(ctx context.Context, evt *protocol.PersistedEvent) error
	GetEvents(ctx context.Context, sessionID string, limit int) ([]*protocol.PersistedEvent, error)

	// Lifecycle
	Close() error
}
