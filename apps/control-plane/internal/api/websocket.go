package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"

	"github.com/angristan/netclode/apps/control-plane/internal/protocol"
	"github.com/angristan/netclode/apps/control-plane/internal/session"
	"github.com/coder/websocket"
)

// Connection represents a WebSocket connection.
type Connection struct {
	ws      *websocket.Conn
	manager *session.Manager

	// Channel-based subscriptions
	subscriptions map[string]*session.Subscriber // sessionID -> subscriber
	subMu         sync.Mutex

	// For graceful shutdown
	done    chan struct{}
	writeMu sync.Mutex
}

// NewConnection creates a new WebSocket connection handler.
func NewConnection(ws *websocket.Conn, manager *session.Manager) *Connection {
	return &Connection{
		ws:            ws,
		manager:       manager,
		subscriptions: make(map[string]*session.Subscriber),
		done:          make(chan struct{}),
	}
}

// Run handles the WebSocket connection lifecycle.
func (c *Connection) Run(ctx context.Context) {
	defer c.Close()

	for {
		select {
		case <-c.done:
			return
		default:
		}

		_, data, err := c.ws.Read(ctx)
		if err != nil {
			if websocket.CloseStatus(err) != -1 {
				// Normal close
				return
			}
			slog.Warn("WebSocket read error", "error", err)
			return
		}

		var msg protocol.ClientMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			c.Send(protocol.NewError("Invalid JSON: " + err.Error()))
			continue
		}

		if err := c.HandleMessage(ctx, msg); err != nil {
			slog.Warn("Handler error", "type", msg.Type, "error", err)
			c.Send(protocol.NewError(err.Error()))
		}
	}
}

// Send sends a message to the client.
func (c *Connection) Send(msg protocol.ServerMessage) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}

	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	return c.ws.Write(context.Background(), websocket.MessageText, data)
}

// Close closes the connection and unsubscribes from all sessions.
func (c *Connection) Close() {
	// Signal done
	select {
	case <-c.done:
		// Already closed
		return
	default:
		close(c.done)
	}

	// Unsubscribe from all sessions
	c.subMu.Lock()
	for sessionID, sub := range c.subscriptions {
		c.manager.Unsubscribe(sessionID, sub)
	}
	c.subscriptions = make(map[string]*session.Subscriber)
	c.subMu.Unlock()

	c.ws.Close(websocket.StatusNormalClosure, "")
}

// subscribe adds a subscription for a session and starts forwarding messages.
func (c *Connection) subscribe(sessionID string) error {
	c.subMu.Lock()
	defer c.subMu.Unlock()

	// Already subscribed
	if _, ok := c.subscriptions[sessionID]; ok {
		return nil
	}

	sub, err := c.manager.Subscribe(sessionID)
	if err != nil {
		return err
	}

	c.subscriptions[sessionID] = sub

	// Start goroutine to forward messages from subscriber channel to WebSocket
	go c.forwardMessages(sessionID, sub)

	return nil
}

// forwardMessages reads from the subscriber channel and sends to WebSocket.
func (c *Connection) forwardMessages(sessionID string, sub *session.Subscriber) {
	for {
		select {
		case msg, ok := <-sub.Send:
			if !ok {
				// Channel closed, subscriber removed
				return
			}
			if err := c.Send(msg); err != nil {
				slog.Debug("Failed to forward message", "sessionID", sessionID, "error", err)
				return
			}
		case <-c.done:
			return
		}
	}
}

// unsubscribe removes a subscription for a session.
func (c *Connection) unsubscribe(sessionID string) {
	c.subMu.Lock()
	defer c.subMu.Unlock()

	if sub, ok := c.subscriptions[sessionID]; ok {
		c.manager.Unsubscribe(sessionID, sub)
		delete(c.subscriptions, sessionID)
	}
}
