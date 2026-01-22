package api

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"time"

	"connectrpc.com/connect"
	pb "github.com/angristan/netclode/services/control-plane/gen/netclode/v1"
	"github.com/angristan/netclode/services/control-plane/gen/netclode/v1/netclodev1connect"
	"github.com/angristan/netclode/services/control-plane/internal/protocol"
	"github.com/angristan/netclode/services/control-plane/internal/session"
	"google.golang.org/protobuf/types/known/structpb"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// Validation errors for client requests
var (
	errSessionIDRequired = errors.New("sessionId is required")
	errTextRequired      = errors.New("text is required")
	errUnknownMessage    = errors.New("unknown message type")
)

// makeErrorResponse creates a unified error response.
func makeErrorResponse(sessionID, code, message string) *pb.ServerMessage {
	var sessID *string
	if sessionID != "" {
		sessID = &sessionID
	}
	return &pb.ServerMessage{
		Message: &pb.ServerMessage_Error{
			Error: &pb.ErrorResponse{
				Error: &pb.Error{
					Code:      code,
					Message:   message,
					SessionId: sessID,
				},
			},
		},
	}
}

// Ensure ConnectClientServiceHandler implements the interface
var _ netclodev1connect.ClientServiceHandler = (*ConnectClientServiceHandler)(nil)

// subscriptionInfo holds subscription state for a session.
type subscriptionInfo struct {
	sub    *session.StreamSubscriber
	cancel context.CancelFunc
}

// ConnectClientServiceHandler implements the Connect ClientService.
type ConnectClientServiceHandler struct {
	netclodev1connect.UnimplementedClientServiceHandler
	manager *session.Manager
	server  *Server
}

// NewConnectClientServiceHandler creates a new Connect client service handler.
func NewConnectClientServiceHandler(manager *session.Manager, server *Server) *ConnectClientServiceHandler {
	return &ConnectClientServiceHandler{
		manager: manager,
		server:  server,
	}
}

// ConnectConnection represents a Connect bidirectional stream connection.
type ConnectConnection struct {
	stream  *connect.BidiStream[pb.ClientMessage, pb.ServerMessage]
	manager *session.Manager
	server  *Server

	// Redis Streams-based subscriptions
	subscriptions map[string]*subscriptionInfo // sessionID -> subscription info
	subMu         sync.Mutex

	// Global messages channel (session create/delete events)
	globalMessages chan *pb.ServerMessage

	// For graceful shutdown
	done    chan struct{}
	writeMu sync.Mutex
}

// Connect implements the bidirectional streaming RPC using Connect protocol.
func (h *ConnectClientServiceHandler) Connect(ctx context.Context, stream *connect.BidiStream[pb.ClientMessage, pb.ServerMessage]) error {
	conn := &ConnectConnection{
		stream:         stream,
		manager:        h.manager,
		server:         h.server,
		subscriptions:  make(map[string]*subscriptionInfo),
		globalMessages: make(chan *pb.ServerMessage, 64),
		done:           make(chan struct{}),
	}

	// Track connection
	h.server.connectConnections.Store(conn, struct{}{})
	h.server.connCount.Add(1)
	h.server.wg.Add(1)

	slog.Info("Connect connection opened", "activeConnections", h.server.connCount.Load())

	// Start goroutine to forward global messages
	go conn.forwardGlobalMessages()

	// Handle the connection
	err := conn.run(ctx)

	// Cleanup
	conn.close()
	h.server.connectConnections.Delete(conn)
	h.server.connCount.Add(-1)
	h.server.wg.Done()

	slog.Info("Connect connection closed", "activeConnections", h.server.connCount.Load())

	return err
}

// run handles the Connect connection lifecycle.
func (c *ConnectConnection) run(ctx context.Context) error {
	for {
		// Check for shutdown before blocking on Receive
		select {
		case <-c.done:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		default:
			// Continue to receive
		}

		// Receive blocks until a message arrives or the stream closes.
		// We check ctx.Done() after receive errors to handle cancellation.
		msg, err := c.stream.Receive()
		if err != nil {
			// Check for graceful close first
			if err == io.EOF {
				return nil
			}
			// Check if context was cancelled while we were blocked
			select {
			case <-c.done:
				return nil
			case <-ctx.Done():
				return nil
			default:
			}
			slog.Warn("Connect recv error", "error", err)
			return err
		}

		if err := c.handleMessage(ctx, msg); err != nil {
			slog.Warn("Connect handler error", "error", err)
			c.send(makeErrorResponse("", "HANDLER_ERROR", err.Error()))
		}
	}
}

