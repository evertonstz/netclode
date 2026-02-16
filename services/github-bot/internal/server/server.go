package server

import (
	"net/http"

	"github.com/angristan/netclode/services/github-bot/internal/webhook"
)

// New creates a new HTTP server mux with the webhook and health endpoints.
func New(handler *webhook.Handler) *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	mux.Handle("POST /webhook", handler)

	return mux
}
