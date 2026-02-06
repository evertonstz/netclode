package cmd

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"

	"connectrpc.com/connect"
	"github.com/angristan/netclode/clients/cli/internal/client"
	pb "github.com/angristan/netclode/services/control-plane/gen/netclode/v1"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

// ptyExitMarker is the OSC escape sequence the agent sends when the PTY exits.
// We detect this in terminal output to auto-detach.
const ptyExitMarker = "\x1b]9999;pty-exit;"

var (
	shellName    string
	shellRepos   []string
	shellTailnet bool
)

var shellCmd = &cobra.Command{
	Use:   "shell [session-id]",
	Short: "Attach an interactive shell to a sandbox",
	Long: `Opens an interactive terminal session attached to a sandbox's PTY.

With no arguments, creates a new session and attaches immediately.
With a session ID, attaches to an existing session.

This gives you direct shell access to the sandbox environment, similar to SSH.
All keyboard input is forwarded to the sandbox, and terminal output is displayed
locally. The terminal is put into raw mode for full interactivity.

Press Ctrl+] to detach.`,
	Args: cobra.MaximumNArgs(1),
	RunE: runShell,
}

func init() {
	shellCmd.Flags().StringVar(&shellName, "name", "", "Session name (for new sessions)")
	shellCmd.Flags().StringArrayVar(&shellRepos, "repo", nil, "GitHub repository to clone (for new sessions, repeatable)")
	shellCmd.Flags().BoolVar(&shellTailnet, "tailnet", false, "Enable Tailnet access (for new sessions)")
	rootCmd.AddCommand(shellCmd)
}

func runShell(cmd *cobra.Command, args []string) error {
	// Ensure stdin is a terminal
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return fmt.Errorf("stdin is not a terminal")
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Handle SIGTERM gracefully
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM)
	go func() {
		<-sigCh
		cancel()
	}()

	c := client.New(getServerURL())
	stream := c.Stream(ctx)

	var sessionID string

	if len(args) == 1 {
		// Attach to existing session
		sessionID = args[0]

		// Open session to subscribe to stream entries
		if err := stream.Send(&pb.ClientMessage{
			Message: &pb.ClientMessage_OpenSession{
				OpenSession: &pb.OpenSessionRequest{
					SessionId: sessionID,
				},
			},
		}); err != nil {
			_ = stream.CloseRequest()
			return fmt.Errorf("open session: %w", err)
		}

		// Wait for session state response (may need to skip forwarded stream entries)
		sessionState, err := receiveSessionState(stream)
		if err != nil {
			_ = stream.CloseRequest()
			return err
		}

		status := sessionState.Session.Status
		if status == pb.SessionStatus_SESSION_STATUS_PAUSED {
			_ = stream.CloseRequest()
			return fmt.Errorf("session is paused, resume it first: netclode sessions resume %s", sessionID)
		}
		if status == pb.SessionStatus_SESSION_STATUS_ERROR {
			_ = stream.CloseRequest()
			return fmt.Errorf("session is in error state")
		}
	} else {
		// Create a new session and wait for it to be ready.
		// CreateSession already subscribes us to the session stream,
		// so we skip OpenSession and go straight to the attach loop.
		var err error
		sessionID, err = shellCreateAndWait(ctx, stream)
		if err != nil {
			_ = stream.CloseRequest()
			return err
		}
	}

	return shellAttach(ctx, cancel, stream, sessionID)
}

// receiveSessionState reads from the stream until it gets a SessionStateResponse,
// skipping any StreamEntryResponse messages that may arrive first.
func receiveSessionState(stream *connect.BidiStreamForClient[pb.ClientMessage, pb.ServerMessage]) (*pb.SessionStateResponse, error) {
	for {
		msg, err := stream.Receive()
		if err != nil {
			return nil, fmt.Errorf("receive session state: %w", err)
		}
		if errResp := msg.GetError(); errResp != nil {
			return nil, fmt.Errorf("%s: %s", errResp.Error.Code, errResp.Error.Message)
		}
		if sessionState := msg.GetSessionState(); sessionState != nil {
			return sessionState, nil
		}
		// Skip other message types (e.g. StreamEntryResponse from prior subscription)
	}
}