// handleMessage dispatches a client message to the appropriate handler.
func (c *ConnectConnection) handleMessage(ctx context.Context, msg *pb.ClientMessage) error {
	switch m := msg.Message.(type) {
	case *pb.ClientMessage_CreateSession:
		return c.handleSessionCreate(ctx, m.CreateSession)
	case *pb.ClientMessage_ListSessions:
		return c.handleSessionList(ctx)
	case *pb.ClientMessage_OpenSession:
		return c.handleSessionOpen(ctx, m.OpenSession)
	case *pb.ClientMessage_ResumeSession:
		return c.handleSessionResume(ctx, m.ResumeSession.SessionId)
	case *pb.ClientMessage_PauseSession:
		return c.handleSessionPause(ctx, m.PauseSession.SessionId)
	case *pb.ClientMessage_DeleteSession:
		return c.handleSessionDelete(ctx, m.DeleteSession.SessionId)
	case *pb.ClientMessage_DeleteAllSessions:
		return c.handleSessionDeleteAll(ctx)
	case *pb.ClientMessage_SendPrompt:
		return c.handlePrompt(ctx, m.SendPrompt.SessionId, m.SendPrompt.Text)
	case *pb.ClientMessage_InterruptPrompt:
		return c.handlePromptInterrupt(ctx, m.InterruptPrompt.SessionId)
	case *pb.ClientMessage_TerminalInput:
		return c.handleTerminalInput(ctx, m.TerminalInput.SessionId, m.TerminalInput.Data)
	case *pb.ClientMessage_TerminalResize:
		return c.handleTerminalResize(ctx, m.TerminalResize)
	case *pb.ClientMessage_Sync:
		return c.handleSync(ctx)
	case *pb.ClientMessage_ExposePort:
		return c.handlePortExpose(ctx, m.ExposePort.SessionId, int(m.ExposePort.Port))
	case *pb.ClientMessage_ListGithubRepos:
		return c.handleGitHubReposList(ctx)
	case *pb.ClientMessage_GitStatus:
		return c.handleGitStatus(ctx, m.GitStatus.SessionId)
	case *pb.ClientMessage_GitDiff:
		return c.handleGitDiff(ctx, m.GitDiff)
	default:
		return connect.NewError(connect.CodeInvalidArgument, errUnknownMessage)
	}
}

// send sends a message to the client.
func (c *ConnectConnection) send(msg *pb.ServerMessage) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	return c.stream.Send(msg)
}

// close closes the connection and cancels all subscriptions.
func (c *ConnectConnection) close() {
	select {
	case <-c.done:
		return
	default:
		close(c.done)
	}

	c.subMu.Lock()
	for _, info := range c.subscriptions {
		info.cancel()
	}
	c.subscriptions = make(map[string]*subscriptionInfo)
	c.subMu.Unlock()
}

// forwardGlobalMessages reads from the global messages channel and sends to stream.
func (c *ConnectConnection) forwardGlobalMessages() {
	for {
		select {
		case msg, ok := <-c.globalMessages:
			if !ok {
				return
			}
			if err := c.send(msg); err != nil {
				slog.Debug("Failed to forward global message", "error", err)
				return
			}
		case <-c.done:
			return
		}
	}
}

// subscribe adds a subscription for a session.
func (c *ConnectConnection) subscribe(_ context.Context, sessionID string, lastNotificationID string) error {
	c.subMu.Lock()
	defer c.subMu.Unlock()

	if old, ok := c.subscriptions[sessionID]; ok {
		old.cancel()
		delete(c.subscriptions, sessionID)
	}

	subCtx, cancel := context.WithCancel(context.Background())

	sub, err := c.manager.Subscribe(subCtx, sessionID, lastNotificationID)
	if err != nil {
		cancel()
		return err
	}

	c.subscriptions[sessionID] = &subscriptionInfo{
		sub:    sub,
		cancel: cancel,
	}

	go c.forwardMessages(sessionID, sub)

	return nil
}

// forwardMessages reads from the StreamSubscriber and sends to stream.
func (c *ConnectConnection) forwardMessages(sessionID string, sub *session.StreamSubscriber) {
	for {
		select {
		case msg, ok := <-sub.Messages():
			if !ok {
				return
			}
			pbMsg := convertServerMessage(msg)
			if err := c.send(pbMsg); err != nil {
				slog.Debug("Failed to forward message", "sessionID", sessionID, "error", err)
				return
			}
		case <-c.done:
			return
		}
	}
}

