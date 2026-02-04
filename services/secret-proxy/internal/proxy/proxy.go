// Package proxy implements a MITM proxy that injects secrets into HTTP headers.
//
// Secrets are passed to the sandbox as placeholder environment variables.
// When the sandbox makes an outbound HTTP request, this proxy intercepts it,
// checks if the destination host is in the allowlist for a secret, and if so,
// replaces the placeholder in request headers with the real secret value.
//
// This prevents secret exfiltration because:
// 1. The real secret never enters the sandbox environment
// 2. Placeholders are only replaced for allowed hosts
// 3. Replacement only happens in headers, not request bodies (prevents reflection attacks)
package proxy

import (
	"crypto/tls"
	"log/slog"
	"net/http"
	"strings"

	"github.com/elazarl/goproxy"
)

// SecretConfig defines a secret and its allowed destinations.
type SecretConfig struct {
	// Placeholder is the value that appears in the sandbox environment.
	// e.g., "NETCLODE_PLACEHOLDER_abc123"
	Placeholder string

	// Secret is the real secret value to inject.
	Secret string

	// AllowedHosts is the list of hosts where this secret can be used.
	// Supports exact matches and wildcard prefixes (e.g., "*.github.com").
	AllowedHosts []string
}

// Config holds the proxy configuration.
type Config struct {
	// ListenAddr is the address to listen on (e.g., ":8080").
	ListenAddr string

	// Secrets is the list of secrets to inject.
	Secrets []SecretConfig

	// CA is the TLS certificate used for MITM.
	CA tls.Certificate

	// Verbose enables verbose logging.
	Verbose bool
}

// Proxy is a MITM proxy that injects secrets into HTTP headers.
type Proxy struct {
	config Config
	server *goproxy.ProxyHttpServer
	logger *slog.Logger
}

// New creates a new secret injection proxy.
func New(cfg Config, logger *slog.Logger) *Proxy {
	proxy := goproxy.NewProxyHttpServer()
	proxy.Verbose = cfg.Verbose

	// Set up custom CA for MITM
	goproxy.GoproxyCa = cfg.CA
	goproxy.OkConnect = &goproxy.ConnectAction{Action: goproxy.ConnectMitm, TLSConfig: goproxy.TLSConfigFromCA(&cfg.CA)}
	goproxy.MitmConnect = &goproxy.ConnectAction{Action: goproxy.ConnectMitm, TLSConfig: goproxy.TLSConfigFromCA(&cfg.CA)}
	goproxy.RejectConnect = &goproxy.ConnectAction{Action: goproxy.ConnectReject, TLSConfig: goproxy.TLSConfigFromCA(&cfg.CA)}

	p := &Proxy{
		config: cfg,
		server: proxy,
		logger: logger,
	}

	// Enable MITM for all HTTPS connections
	proxy.OnRequest().HandleConnect(goproxy.AlwaysMitm)

	// Add request handler for secret injection
	proxy.OnRequest().DoFunc(p.handleRequest)

	return p
}

// handleRequest processes each request and injects secrets where appropriate.
func (p *Proxy) handleRequest(req *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
	host := req.Host
	if host == "" {
		host = req.URL.Host
	}

	// Strip port from host for matching
	hostWithoutPort := host
	if colonIdx := strings.LastIndex(host, ":"); colonIdx != -1 {
		hostWithoutPort = host[:colonIdx]
	}

	for _, secret := range p.config.Secrets {
		if !p.hostAllowed(hostWithoutPort, secret.AllowedHosts) {
			continue
		}

		// Replace placeholder in headers ONLY (not in body - prevents reflection attacks)
		for name, values := range req.Header {
			for i, value := range values {
				if strings.Contains(value, secret.Placeholder) {
					req.Header[name][i] = strings.Replace(value, secret.Placeholder, secret.Secret, -1)
					p.logger.Info("Injected secret into header",
						"host", hostWithoutPort,
						"header", name,
						"placeholder", secret.Placeholder[:min(20, len(secret.Placeholder))]+"...",
					)
				}
			}
		}
	}

	return req, nil
}

// hostAllowed checks if a host matches any pattern in the allowlist.
func (p *Proxy) hostAllowed(host string, allowedHosts []string) bool {
	host = strings.ToLower(host)
	for _, pattern := range allowedHosts {
		pattern = strings.ToLower(pattern)
		if pattern == host {
			return true
		}
		// Wildcard matching: *.example.com matches foo.example.com
		if strings.HasPrefix(pattern, "*.") {
			suffix := pattern[1:] // ".example.com"
			if strings.HasSuffix(host, suffix) {
				return true
			}
		}
	}
	return false
}

// ListenAndServe starts the proxy server.
func (p *Proxy) ListenAndServe() error {
	p.logger.Info("Starting secret proxy", "addr", p.config.ListenAddr)
	return http.ListenAndServe(p.config.ListenAddr, p.server)
}
