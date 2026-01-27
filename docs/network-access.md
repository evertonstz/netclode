# Network Access Control

Netclode provides fine-grained network access control for agent sandboxes using Kubernetes NetworkPolicies and Cilium CNI.

## Overview

By default, agent sandboxes have:
- **Internet access**: Can reach external services (0.0.0.0/0)
- **Control-plane access**: Can communicate with the Netclode control-plane
- **DNS access**: Can resolve domain names via kube-system DNS
- **No private network access**: Cannot reach private IP ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10)

## Configuration Options

### Block Internet Access (`--no-internet`)

When creating a session with `--no-internet`, the sandbox cannot reach the public internet:

```bash
netclode sessions create --repo owner/repo --no-internet
```

**Allowed:**
- DNS resolution (kube-system)
- Control-plane communication (for agent protocol)

**Blocked:**
- All internet egress (0.0.0.0/0)
- Private networks (unchanged)

**Use cases:**
- Running untrusted code that shouldn't exfiltrate data
- Enforcing air-gapped development environments
- Testing offline behavior

### Enable Tailnet Access (`--tailnet`)

When creating a session with `--tailnet`, the sandbox can reach services on your Tailscale network:

```bash
netclode sessions create --repo owner/repo --tailnet
```

**Allowed:**
- Tailscale CGNAT range (100.64.0.0/10)
- Everything allowed by default

**Use cases:**
- Accessing internal APIs exposed via Tailscale
- Connecting to databases on your tailnet
- Using private package registries

### Combined Options

You can combine both flags for maximum control:

```bash
# No internet, but can reach Tailnet services
netclode sessions create --repo owner/repo --no-internet --tailnet
```

| Flags | Internet | Tailnet | Control-plane | DNS |
|-------|----------|---------|---------------|-----|
| (default) | Allowed | Blocked | Allowed | Allowed |
| `--no-internet` | Blocked | Blocked | Allowed | Allowed |
| `--tailnet` | Allowed | Allowed | Allowed | Allowed |
| `--no-internet --tailnet` | Blocked | Allowed | Allowed | Allowed |

## Implementation Details

### SandboxTemplates

Network access is implemented using different SandboxTemplates:

- **`netclode-agent`**: Default template with internet access
- **`netclode-agent-no-internet`**: Template without internet egress rule

When `--no-internet` is specified, the control-plane creates a SandboxClaim referencing the `netclode-agent-no-internet` template.

### NetworkPolicies

Each sandbox gets NetworkPolicies created by the sandbox controller based on the template:

```yaml
# Default policy (from template)
spec:
  egress:
    # Control-plane access
    - to:
        - podSelector:
            matchLabels:
              app: control-plane
      ports:
        - port: 80
        - port: 3000
    # Internet access (NOT present in no-internet template)
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
              - 100.64.0.0/10
    # DNS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - port: 53
```

### Tailnet Access Policy

When `--tailnet` is specified, an additional NetworkPolicy is created:

```yaml
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

Since Kubernetes NetworkPolicies are additive (union), this allows Tailnet access even when the base template excludes it.

## Troubleshooting

### Verify NetworkPolicies

```bash
# List policies for a session
kubectl --context netclode -n netclode get networkpolicies | grep <session-id>

# Check policy details
kubectl --context netclode -n netclode get networkpolicy sess-<id>-network-policy -o yaml
```

### Test Connectivity from a Sandbox

```bash
# Get the pod name
CLAIM_UID=$(kubectl --context netclode -n netclode get sandboxclaim sess-<id> -o jsonpath='{.metadata.uid}')
POD=$(kubectl --context netclode -n netclode get pods -l agents.x-k8s.io/claim-uid=$CLAIM_UID -o jsonpath='{.items[0].metadata.name}')

# Test internet
kubectl --context netclode -n netclode exec $POD -- curl -s --connect-timeout 5 https://google.com

# Test control-plane
kubectl --context netclode -n netclode exec $POD -- curl -s http://control-plane/health

# Test Tailnet (replace with your Tailscale IP)
kubectl --context netclode -n netclode exec $POD -- curl -s --connect-timeout 5 https://100.x.x.x/health
```

### Common Issues

**Internet still accessible with `--no-internet`:**
- Ensure the control-plane was restarted after deploying the `netclode-agent-no-internet` template
- Check that the SandboxClaim references the correct template in logs

**Tailnet not accessible with `--tailnet`:**
- Verify the tailnet-access NetworkPolicy exists
- Ensure the target service is actually on the Tailscale network (100.64.0.0/10)

**DNS not working:**
- Check that kube-system namespace has the correct label: `kubernetes.io/metadata.name: kube-system`
- Verify CoreDNS pods are running