// unsubscribe removes a subscription for a session.
func (c *ConnectConnection) unsubscribe(sessionID string) {
	c.subMu.Lock()
	defer c.subMu.Unlock()

	if info, ok := c.subscriptions[sessionID]; ok {
		info.cancel()
		delete(c.subscriptions, sessionID)
	}
}

// Handler implementations

func (c *ConnectConnection) handleSessionCreate(ctx context.Context, req *pb.CreateSessionRequest) error {
	var repoPtr *string
	var repoAccessPtr *protocol.RepoAccess
	if req.Repo != nil {
		repoPtr = req.Repo
	}
	if req.RepoAccess != nil {
		access := convertProtoRepoAccess(*req.RepoAccess)
		repoAccessPtr = &access
	}

	name := ""
	if req.Name != nil {
		name = *req.Name
	}

	sess, err := c.manager.Create(ctx, name, repoPtr, repoAccessPtr)
	if err != nil {
		return err
	}

	if err := c.subscribe(ctx, sess.ID, "$"); err != nil {
		slog.Warn("Failed to subscribe to new session", "sessionID", sess.ID, "error", err)
	}

	pbSession := convertSession(sess)
	msg := &pb.ServerMessage{
		Message: &pb.ServerMessage_SessionCreated{
			SessionCreated: &pb.SessionCreatedResponse{Session: pbSession},
		},
	}

	if err := c.send(msg); err != nil {
		return err
	}

	// Broadcast to other clients
	c.server.BroadcastToAllConnect(msg, c)

	// Send initial prompt if provided
	if req.InitialPrompt != nil && *req.InitialPrompt != "" {
		slog.Info("Sending initial prompt", "sessionID", sess.ID)
		if err := c.manager.SendPrompt(ctx, sess.ID, *req.InitialPrompt); err != nil {
			slog.Warn("Failed to send initial prompt", "sessionID", sess.ID, "error", err)
		}
	}

	return nil
}

func (c *ConnectConnection) handleSessionList(ctx context.Context) error {
	sessions, err := c.manager.List(ctx)
	if err != nil {
		return err
	}

	pbSessions := make([]*pb.Session, len(sessions))
	for i, s := range sessions {
		pbSessions[i] = convertSession(&s)
	}

	return c.send(&pb.ServerMessage{
		Message: &pb.ServerMessage_SessionList{
			SessionList: &pb.SessionListResponse{Sessions: pbSessions},
		},
	})
}

func (c *ConnectConnection) handleSessionOpen(ctx context.Context, req *pb.OpenSessionRequest) error {
	var lastMsgID, lastNotifID *string
	if req.LastMessageId != nil {
		lastMsgID = req.LastMessageId
	}
	if req.LastNotificationId != nil {
		lastNotifID = req.LastNotificationId
	}
	_ = lastMsgID // unused for now

	sess, messages, events, hasMore, currentNotificationID, err := c.manager.GetWithHistory(ctx, req.SessionId, 100)
	if err != nil {
		return err
	}

	cursor := currentNotificationID
	if lastNotifID != nil && *lastNotifID != "" {
		cursor = *lastNotifID
	}

	if err := c.subscribe(ctx, req.SessionId, cursor); err != nil {
		slog.Warn("Failed to subscribe to opened session", "sessionID", req.SessionId, "error", err)
	}

	pbMessages := make([]*pb.PersistedMessage, len(messages))
	for i, m := range messages {
		pbMessages[i] = convertPersistedMessage(&m)
	}

	pbEvents := make([]*pb.PersistedEvent, len(events))
	for i, e := range events {
		pbEvents[i] = convertPersistedEvent(&e)
	}

	resp := &pb.SessionStateResponse{
		Session:            convertSession(sess),
		Messages:           pbMessages,
		Events:             pbEvents,
		HasMore:            hasMore,
		LastNotificationId: &currentNotificationID,
	}

	return c.send(&pb.ServerMessage{
		Message: &pb.ServerMessage_SessionState{SessionState: resp},
	})
}

func (c *ConnectConnection) handleSessionResume(ctx context.Context, id string) error {
	sess, err := c.manager.Resume(ctx, id)
	if err != nil {
		return err
	}

	if err := c.subscribe(ctx, id, "$"); err != nil {
		slog.Warn("Failed to subscribe to resumed session", "sessionID", id, "error", err)
	}

	msg := &pb.ServerMessage{
		Message: &pb.ServerMessage_SessionUpdated{
			SessionUpdated: &pb.SessionUpdatedResponse{Session: convertSession(sess)},
		},
	}

	if err := c.send(msg); err != nil {
		return err
	}

	c.server.BroadcastToAllConnect(msg, c)
	return nil
}

