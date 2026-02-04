// genca generates a CA certificate and key for the secret-proxy.
//
// Usage:
//
//	go run ./cmd/genca -out /tmp/ca
//
// This will create:
//   - /tmp/ca/ca.crt - CA certificate (PEM)
//   - /tmp/ca/ca.key - CA private key (PEM)
//
// To create the Kubernetes ConfigMap:
//
//	kubectl create configmap secret-proxy-ca \
//	  --from-file=ca.crt=/tmp/ca/ca.crt \
//	  --from-file=ca.key=/tmp/ca/ca.key \
//	  -n netclode
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/angristan/netclode/services/secret-proxy/internal/certs"
)

func main() {
	outDir := flag.String("out", ".", "Output directory for CA files")
	flag.Parse()

	// Create output directory if it doesn't exist
	if err := os.MkdirAll(*outDir, 0755); err != nil {
		fmt.Fprintf(os.Stderr, "Error creating output directory: %v\n", err)
		os.Exit(1)
	}

	certPath := filepath.Join(*outDir, "ca.crt")
	keyPath := filepath.Join(*outDir, "ca.key")

	fmt.Printf("Generating CA certificate...\n")
	if err := certs.GenerateAndSaveCA(certPath, keyPath); err != nil {
		fmt.Fprintf(os.Stderr, "Error generating CA: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("CA certificate generated:\n")
	fmt.Printf("  Certificate: %s\n", certPath)
	fmt.Printf("  Private key: %s\n", keyPath)
	fmt.Printf("\nTo create the Kubernetes ConfigMap:\n")
	fmt.Printf("  kubectl create configmap secret-proxy-ca \\\n")
	fmt.Printf("    --from-file=ca.crt=%s \\\n", certPath)
	fmt.Printf("    --from-file=ca.key=%s \\\n", keyPath)
	fmt.Printf("    -n netclode\n")
}