// shellCreateAndWait creates a new session over the stream and waits for it to become ready.
// After this returns, the stream is already subscribed to the session (done by the server
// during CreateSession), so there's no need to send OpenSession.
func shellCreateAndWait(ctx context.Context, stream *connect.BidiStreamForClient[pb.ClientMessage, pb.ServerMessage]) (string, error) {
	req := &pb.CreateSessionRequest{
		SdkType: pb.SdkType_SDK_TYPE_CLAUDE.Enum(),
	}
	if shellName != "" {
		req.Name = &shellName
	}
	if len(shellRepos) > 0 {
		req.Repos = shellRepos
	}
	if shellTailnet {
		req.NetworkConfig = &pb.NetworkConfig{
			TailnetAccess: true,
		}
	}

	if err := stream.Send(&pb.ClientMessage{
		Message: &pb.ClientMessage_CreateSession{
			CreateSession: req,
		},
	}); err != nil {
		return "", fmt.Errorf("create session: %w", err)
	}

	fmt.Fprintf(os.Stderr, "Creating sandbox...")

	var sessionID string

	for {
		msg, err := stream.Receive()
		if err != nil {
			return "", fmt.Errorf("waiting for session: %w", err)
		}

		if errResp := msg.GetError(); errResp != nil {
			fmt.Fprintln(os.Stderr)
			return "", fmt.Errorf("%s: %s", errResp.Error.Code, errResp.Error.Message)
		}

		if resp := msg.GetSessionCreated(); resp != nil {
			sessionID = resp.Session.Id
			status := resp.Session.Status
			if status == pb.SessionStatus_SESSION_STATUS_READY {
				fmt.Fprintf(os.Stderr, " ready (%s)\n", sessionID)
				return sessionID, nil
			}
			fmt.Fprintf(os.Stderr, " %s", strings.TrimPrefix(strings.ToLower(status.String()), "session_status_"))
		}

		// Top-level SessionUpdated — only process if it's for OUR session.
		// (Auto-pause of other sessions also sends SessionUpdated via broadcast.)
		if resp := msg.GetSessionUpdated(); resp != nil && sessionID != "" && resp.Session.Id == sessionID {
			status := resp.Session.Status
			fmt.Fprintf(os.Stderr, " %s", strings.TrimPrefix(strings.ToLower(status.String()), "session_status_"))
			if status == pb.SessionStatus_SESSION_STATUS_READY {
				fmt.Fprintf(os.Stderr, " (%s)\n", sessionID)
				return sessionID, nil
			}
			if status == pb.SessionStatus_SESSION_STATUS_ERROR {
				fmt.Fprintln(os.Stderr)
				return "", fmt.Errorf("session failed to start")
			}
		}

		// Session status READY also arrives as a StreamEntry (via Redis subscriber).
		// This is the primary path for warm pool sessions.
		if entry := msg.GetStreamEntry(); entry != nil && entry.Entry != nil {
			if sessUpdate := entry.Entry.GetSessionUpdate(); sessUpdate != nil && sessionID != "" && sessUpdate.Id == sessionID {
				status := sessUpdate.Status
				fmt.Fprintf(os.Stderr, " %s", strings.TrimPrefix(strings.ToLower(status.String()), "session_status_"))
				if status == pb.SessionStatus_SESSION_STATUS_READY {
					fmt.Fprintf(os.Stderr, " (%s)\n", sessionID)
					return sessionID, nil
				}
				if status == pb.SessionStatus_SESSION_STATUS_ERROR {
					fmt.Fprintln(os.Stderr)
					return "", fmt.Errorf("session failed to start")
				}
			}
		}

		select {
		case <-ctx.Done():
			return "", ctx.Err()
		default:
		}
	}
}