func (c *ConnectConnection) handleSessionPause(ctx context.Context, id string) error {
	sess, err := c.manager.Pause(ctx, id)
	if err != nil {
		return err
	}

	c.unsubscribe(id)

	msg := &pb.ServerMessage{
		Message: &pb.ServerMessage_SessionUpdated{
			SessionUpdated: &pb.SessionUpdatedResponse{Session: convertSession(sess)},
		},
	}

	if err := c.send(msg); err != nil {
		return err
	}

	c.server.BroadcastToAllConnect(msg, c)
	return nil
}

func (c *ConnectConnection) handleSessionDelete(ctx context.Context, id string) error {
	c.unsubscribe(id)

	if err := c.manager.Delete(ctx, id); err != nil {
		return err
	}

	msg := &pb.ServerMessage{
		Message: &pb.ServerMessage_SessionDeleted{
			SessionDeleted: &pb.SessionDeletedResponse{SessionId: id},
		},
	}

	if err := c.send(msg); err != nil {
		return err
	}

	c.server.BroadcastToAllConnect(msg, c)
	return nil
}

func (c *ConnectConnection) handleSessionDeleteAll(ctx context.Context) error {
	deletedIDs, err := c.manager.DeleteAll(ctx)
	if err != nil {
		slog.Warn("Some sessions failed to delete", "error", err)
	}

	msg := &pb.ServerMessage{
		Message: &pb.ServerMessage_SessionsDeletedAll{
			SessionsDeletedAll: &pb.SessionsDeletedAllResponse{DeletedIds: deletedIDs},
		},
	}

	if err := c.send(msg); err != nil {
		return err
	}

	c.server.BroadcastToAllConnect(msg, c)
	return nil
}

func (c *ConnectConnection) handlePrompt(ctx context.Context, sessionID, text string) error {
	if sessionID == "" {
		return connect.NewError(connect.CodeInvalidArgument, errSessionIDRequired)
	}
	if text == "" {
		return connect.NewError(connect.CodeInvalidArgument, errTextRequired)
	}

	return c.manager.SendPrompt(ctx, sessionID, text)
}

func (c *ConnectConnection) handlePromptInterrupt(ctx context.Context, sessionID string) error {
	return c.manager.Interrupt(ctx, sessionID)
}

func (c *ConnectConnection) handleTerminalInput(ctx context.Context, sessionID, data string) error {
	if sessionID == "" {
		return connect.NewError(connect.CodeInvalidArgument, errSessionIDRequired)
	}
	if data == "" {
		return nil // Empty input is a no-op
	}

	return c.manager.SendTerminalInput(ctx, sessionID, data)
}

var errInvalidTerminalDimensions = errors.New("cols and rows must be positive integers")

func (c *ConnectConnection) handleTerminalResize(ctx context.Context, req *pb.TerminalResizeRequest) error {
	if req.SessionId == "" {
		return connect.NewError(connect.CodeInvalidArgument, errSessionIDRequired)
	}
	if req.Cols <= 0 || req.Rows <= 0 {
		return connect.NewError(connect.CodeInvalidArgument, errInvalidTerminalDimensions)
	}

	return c.manager.ResizeTerminal(ctx, req.SessionId, int(req.Cols), int(req.Rows))
}

func (c *ConnectConnection) handleSync(ctx context.Context) error {
	sessions, err := c.manager.GetAllWithMeta(ctx)
	if err != nil {
		return err
	}

	pbSessions := make([]*pb.SessionSummary, len(sessions))
	for i, s := range sessions {
		pbSessions[i] = convertSessionSummary(&s)
	}

	return c.send(&pb.ServerMessage{
		Message: &pb.ServerMessage_SyncResponse{
			SyncResponse: &pb.SyncResponse{
				Sessions:   pbSessions,
				ServerTime: timestamppb.Now(),
			},
		},
	})
}

func (c *ConnectConnection) handlePortExpose(ctx context.Context, sessionID string, port int) error {
	if sessionID == "" {
		return c.send(makeErrorResponse(sessionID, "PORT_ERROR", "sessionId is required"))
	}
	if port < 1 || port > 65535 {
		return c.send(makeErrorResponse(sessionID, "PORT_ERROR", "port must be between 1 and 65535"))
	}

	previewURL, err := c.manager.ExposePort(ctx, sessionID, port)
	if err != nil {
		return c.send(makeErrorResponse(sessionID, "PORT_ERROR", err.Error()))
	}

	return c.send(&pb.ServerMessage{
		Message: &pb.ServerMessage_PortExposed{
			PortExposed: &pb.PortExposedResponse{
				SessionId:  sessionID,
				Port:       int32(port),
				PreviewUrl: previewURL,
			},
		},
	})
}

