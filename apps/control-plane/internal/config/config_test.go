package config

import (
	"os"
	"testing"
)

func TestGetEnvBool(t *testing.T) {
	tests := []struct {
		name         string
		envValue     string
		defaultValue bool
		expected     bool
	}{
		{
			name:         "true string",
			envValue:     "true",
			defaultValue: false,
			expected:     true,
		},
		{
			name:         "1 string",
			envValue:     "1",
			defaultValue: false,
			expected:     true,
		},
		{
			name:         "false string",
			envValue:     "false",
			defaultValue: true,
			expected:     false,
		},
		{
			name:         "0 string",
			envValue:     "0",
			defaultValue: true,
			expected:     false,
		},
		{
			name:         "empty uses default true",
			envValue:     "",
			defaultValue: true,
			expected:     true,
		},
		{
			name:         "empty uses default false",
			envValue:     "",
			defaultValue: false,
			expected:     false,
		},
		{
			name:         "invalid uses false",
			envValue:     "invalid",
			defaultValue: true,
			expected:     false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			key := "TEST_BOOL_VAR"
			if tt.envValue != "" {
				os.Setenv(key, tt.envValue)
				defer os.Unsetenv(key)
			} else {
				os.Unsetenv(key)
			}

			result := getEnvBool(key, tt.defaultValue)
			if result != tt.expected {
				t.Errorf("getEnvBool(%q, %v) = %v, want %v", tt.envValue, tt.defaultValue, result, tt.expected)
			}
		})
	}
}

func TestLoadWithWarmPoolEnabled(t *testing.T) {
	// Test default (disabled)
	os.Unsetenv("WARM_POOL_ENABLED")
	cfg := Load()
	if cfg.UseWarmPool {
		t.Error("UseWarmPool should be false by default")
	}

	// Test enabled
	os.Setenv("WARM_POOL_ENABLED", "true")
	defer os.Unsetenv("WARM_POOL_ENABLED")

	cfg = Load()
	if !cfg.UseWarmPool {
		t.Error("UseWarmPool should be true when WARM_POOL_ENABLED=true")
	}
}

func TestLoadWithSandboxTemplate(t *testing.T) {
	// Test default
	os.Unsetenv("SANDBOX_TEMPLATE")
	cfg := Load()
	if cfg.SandboxTemplate != "netclode-agent" {
		t.Errorf("SandboxTemplate = %q, want %q", cfg.SandboxTemplate, "netclode-agent")
	}

	// Test custom value
	os.Setenv("SANDBOX_TEMPLATE", "custom-template")
	defer os.Unsetenv("SANDBOX_TEMPLATE")

	cfg = Load()
	if cfg.SandboxTemplate != "custom-template" {
		t.Errorf("SandboxTemplate = %q, want %q", cfg.SandboxTemplate, "custom-template")
	}
}
