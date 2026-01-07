package api

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/angristan/netclode/apps/control-plane/internal/protocol"
)

// HandleMessage dispatches a client message to the appropriate handler.
func (c *Connection) HandleMessage(ctx context.Context, msg protocol.ClientMessage) error {
	switch msg.Type {
	case protocol.MsgTypeSessionCreate:
		return c.handleSessionCreate(ctx, msg.Name, msg.Repo)
	case protocol.MsgTypeSessionList:
		return c.handleSessionList(ctx)
	case protocol.MsgTypeSessionResume:
		return c.handleSessionResume(ctx, msg.ID)
	case protocol.MsgTypeSessionPause:
		return c.handleSessionPause(ctx, msg.ID)
	case protocol.MsgTypeSessionDelete:
		return c.handleSessionDelete(ctx, msg.ID)
	case protocol.MsgTypePrompt:
		return c.handlePrompt(ctx, msg.SessionID, msg.Text)
	case protocol.MsgTypePromptInterrupt:
		return c.handlePromptInterrupt(ctx, msg.SessionID)
	case protocol.MsgTypeTerminalInput:
		return c.handleTerminalInput(ctx, msg.SessionID, msg.Data)
	case protocol.MsgTypeTerminalResize:
		return c.handleTerminalResize(ctx, msg.SessionID, msg.Cols, msg.Rows)
	case protocol.MsgTypeSync:
		return c.handleSync(ctx)
	case protocol.MsgTypeSessionOpen:
		return c.handleSessionOpen(ctx, msg.ID, msg.LastMessageID)
	default:
		return fmt.Errorf("unknown message type: %s", msg.Type)
	}
}

func (c *Connection) handleSessionCreate(ctx context.Context, name, repo string) error {
	var repoPtr *string
	if repo != "" {
		repoPtr = &repo
	}

	session, err := c.manager.Create(ctx, name, repoPtr)
	if err != nil {
		return err
	}

	// Auto-subscribe to agent messages (now uses channels)
	if err := c.subscribe(session.ID); err != nil {
		slog.Warn("Failed to subscribe to new session", "sessionID", session.ID, "error", err)
	}

	// Send created message to this client
	if err := c.Send(protocol.NewSessionCreated(session)); err != nil {
		return err
	}

	// Broadcast to all other clients for cross-client sync
	c.server.BroadcastToAll(protocol.NewSessionCreated(session), c)

	return nil
}

func (c *Connection) handleSessionList(ctx context.Context) error {
	sessions, err := c.manager.List(ctx)
	if err != nil {
		return err
	}

	return c.Send(protocol.NewSessionListMsg(sessions))
}

func (c *Connection) handleSessionResume(ctx context.Context, id string) error {
	session, err := c.manager.Resume(ctx, id)
	if err != nil {
		return err
	}

	// Auto-subscribe to agent messages
	if err := c.subscribe(id); err != nil {
		slog.Warn("Failed to subscribe to resumed session", "sessionID", id, "error", err)
	}

	return c.Send(protocol.NewSessionUpdated(session))
}

func (c *Connection) handleSessionPause(ctx context.Context, id string) error {
	session, err := c.manager.Pause(ctx, id)
	if err != nil {
		return err
	}

	// Unsubscribe from agent messages
	c.unsubscribe(id)

	return c.Send(protocol.NewSessionUpdated(session))
}

func (c *Connection) handleSessionDelete(ctx context.Context, id string) error {
	// Unsubscribe first
	c.unsubscribe(id)

	if err := c.manager.Delete(ctx, id); err != nil {
		return err
	}

	// Send deleted message to this client
	if err := c.Send(protocol.NewSessionDeleted(id)); err != nil {
		return err
	}

	// Broadcast to all other clients for cross-client sync
	c.server.BroadcastToAll(protocol.NewSessionDeleted(id), c)

	return nil
}

func (c *Connection) handlePrompt(ctx context.Context, sessionID, text string) error {
	if sessionID == "" {
		return fmt.Errorf("sessionId is required")
	}
	if text == "" {
		return fmt.Errorf("text is required")
	}

	// Fire and forget - responses come via subscription
	if err := c.manager.SendPrompt(ctx, sessionID, text); err != nil {
		return err
	}

	return nil
}

func (c *Connection) handlePromptInterrupt(ctx context.Context, sessionID string) error {
	return c.manager.Interrupt(ctx, sessionID)
}

func (c *Connection) handleTerminalInput(ctx context.Context, sessionID, data string) error {
	// Terminal input not yet implemented
	slog.Debug("Terminal input received", "sessionID", sessionID, "dataLen", len(data))
	return nil
}

func (c *Connection) handleTerminalResize(ctx context.Context, sessionID string, cols, rows int) error {
	// Terminal resize not yet implemented
	slog.Debug("Terminal resize received", "sessionID", sessionID, "cols", cols, "rows", rows)
	return nil
}

func (c *Connection) handleSync(ctx context.Context) error {
	sessions, err := c.manager.GetAllWithMeta(ctx)
	if err != nil {
		return err
	}

	return c.Send(protocol.NewSyncResponse(sessions, time.Now().UTC().Format(time.RFC3339)))
}

func (c *Connection) handleSessionOpen(ctx context.Context, id string, lastMessageID *string) error {
	session, messages, events, hasMore, err := c.manager.GetWithHistory(ctx, id, 100)
	if err != nil {
		return err
	}

	// Auto-subscribe to agent messages
	if err := c.subscribe(id); err != nil {
		slog.Warn("Failed to subscribe to opened session", "sessionID", id, "error", err)
	}

	return c.Send(protocol.NewSessionState(session, messages, events, hasMore))
}