func (c *ConnectConnection) handleGitHubReposList(ctx context.Context) error {
	repos, err := c.manager.ListGitHubRepos(ctx)
	if err != nil {
		return c.send(makeErrorResponse("", "GITHUB_ERROR", "Failed to list GitHub repositories: "+err.Error()))
	}

	pbRepos := make([]*pb.GitHubRepo, len(repos))
	for i, r := range repos {
		pbRepos[i] = &pb.GitHubRepo{
			Name:     r.Name,
			FullName: r.FullName,
			Private:  r.Private,
		}
		if r.Description != "" {
			pbRepos[i].Description = &r.Description
		}
	}

	return c.send(&pb.ServerMessage{
		Message: &pb.ServerMessage_GithubRepos{
			GithubRepos: &pb.GitHubReposResponse{Repos: pbRepos},
		},
	})
}

func (c *ConnectConnection) handleGitStatus(ctx context.Context, sessionID string) error {
	if sessionID == "" {
		return c.send(makeErrorResponse(sessionID, "GIT_ERROR", "sessionId is required"))
	}

	files, err := c.manager.GetGitStatus(ctx, sessionID)
	if err != nil {
		return c.send(makeErrorResponse(sessionID, "GIT_ERROR", err.Error()))
	}

	pbFiles := make([]*pb.GitFileChange, len(files))
	for i, f := range files {
		pbFiles[i] = &pb.GitFileChange{
			Path:   f.Path,
			Status: convertGitStatus(f.Status),
			Staged: f.Staged,
		}
	}

	return c.send(&pb.ServerMessage{
		Message: &pb.ServerMessage_GitStatus{
			GitStatus: &pb.GitStatusResponse{SessionId: sessionID, Files: pbFiles},
		},
	})
}

func (c *ConnectConnection) handleGitDiff(ctx context.Context, req *pb.GitDiffRequest) error {
	if req.SessionId == "" {
		return c.send(makeErrorResponse(req.SessionId, "GIT_ERROR", "sessionId is required"))
	}

	file := ""
	if req.File != nil {
		file = *req.File
	}

	diff, err := c.manager.GetGitDiff(ctx, req.SessionId, file)
	if err != nil {
		return c.send(makeErrorResponse(req.SessionId, "GIT_ERROR", err.Error()))
	}

	return c.send(&pb.ServerMessage{
		Message: &pb.ServerMessage_GitDiff{
			GitDiff: &pb.GitDiffResponse{SessionId: req.SessionId, Diff: diff},
		},
	})
}

// Conversion helpers for protocol types to protobuf types

func convertSession(s *protocol.Session) *pb.Session {
	if s == nil {
		return nil
	}

	pbSess := &pb.Session{
		Id:     s.ID,
		Name:   s.Name,
		Status: convertSessionStatus(s.Status),
	}

	if s.Repo != nil {
		pbSess.Repo = s.Repo
	}
	if s.RepoAccess != nil {
		access := convertRepoAccessToProto(*s.RepoAccess)
		pbSess.RepoAccess = &access
	}

	if t, err := time.Parse(time.RFC3339, s.CreatedAt); err == nil {
		pbSess.CreatedAt = timestamppb.New(t)
	} else if s.CreatedAt != "" {
		slog.Warn("Failed to parse session CreatedAt timestamp",
			"sessionID", s.ID, "timestamp", s.CreatedAt, "error", err)
	}
	if t, err := time.Parse(time.RFC3339, s.LastActiveAt); err == nil {
		pbSess.LastActiveAt = timestamppb.New(t)
	} else if s.LastActiveAt != "" {
		slog.Warn("Failed to parse session LastActiveAt timestamp",
			"sessionID", s.ID, "timestamp", s.LastActiveAt, "error", err)
	}

	return pbSess
}

// convertRepoAccessToProto converts protocol RepoAccess to proto RepoAccess.
func convertRepoAccessToProto(access protocol.RepoAccess) pb.RepoAccess {
	switch access {
	case protocol.RepoAccessRead:
		return pb.RepoAccess_REPO_ACCESS_READ
	case protocol.RepoAccessWrite:
		return pb.RepoAccess_REPO_ACCESS_WRITE
	default:
		return pb.RepoAccess_REPO_ACCESS_UNSPECIFIED
	}
}

