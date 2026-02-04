package proxy

import (
	"testing"
)

func TestHostAllowed(t *testing.T) {
	p := &Proxy{}

	tests := []struct {
		name         string
		host         string
		allowedHosts []string
		want         bool
	}{
		{
			name:         "exact match",
			host:         "api.anthropic.com",
			allowedHosts: []string{"api.anthropic.com"},
			want:         true,
		},
		{
			name:         "exact match case insensitive",
			host:         "API.Anthropic.COM",
			allowedHosts: []string{"api.anthropic.com"},
			want:         true,
		},
		{
			name:         "no match",
			host:         "evil.com",
			allowedHosts: []string{"api.anthropic.com"},
			want:         false,
		},
		{
			name:         "wildcard match",
			host:         "api.github.com",
			allowedHosts: []string{"*.github.com"},
			want:         true,
		},
		{
			name:         "wildcard match subdomain",
			host:         "raw.githubusercontent.com",
			allowedHosts: []string{"*.githubusercontent.com"},
			want:         true,
		},
		{
			name:         "wildcard no match root domain",
			host:         "github.com",
			allowedHosts: []string{"*.github.com"},
			want:         false,
		},
		{
			name:         "multiple hosts first match",
			host:         "api.openai.com",
			allowedHosts: []string{"api.openai.com", "api.anthropic.com"},
			want:         true,
		},
		{
			name:         "multiple hosts second match",
			host:         "api.anthropic.com",
			allowedHosts: []string{"api.openai.com", "api.anthropic.com"},
			want:         true,
		},
		{
			name:         "empty allowlist",
			host:         "api.anthropic.com",
			allowedHosts: []string{},
			want:         false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := p.hostAllowed(tt.host, tt.allowedHosts)
			if got != tt.want {
				t.Errorf("hostAllowed(%q, %v) = %v, want %v", tt.host, tt.allowedHosts, got, tt.want)
			}
		})
	}
}
