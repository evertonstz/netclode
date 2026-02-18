package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

// fakeUpstreamProxy simulates the secret-proxy side of a CONNECT tunnel.
// It accepts a TCP connection, reads the CONNECT request, sends the response
// (via responseFn), then echoes data back through the tunnel.
func fakeUpstreamProxy(t *testing.T, responseFn func(conn net.Conn, host string)) net.Listener {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return // listener closed
			}
			go func(c net.Conn) {
				defer c.Close()
				br := bufio.NewReader(c)
				req, err := http.ReadRequest(br)
				if err != nil {
					return
				}
				responseFn(c, req.Host)
				// After tunnel is established, echo everything back
				io.Copy(c, br)
			}(conn)
		}
	}()
	return ln
}

// sendCONNECT sends a CONNECT request through the auth-proxy and returns the
// raw hijacked connection after the tunnel is established.
func sendCONNECT(t *testing.T, proxyAddr, targetHost string) net.Conn {
	t.Helper()
	conn, err := net.DialTimeout("tcp", proxyAddr, 2*time.Second)
	if err != nil {
		t.Fatalf("dial auth-proxy: %v", err)
	}
	req := fmt.Sprintf("CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", targetHost, targetHost)
	if _, err := conn.Write([]byte(req)); err != nil {
		conn.Close()
		t.Fatalf("write CONNECT: %v", err)
	}
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodConnect})
	if err != nil {
		conn.Close()
		t.Fatalf("read CONNECT response: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		conn.Close()
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	// If the reader buffered extra bytes, we need a conn that serves them first.
	if br.Buffered() > 0 {
		return &bufferedConn{Conn: conn, br: br}
	}
	return conn
}

// bufferedConn wraps a net.Conn with a bufio.Reader for leftover buffered data.
type bufferedConn struct {
	net.Conn
	br *bufio.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) {
	return c.br.Read(p)
}

func startAuthProxy(t *testing.T, upstreamAddr string) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })

	handler := &proxyHandler{
		upstream: "http://" + upstreamAddr,
		dialer: &net.Dialer{
			Timeout:   5 * time.Second,
			KeepAlive: 5 * time.Second,
		},
	}
	srv := &http.Server{Handler: handler}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })

	return ln.Addr().String()
}

func TestHandleConnect_CleanResponse(t *testing.T) {
	// Upstream sends a clean CONNECT 200 response with no extra bytes.
	upstream := fakeUpstreamProxy(t, func(conn net.Conn, host string) {
		conn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))
	})
	defer upstream.Close()

	proxyAddr := startAuthProxy(t, upstream.Addr().String())
	conn := sendCONNECT(t, proxyAddr, "example.com:443")
	defer conn.Close()

	// Send data through the tunnel; the fake upstream echoes it back.
	msg := "hello through tunnel"
	conn.Write([]byte(msg))
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, len(msg))
	n, err := io.ReadFull(conn, buf)
	if err != nil {
		t.Fatalf("read echo: %v", err)
	}
	if string(buf[:n]) != msg {
		t.Fatalf("expected %q, got %q", msg, string(buf[:n]))
	}
}

func TestHandleConnect_OverRead(t *testing.T) {
	// Upstream sends the CONNECT response AND the start of tunnel data
	// in a single write (simulating TCP coalescing / Nagle).
	// The auth-proxy must not drop the extra bytes.
	tunnelPrefix := "TLS-SERVER-HELLO-BYTES"
	upstream := fakeUpstreamProxy(t, func(conn net.Conn, host string) {
		// Single write: response + immediate tunnel data
		conn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n" + tunnelPrefix))
	})
	defer upstream.Close()

	proxyAddr := startAuthProxy(t, upstream.Addr().String())
	conn := sendCONNECT(t, proxyAddr, "example.com:443")
	defer conn.Close()

	// We should receive the tunnel prefix that was coalesced with the response.
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, len(tunnelPrefix)+64)
	n, err := io.ReadAtLeast(conn, buf, len(tunnelPrefix))
	if err != nil {
		t.Fatalf("read tunnel prefix: %v", err)
	}
	got := string(buf[:n])
	if !strings.HasPrefix(got, tunnelPrefix) {
		t.Fatalf("expected tunnel data to start with %q, got %q", tunnelPrefix, got)
	}
}