// convertProtoRepoAccess converts proto RepoAccess to protocol RepoAccess.
func convertProtoRepoAccess(access pb.RepoAccess) protocol.RepoAccess {
	switch access {
	case pb.RepoAccess_REPO_ACCESS_READ:
		return protocol.RepoAccessRead
	case pb.RepoAccess_REPO_ACCESS_WRITE:
		return protocol.RepoAccessWrite
	default:
		return protocol.RepoAccessUnspecified
	}
}

func convertSessionStatus(s protocol.SessionStatus) pb.SessionStatus {
	switch s {
	case protocol.StatusCreating:
		return pb.SessionStatus_SESSION_STATUS_CREATING
	case protocol.StatusResuming:
		return pb.SessionStatus_SESSION_STATUS_RESUMING
	case protocol.StatusReady:
		return pb.SessionStatus_SESSION_STATUS_READY
	case protocol.StatusRunning:
		return pb.SessionStatus_SESSION_STATUS_RUNNING
	case protocol.StatusPaused:
		return pb.SessionStatus_SESSION_STATUS_PAUSED
	case protocol.StatusError:
		return pb.SessionStatus_SESSION_STATUS_ERROR
	default:
		return pb.SessionStatus_SESSION_STATUS_UNSPECIFIED
	}
}

func convertSessionSummary(s *protocol.SessionSummary) *pb.SessionSummary {
	if s == nil {
		return nil
	}

	summary := &pb.SessionSummary{
		Session: convertSession(&s.Session),
	}

	if s.MessageCount != nil {
		count := int32(*s.MessageCount)
		summary.MessageCount = &count
	}
	if s.LastMessageID != nil {
		summary.LastMessageId = s.LastMessageID
	}

	return summary
}

func convertPersistedMessage(m *protocol.PersistedMessage) *pb.PersistedMessage {
	if m == nil {
		return nil
	}

	msg := &pb.PersistedMessage{
		Id:      m.ID,
		Role:    convertMessageRole(m.Role),
		Content: m.Content,
	}

	if t, err := time.Parse(time.RFC3339, m.Timestamp); err == nil {
		msg.Timestamp = timestamppb.New(t)
	} else if m.Timestamp != "" {
		slog.Warn("Failed to parse message timestamp",
			"messageID", m.ID, "timestamp", m.Timestamp, "error", err)
	}

	return msg
}

func convertMessageRole(r protocol.MessageRole) pb.MessageRole {
	switch r {
	case protocol.RoleUser:
		return pb.MessageRole_MESSAGE_ROLE_USER
	case protocol.RoleAssistant:
		return pb.MessageRole_MESSAGE_ROLE_ASSISTANT
	default:
		return pb.MessageRole_MESSAGE_ROLE_UNSPECIFIED
	}
}

func convertPersistedEvent(e *protocol.PersistedEvent) *pb.PersistedEvent {
	if e == nil {
		return nil
	}

	evt := &pb.PersistedEvent{
		Id: e.ID,
		// MessageId intentionally left empty - message-level correlation not yet implemented
	}

	// Convert the embedded event
	evt.Event = convertAgentEvent(&e.Event)

	if t, err := time.Parse(time.RFC3339, e.Timestamp); err == nil {
		evt.Timestamp = timestamppb.New(t)
	} else if e.Timestamp != "" {
		slog.Warn("Failed to parse event timestamp",
			"eventID", e.ID, "timestamp", e.Timestamp, "error", err)
	}

	return evt
}

func convertGitStatus(s string) pb.GitFileStatus {
	switch s {
	case "modified":
		return pb.GitFileStatus_GIT_FILE_STATUS_MODIFIED
	case "added":
		return pb.GitFileStatus_GIT_FILE_STATUS_ADDED
	case "deleted":
		return pb.GitFileStatus_GIT_FILE_STATUS_DELETED
	case "renamed":
		return pb.GitFileStatus_GIT_FILE_STATUS_RENAMED
	case "untracked":
		return pb.GitFileStatus_GIT_FILE_STATUS_UNTRACKED
	case "copied":
		return pb.GitFileStatus_GIT_FILE_STATUS_COPIED
	case "ignored":
		return pb.GitFileStatus_GIT_FILE_STATUS_IGNORED
	case "unmerged":
		return pb.GitFileStatus_GIT_FILE_STATUS_UNMERGED
	default:
		return pb.GitFileStatus_GIT_FILE_STATUS_UNSPECIFIED
	}
}

