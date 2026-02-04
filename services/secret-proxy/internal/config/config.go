// Package config handles configuration loading for the secret proxy.
package config

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/angristan/netclode/services/secret-proxy/internal/proxy"
)

// Config holds the application configuration.
type Config struct {
	// ListenAddr is the address to listen on.
	ListenAddr string

	// CAPath is the path to the CA certificate file.
	CAPath string

	// CAKeyPath is the path to the CA private key file.
	CAKeyPath string

	// SecretsJSON is the JSON-encoded secrets configuration.
	// Format: {"PLACEHOLDER": {"secret": "value", "hosts": ["host1", "host2"]}}
	SecretsJSON string

	// Verbose enables verbose logging.
	Verbose bool
}

// Load loads configuration from environment variables.
func Load() Config {
	return Config{
		ListenAddr:  getEnv("LISTEN_ADDR", ":8080"),
		CAPath:      getEnv("CA_CERT_PATH", "/etc/secret-proxy/ca.crt"),
		CAKeyPath:   getEnv("CA_KEY_PATH", "/etc/secret-proxy/ca.key"),
		SecretsJSON: os.Getenv("SECRETS_JSON"),
		Verbose:     os.Getenv("VERBOSE") == "true",
	}
}

// ParseSecrets parses the JSON secrets configuration into SecretConfig structs.
func ParseSecrets(jsonStr string) ([]proxy.SecretConfig, error) {
	if jsonStr == "" {
		return nil, nil
	}

	// Format: {"PLACEHOLDER": {"secret": "value", "hosts": ["host1", "host2"]}}
	var raw map[string]struct {
		Secret string   `json:"secret"`
		Hosts  []string `json:"hosts"`
	}

	if err := json.Unmarshal([]byte(jsonStr), &raw); err != nil {
		return nil, fmt.Errorf("parse secrets JSON: %w", err)
	}

	secrets := make([]proxy.SecretConfig, 0, len(raw))
	for placeholder, cfg := range raw {
		secrets = append(secrets, proxy.SecretConfig{
			Placeholder:  placeholder,
			Secret:       cfg.Secret,
			AllowedHosts: cfg.Hosts,
		})
	}

	return secrets, nil
}

func getEnv(key, defaultValue string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultValue
}