func TestHandleConnect_UpstreamReject(t *testing.T) {
	// Upstream rejects the CONNECT with 403.
	upstream := fakeUpstreamProxy(t, func(conn net.Conn, host string) {
		conn.Write([]byte("HTTP/1.1 403 Forbidden\r\n\r\n"))
	})
	defer upstream.Close()

	proxyAddr := startAuthProxy(t, upstream.Addr().String())

	conn, err := net.DialTimeout("tcp", proxyAddr, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	req := "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n"
	conn.Write([]byte(req))

	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodConnect})
	if err != nil {
		t.Fatalf("read response: %v", err)
	}
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("expected 502, got %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), "upstream proxy rejected CONNECT") {
		t.Fatalf("expected rejection message, got %q", string(body))
	}
}

func TestHandleConnect_ProxyAuthHeader(t *testing.T) {
	// Verify that the Proxy-Authorization header is forwarded to upstream.
	var gotAuth string
	upstream := fakeUpstreamProxy(t, func(conn net.Conn, host string) {
		// Re-read the raw request to check headers.
		// The request was already consumed by fakeUpstreamProxy, so we
		// need a different approach: capture it in the handler.
		conn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))
	})
	defer upstream.Close()

	// Override: use a custom upstream that captures the auth header.
	upstream.Close()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				br := bufio.NewReader(c)
				req, err := http.ReadRequest(br)
				if err != nil {
					return
				}
				gotAuth = req.Header.Get("Proxy-Authorization")
				c.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))
				io.Copy(c, br)
			}(conn)
		}
	}()

	// Set a test token
	tokenMu.Lock()
	oldToken := tokenCache
	tokenCache = "test-sa-token-123"
	tokenMu.Unlock()
	defer func() {
		tokenMu.Lock()
		tokenCache = oldToken
		tokenMu.Unlock()
	}()

	proxyAddr := startAuthProxy(t, ln.Addr().String())
	conn := sendCONNECT(t, proxyAddr, "api.anthropic.com:443")
	defer conn.Close()

	// Give the upstream a moment to process
	time.Sleep(50 * time.Millisecond)

	expected := "Bearer test-sa-token-123"
	if gotAuth != expected {
		t.Fatalf("expected Proxy-Authorization %q, got %q", expected, gotAuth)
	}
}

func TestHandleConnect_UpstreamUnreachable(t *testing.T) {
	// Upstream is not listening at all.
	proxyAddr := startAuthProxy(t, "127.0.0.1:1") // port 1 = nobody listening

	conn, err := net.DialTimeout("tcp", proxyAddr, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	req := "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n"
	conn.Write([]byte(req))

	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodConnect})
	if err != nil {
		t.Fatalf("read response: %v", err)
	}
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("expected 502, got %d", resp.StatusCode)
	}
}

func TestHandleConnect_ResponseWithExtraHeaders(t *testing.T) {
	// Upstream sends extra headers in the CONNECT response (some proxies do this).
	// The parser must handle them without corrupting the tunnel.
	upstream := fakeUpstreamProxy(t, func(conn net.Conn, host string) {
		conn.Write([]byte("HTTP/1.1 200 Connection Established\r\nX-Proxy-Info: secret-proxy\r\nDate: Tue, 18 Feb 2026 00:00:00 GMT\r\n\r\n"))
	})
	defer upstream.Close()

	proxyAddr := startAuthProxy(t, upstream.Addr().String())
	conn := sendCONNECT(t, proxyAddr, "example.com:443")
	defer conn.Close()

	msg := "data after headers"
	conn.Write([]byte(msg))
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, len(msg))
	n, err := io.ReadFull(conn, buf)
	if err != nil {
		t.Fatalf("read echo: %v", err)
	}
	if string(buf[:n]) != msg {
		t.Fatalf("expected %q, got %q", msg, string(buf[:n]))
	}
}