// convertServerMessage converts a protocol.ServerMessage to pb.ServerMessage.
func convertServerMessage(msg protocol.ServerMessage) *pb.ServerMessage {
	switch msg.Type {
	case protocol.MsgTypeSessionCreated:
		return &pb.ServerMessage{
			Message: &pb.ServerMessage_SessionCreated{
				SessionCreated: &pb.SessionCreatedResponse{Session: convertSession(msg.Session)},
			},
		}
	case protocol.MsgTypeSessionUpdated:
		return &pb.ServerMessage{
			Message: &pb.ServerMessage_SessionUpdated{
				SessionUpdated: &pb.SessionUpdatedResponse{Session: convertSession(msg.Session)},
			},
		}
	case protocol.MsgTypeSessionDeleted:
		return &pb.ServerMessage{
			Message: &pb.ServerMessage_SessionDeleted{
				SessionDeleted: &pb.SessionDeletedResponse{SessionId: msg.ID},
			},
		}
	case protocol.MsgTypeSessionError:
		return makeErrorResponse(msg.ID, "SESSION_ERROR", msg.Error)
	case protocol.MsgTypeAgentMessage:
		partial := false
		if msg.Partial != nil {
			partial = *msg.Partial
		}
		return &pb.ServerMessage{
			Message: &pb.ServerMessage_AgentMessage{
				AgentMessage: &pb.AgentMessageResponse{
					SessionId: msg.SessionID,
					Content:   msg.Content,
					Partial:   partial,
					MessageId: msg.MessageID,
				},
			},
		}
	case protocol.MsgTypeAgentEvent:
		return &pb.ServerMessage{
			Message: &pb.ServerMessage_AgentEvent{
				AgentEvent: &pb.AgentEventResponse{
					SessionId: msg.SessionID,
					Event:     convertAgentEvent(msg.Event),
				},
			},
		}
	case protocol.MsgTypeAgentDone:
		return &pb.ServerMessage{
			Message: &pb.ServerMessage_AgentDone{
				AgentDone: &pb.AgentDoneResponse{SessionId: msg.SessionID},
			},
		}
	case protocol.MsgTypeAgentError:
		return makeErrorResponse(msg.SessionID, "AGENT_ERROR", msg.Error)
	case protocol.MsgTypeUserMessage:
		return &pb.ServerMessage{
			Message: &pb.ServerMessage_UserMessage{
				UserMessage: &pb.UserMessageResponse{SessionId: msg.SessionID, Content: msg.Content},
			},
		}
	case protocol.MsgTypeTerminalOutput:
		return &pb.ServerMessage{
			Message: &pb.ServerMessage_TerminalOutput{
				TerminalOutput: &pb.TerminalOutputResponse{SessionId: msg.SessionID, Data: msg.Data},
			},
		}
	case protocol.MsgTypeError:
		return makeErrorResponse("", "ERROR", msg.Message)
	default:
		return makeErrorResponse("", "UNKNOWN_MESSAGE_TYPE", "Unknown message type: "+msg.Type)
	}
}

func convertAgentEvent(e *protocol.AgentEvent) *pb.AgentEvent {
	if e == nil {
		return nil
	}

	evt := &pb.AgentEvent{
		Kind: convertEventKind(e.Kind),
	}

	if t, err := time.Parse(time.RFC3339, e.Timestamp); err == nil {
		evt.Timestamp = timestamppb.New(t)
	} else if e.Timestamp != "" {
		slog.Warn("Failed to parse agent event timestamp",
			"kind", e.Kind, "timestamp", e.Timestamp, "error", err)
	}

	// Set payload based on event kind
	switch e.Kind {
	case protocol.EventKindToolStart, protocol.EventKindToolInput, protocol.EventKindToolInputComplete, protocol.EventKindToolEnd:
		payload := &pb.ToolEventPayload{
			Tool:      e.Tool,
			ToolUseId: e.ToolUseID,
		}
		if e.ParentToolUseID != "" {
			payload.ParentToolUseId = &e.ParentToolUseID
		}
		if len(e.Input) > 0 {
			if inputStruct, err := structpb.NewStruct(e.Input); err == nil {
				payload.Input = inputStruct
			}
		}
		if e.InputDelta != "" {
			payload.InputDelta = &e.InputDelta
		}
		if e.Result != nil {
			payload.Result = e.Result
		}
		if e.Error != nil {
			payload.Error = e.Error
		}
		evt.Payload = &pb.AgentEvent_Tool{Tool: payload}

	case protocol.EventKindFileChange:
		payload := &pb.FileChangePayload{
			Path:   e.Path,
			Action: convertFileActionToProto(e.Action),
		}
		if e.LinesAdded != nil {
			added := int32(*e.LinesAdded)
			payload.LinesAdded = &added
		}
		if e.LinesRemoved != nil {
			removed := int32(*e.LinesRemoved)
			payload.LinesRemoved = &removed
		}
		evt.Payload = &pb.AgentEvent_FileChange{FileChange: payload}

	case protocol.EventKindCommandStart, protocol.EventKindCommandEnd:
		payload := &pb.CommandPayload{
			Command: e.Command,
		}
		if e.Cwd != nil {
			payload.Cwd = e.Cwd
		}
		if e.ExitCode != nil {
			code := int32(*e.ExitCode)
			payload.ExitCode = &code
		}
		if e.Output != nil {
			payload.Output = e.Output
		}
		evt.Payload = &pb.AgentEvent_Command{Command: payload}

	case protocol.EventKindThinking:
		evt.Payload = &pb.AgentEvent_Thinking{
			Thinking: &pb.ThinkingPayload{
				ThinkingId: e.ThinkingID,
				Content:    e.Content,
				Partial:    e.Partial,
			},
		}

	case protocol.EventKindPortExposed:
		payload := &pb.PortExposedPayload{
			Port: int32(e.Port),
		}
		if e.Process != nil {
			payload.Process = e.Process
		}
		if e.PreviewURL != nil {
			payload.PreviewUrl = e.PreviewURL
		}
		evt.Payload = &pb.AgentEvent_PortExposed{PortExposed: payload}

	case protocol.EventKindRepoClone:
		evt.Payload = &pb.AgentEvent_RepoClone{
			RepoClone: &pb.RepoClonePayload{
				Repo:    e.Repo,
				Stage:   convertRepoCloneStageToProto(e.Stage),
				Message: e.Message,
			},
		}
	}

	return evt
}

