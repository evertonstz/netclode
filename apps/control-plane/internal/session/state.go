package session

import (
	"sync"

	"github.com/angristan/netclode/apps/control-plane/internal/protocol"
)

// SessionState holds the in-memory state for a session.
type SessionState struct {
	Session     *protocol.Session
	ServiceFQDN string // DNS name of the agent service when running

	// Channel-based broadcasting
	broadcast  chan protocol.ServerMessage
	clients    map[*Subscriber]struct{}
	register   chan *Subscriber
	unregister chan *Subscriber
	done       chan struct{}
	mu         sync.RWMutex
}

// Subscriber represents a WebSocket client subscribed to a session.
type Subscriber struct {
	Send chan protocol.ServerMessage
}

// NewSessionState creates a new session state with broadcast channel.
func NewSessionState(session *protocol.Session) *SessionState {
	s := &SessionState{
		Session:    session,
		broadcast:  make(chan protocol.ServerMessage, 256),
		clients:    make(map[*Subscriber]struct{}),
		register:   make(chan *Subscriber),
		unregister: make(chan *Subscriber),
		done:       make(chan struct{}),
	}
	go s.run()
	return s
}

// run handles the broadcast loop for this session.
func (s *SessionState) run() {
	for {
		select {
		case sub := <-s.register:
			s.mu.Lock()
			s.clients[sub] = struct{}{}
			s.mu.Unlock()

		case sub := <-s.unregister:
			s.mu.Lock()
			if _, ok := s.clients[sub]; ok {
				delete(s.clients, sub)
				close(sub.Send)
			}
			s.mu.Unlock()

		case msg := <-s.broadcast:
			s.mu.RLock()
			for sub := range s.clients {
				select {
				case sub.Send <- msg:
				default:
					// Client buffer full, skip (non-blocking)
				}
			}
			s.mu.RUnlock()

		case <-s.done:
			s.mu.Lock()
			for sub := range s.clients {
				close(sub.Send)
				delete(s.clients, sub)
			}
			s.mu.Unlock()
			return
		}
	}
}

// Subscribe adds a subscriber to this session.
func (s *SessionState) Subscribe() *Subscriber {
	sub := &Subscriber{
		Send: make(chan protocol.ServerMessage, 64),
	}
	s.register <- sub
	return sub
}

// Unsubscribe removes a subscriber from this session.
func (s *SessionState) Unsubscribe(sub *Subscriber) {
	select {
	case s.unregister <- sub:
	case <-s.done:
	}
}

// Broadcast sends a message to all subscribers.
func (s *SessionState) Broadcast(msg protocol.ServerMessage) {
	select {
	case s.broadcast <- msg:
	case <-s.done:
	}
}

// Close stops the broadcast loop and closes all subscriber channels.
func (s *SessionState) Close() {
	close(s.done)
}

// SubscriberCount returns the number of active subscribers.
func (s *SessionState) SubscriberCount() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.clients)
}
