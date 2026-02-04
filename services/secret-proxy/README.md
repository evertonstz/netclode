# Secret Proxy

A MITM proxy that transparently injects secrets into HTTP request headers, preventing secret exfiltration from sandboxes.

## How It Works

1. **Sandbox Environment**: Secrets are passed to the sandbox as placeholder values:
   ```
   ANTHROPIC_API_KEY=NETCLODE_PLACEHOLDER_abc123
   ```

2. **Transparent Interception**: All HTTP/HTTPS traffic is redirected to the proxy via iptables.

3. **Secret Injection**: When the proxy sees a request:
   - It checks if the destination host is in the secret's allowlist
   - If allowed, it replaces the placeholder with the real secret **in headers only**
   - The request is forwarded to the destination

4. **Security**: 
   - Real secrets never enter the sandbox environment
   - Placeholders are useless if exfiltrated (wrong host = no replacement)
   - Body replacement is blocked (prevents reflection attacks via APIs that echo input)

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LISTEN_ADDR` | `:8080` | Address to listen on |
| `CA_CERT_PATH` | `/etc/secret-proxy/ca.crt` | Path to CA certificate |
| `CA_KEY_PATH` | `/etc/secret-proxy/ca.key` | Path to CA private key |
| `SECRETS_JSON` | - | JSON-encoded secrets (see below) |
| `VERBOSE` | `false` | Enable verbose logging |

### Secrets JSON Format

```json
{
  "NETCLODE_PLACEHOLDER_abc123": {
    "secret": "sk-ant-actual-api-key",
    "hosts": ["api.anthropic.com"]
  },
  "NETCLODE_PLACEHOLDER_def456": {
    "secret": "ghp_actual-github-token",
    "hosts": ["api.github.com", "*.githubusercontent.com"]
  }
}
```

### Host Patterns

- Exact match: `api.anthropic.com`
- Wildcard subdomain: `*.github.com` (matches `api.github.com`, `raw.github.com`, etc.)

## Usage

### Running Locally

```bash
# Generate CA certificate
mkdir -p /tmp/secret-proxy
cd services/secret-proxy
go run ./cmd/secret-proxy

# The CA will be auto-generated on first run
```

### Running in Kubernetes (Netclode)

The sandbox template (`infra/k8s/sandbox-template.yaml`) handles everything:

1. **Init container** sets up iptables redirect to the proxy
2. **Sidecar container** runs the secret-proxy
3. **Agent entrypoint** trusts the proxy CA certificate

See the sandbox template for the full configuration.

### Docker

```bash
docker build -t secret-proxy .
docker run -e SECRETS_JSON='...' secret-proxy
```

## Security Considerations

- **Header-only replacement**: Secrets are never injected into request bodies, preventing reflection attacks where an API echoes back input.
- **Host allowlists**: Each secret can only be used with specific hosts.
- **Wildcard limitations**: `*.example.com` matches subdomains but not `example.com` itself.
- **CA trust**: The sandbox must trust the proxy's CA certificate for HTTPS interception.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Sandbox                                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Agent Process                                       │   │
│  │ ENV: ANTHROPIC_API_KEY=NETCLODE_PLACEHOLDER_abc123  │   │
│  │                                                     │   │
│  │ curl -H "Authorization: Bearer $ANTHROPIC_API_KEY"  │   │
│  │      https://api.anthropic.com/v1/messages          │   │
│  └──────────────────────┬──────────────────────────────┘   │
│                         │                                   │
│              iptables redirect (port 443 → 8080)           │
│                         │                                   │
│  ┌──────────────────────▼──────────────────────────────┐   │
│  │ Secret Proxy (:8080)                                │   │
│  │                                                     │   │
│  │ 1. Terminate TLS (MITM with trusted CA)            │   │
│  │ 2. Check: api.anthropic.com in allowlist? ✓        │   │
│  │ 3. Replace PLACEHOLDER_abc123 → real key (headers) │   │
│  │ 4. Forward request via new TLS connection          │   │
│  └──────────────────────┬──────────────────────────────┘   │
└─────────────────────────┼───────────────────────────────────┘
                          │
                          ▼
              https://api.anthropic.com
              (with real API key in header)
```
