# Network Access Control

Netclode provides network access control for agent sandboxes using Kubernetes NetworkPolicies and Cilium CNI.

## Overview

Agent sandboxes have:
- **Internet access**: Can reach external services (required for LLM API calls)
- **Control-plane access**: Can communicate with the Netclode control-plane
- **DNS access**: Can resolve domain names via kube-system DNS
- **No private network access**: Cannot reach private IP ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
- **No Tailnet access** by default: Cannot reach Tailscale network (100.64.0.0/10)

## Configuration Options

### Enable Tailnet Access (`--tailnet`)

When creating a session with `--tailnet`, the sandbox can reach services on your Tailscale network:

```bash
netclode sessions create --repo owner/repo --repo owner/other --tailnet
```

Repeat `--repo` to clone multiple repositories into the same session.

**Allowed:**
- Tailscale CGNAT range (100.64.0.0/10)
- Everything allowed by default

**Use cases:**
- Accessing internal APIs exposed via Tailscale
- Connecting to databases on your tailnet
- Using private package registries

| Flags | Internet | Tailnet | Control-plane | DNS |
|-------|----------|---------|---------------|-----|
| (default) | Allowed | Blocked | Allowed | Allowed |
| `--tailnet` | Allowed | Allowed | Allowed | Allowed |

## Implementation Details

### SandboxTemplate

Network access is implemented using a single SandboxTemplate (`netclode-agent`) that provides:
- DNS access (kube-system)
- Control-plane access
- Ingress from Tailscale namespace (for preview URLs)

Internet access and Tailnet access are added dynamically via additional NetworkPolicies.

### NetworkPolicies

Each sandbox gets NetworkPolicies:

1. **Base policy** (from template): DNS + control-plane access
2. **Internet access** (always added): `sess-<id>-internet-access` - allows `0.0.0.0/0` except private ranges
3. **Tailnet access** (if `--tailnet`): `sess-<id>-tailnet-access` - allows `100.64.0.0/10`

```yaml
# Internet access policy (always created)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: sess-<id>-internet-access
spec:
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
              - 100.64.0.0/10
```

```yaml
# Tailnet access policy (created with --tailnet)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: sess-<id>-tailnet-access
spec:
  egress:
    - to:
        - ipBlock:
            cidr: 100.64.0.0/10
```

Since Kubernetes NetworkPolicies are additive (union), the tailnet policy allows Tailnet access alongside internet access.

## Troubleshooting

### Verify NetworkPolicies

```bash
# List policies for a session
kubectl --context netclode -n netclode get networkpolicies | grep <session-id>

# Check policy details
kubectl --context netclode -n netclode get networkpolicy sess-<id>-internet-access -o yaml
```

### Test Connectivity from a Sandbox

```bash
# Get the pod name
CLAIM_UID=$(kubectl --context netclode -n netclode get sandboxclaim sess-<id> -o jsonpath='{.metadata.uid}')
POD=$(kubectl --context netclode -n netclode get pods -l agents.x-k8s.io/claim-uid=$CLAIM_UID -o jsonpath='{.items[0].metadata.name}')

# Test internet
kubectl --context netclode -n netclode exec $POD -- curl -s --connect-timeout 5 https://httpbin.org/get

# Test control-plane
kubectl --context netclode -n netclode exec $POD -- curl -s http://control-plane.netclode.svc.cluster.local/health

# Test Tailnet (replace with your Tailscale IP)
kubectl --context netclode -n netclode exec $POD -- curl -s --connect-timeout 5 http://100.x.x.x:8123
```

### Common Issues

**Tailnet not accessible with `--tailnet`:**
- Verify the `sess-<id>-tailnet-access` NetworkPolicy exists
- Ensure the target service is actually on the Tailscale network (100.64.0.0/10)
- Check that the host has routes to Tailscale IPs (traffic is masqueraded through the host)

**DNS not working:**
- Check that kube-system namespace has the correct label: `kubernetes.io/metadata.name: kube-system`
- Verify CoreDNS pods are running
