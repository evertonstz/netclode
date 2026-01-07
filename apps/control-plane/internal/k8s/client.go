package k8s

import (
	"context"
	"time"

	"github.com/angristan/netclode/apps/control-plane/internal/config"
)

// Runtime defines the interface for Kubernetes operations.
type Runtime interface {
	CreateSandbox(ctx context.Context, sessionID string, env map[string]string) error
	WaitForReady(ctx context.Context, sessionID string, timeout time.Duration) (serviceFQDN string, err error)
	WatchSandboxReady(sessionID string, callback SandboxReadyCallback)
	GetStatus(ctx context.Context, sessionID string) (*SandboxStatusInfo, error)
	DeleteSandbox(ctx context.Context, sessionID string) error
	DeletePVC(ctx context.Context, sessionID string) error
	DeleteSecret(ctx context.Context, sessionID string) error
	ListSandboxes(ctx context.Context) ([]SandboxInfo, error)
	Close()
}

// NewRuntime creates a new Kubernetes runtime with informer-based watching.
func NewRuntime(cfg *config.Config) (Runtime, error) {
	return newK8sRuntime(cfg)
}