// shellAttach puts the terminal in raw mode and starts the bidirectional forwarding.
func shellAttach(ctx context.Context, cancel context.CancelFunc, stream *connect.BidiStreamForClient[pb.ClientMessage, pb.ServerMessage], sessionID string) error {
	fd := int(os.Stdin.Fd())
	oldState, err := term.MakeRaw(fd)
	if err != nil {
		_ = stream.CloseRequest()
		return fmt.Errorf("set raw mode: %w", err)
	}
	defer func() {
		_ = term.Restore(fd, oldState)
		fmt.Println()
	}()

	// Send initial terminal size
	cols, rows, err := term.GetSize(fd)
	if err == nil && cols > 0 && rows > 0 {
		_ = stream.Send(&pb.ClientMessage{
			Message: &pb.ClientMessage_TerminalResize{
				TerminalResize: &pb.TerminalResizeRequest{
					SessionId: sessionID,
					Cols:      int32(cols),
					Rows:      int32(rows),
				},
			},
		})
	}

	// Send an initial newline to trigger PTY output (prompt)
	_ = stream.Send(&pb.ClientMessage{
		Message: &pb.ClientMessage_TerminalInput{
			TerminalInput: &pb.TerminalInputRequest{
				SessionId: sessionID,
				Data:      "\n",
			},
		},
	})

	// Watch for terminal resize (SIGWINCH)
	winchCh := make(chan os.Signal, 1)
	signal.Notify(winchCh, syscall.SIGWINCH)
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case <-winchCh:
				c, r, err := term.GetSize(fd)
				if err != nil || c <= 0 || r <= 0 {
					continue
				}
				_ = stream.Send(&pb.ClientMessage{
					Message: &pb.ClientMessage_TerminalResize{
						TerminalResize: &pb.TerminalResizeRequest{
							SessionId: sessionID,
							Cols:      int32(c),
							Rows:      int32(r),
						},
					},
				})
			}
		}
	}()

	var wg sync.WaitGroup
	errCh := make(chan error, 2)

	// Goroutine: read from stream, write terminal output to stdout
	wg.Add(1)
	go func() {
		defer wg.Done()
		if err := shellReceiveLoop(ctx, cancel, stream); err != nil {
			errCh <- err
		}
	}()

	// Goroutine: read from stdin, send as terminal input
	wg.Add(1)
	go func() {
		defer wg.Done()
		if err := shellInputLoop(ctx, cancel, stream, sessionID); err != nil {
			errCh <- err
		}
	}()

	wg.Wait()
	_ = stream.CloseRequest()

	select {
	case err := <-errCh:
		if ctx.Err() != nil {
			return nil
		}
		return err
	default:
		return nil
	}
}

// shellReceiveLoop reads messages from the stream and writes terminal output to stdout.
// When the remote PTY exits (detected via OSC 9999 escape sequence), it cancels the context.
func shellReceiveLoop(ctx context.Context, cancel context.CancelFunc, stream *connect.BidiStreamForClient[pb.ClientMessage, pb.ServerMessage]) error {
	for {
		select {
		case <-ctx.Done():
			return nil
		default:
		}

		msg, err := stream.Receive()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return fmt.Errorf("receive: %w", err)
		}

		if entry := msg.GetStreamEntry(); entry != nil && entry.Entry != nil {
			if termOut := entry.Entry.GetTerminalOutput(); termOut != nil {
				data := termOut.Data
				// Check for PTY exit marker (OSC 9999 escape sequence).
				// Strip it from output and trigger detach.
				if idx := strings.Index(data, ptyExitMarker); idx != -1 {
					// Write any output before the marker
					if idx > 0 {
						_, _ = os.Stdout.WriteString(data[:idx])
					}
					cancel()
					return nil
				}
				_, _ = os.Stdout.WriteString(data)
			}
		}

		if errResp := msg.GetError(); errResp != nil {
			return fmt.Errorf("server error: %s: %s", errResp.Error.Code, errResp.Error.Message)
		}
	}
}

// shellInputLoop reads from stdin and sends terminal input to the stream.
// Ctrl+] (0x1d, GS) is the escape character to detach.
func shellInputLoop(ctx context.Context, cancel context.CancelFunc, stream *connect.BidiStreamForClient[pb.ClientMessage, pb.ServerMessage], sessionID string) error {
	buf := make([]byte, 4096)
	for {
		select {
		case <-ctx.Done():
			return nil
		default:
		}

		n, err := os.Stdin.Read(buf)
		if err != nil {
			if err == io.EOF || ctx.Err() != nil {
				cancel()
				return nil
			}
			return fmt.Errorf("read stdin: %w", err)
		}

		if n == 0 {
			continue
		}

		// Check for escape character: Ctrl+] (0x1d)
		for i := 0; i < n; i++ {
			if buf[i] == 0x1d {
				cancel()
				return nil
			}
		}

		if err := stream.Send(&pb.ClientMessage{
			Message: &pb.ClientMessage_TerminalInput{
				TerminalInput: &pb.TerminalInputRequest{
					SessionId: sessionID,
					Data:      string(buf[:n]),
				},
			},
		}); err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return fmt.Errorf("send input: %w", err)
		}
	}
}