// convertFileActionToProto converts protocol FileAction to proto FileAction.
func convertFileActionToProto(action protocol.FileAction) pb.FileAction {
	switch action {
	case protocol.FileActionCreate:
		return pb.FileAction_FILE_ACTION_CREATE
	case protocol.FileActionEdit:
		return pb.FileAction_FILE_ACTION_EDIT
	case protocol.FileActionDelete:
		return pb.FileAction_FILE_ACTION_DELETE
	default:
		return pb.FileAction_FILE_ACTION_UNSPECIFIED
	}
}

// convertRepoCloneStageToProto converts protocol RepoCloneStage to proto RepoCloneStage.
func convertRepoCloneStageToProto(stage protocol.RepoCloneStage) pb.RepoCloneStage {
	switch stage {
	case protocol.RepoCloneStageStarting:
		return pb.RepoCloneStage_REPO_CLONE_STAGE_STARTING
	case protocol.RepoCloneStageCloning:
		return pb.RepoCloneStage_REPO_CLONE_STAGE_CLONING
	case protocol.RepoCloneStageDone:
		return pb.RepoCloneStage_REPO_CLONE_STAGE_DONE
	case protocol.RepoCloneStageError:
		return pb.RepoCloneStage_REPO_CLONE_STAGE_ERROR
	default:
		return pb.RepoCloneStage_REPO_CLONE_STAGE_UNSPECIFIED
	}
}

func convertEventKind(k protocol.AgentEventKind) pb.AgentEventKind {
	switch k {
	case protocol.EventKindToolStart:
		return pb.AgentEventKind_AGENT_EVENT_KIND_TOOL_START
	case protocol.EventKindToolInput:
		return pb.AgentEventKind_AGENT_EVENT_KIND_TOOL_INPUT
	case protocol.EventKindToolInputComplete:
		return pb.AgentEventKind_AGENT_EVENT_KIND_TOOL_INPUT_COMPLETE
	case protocol.EventKindToolEnd:
		return pb.AgentEventKind_AGENT_EVENT_KIND_TOOL_END
	case protocol.EventKindFileChange:
		return pb.AgentEventKind_AGENT_EVENT_KIND_FILE_CHANGE
	case protocol.EventKindCommandStart:
		return pb.AgentEventKind_AGENT_EVENT_KIND_COMMAND_START
	case protocol.EventKindCommandEnd:
		return pb.AgentEventKind_AGENT_EVENT_KIND_COMMAND_END
	case protocol.EventKindThinking:
		return pb.AgentEventKind_AGENT_EVENT_KIND_THINKING
	case protocol.EventKindPortExposed:
		return pb.AgentEventKind_AGENT_EVENT_KIND_PORT_EXPOSED
	case protocol.EventKindRepoClone:
		return pb.AgentEventKind_AGENT_EVENT_KIND_REPO_CLONE
	default:
		return pb.AgentEventKind_AGENT_EVENT_KIND_UNSPECIFIED
	}
}
