# Cilium CNI Role

Installs Cilium as the CNI for k3s, replacing Flannel. Required for NetworkPolicy support with Kata containers.

## Prerequisites

k3s must be started with `--flannel-backend=none` to disable the default Flannel CNI.

## Configuration

Key Helm values:

| Parameter | Value | Reason |
|-----------|-------|--------|
| `kubeProxyReplacement` | `false` | Let k3s kube-proxy handle services (more conservative) |
| `MTU` | `1450` | **Critical** - see MTU section below |
| `hubble.enabled` | `true` | Observability |

## MTU Configuration

**This is critical and must not be changed without understanding the implications.**

### The Problem

Cilium auto-detects MTU from host interfaces. If Tailscale is installed, it may pick up `tailscale0` which has MTU 1280 (WireGuard default). This causes TLS handshake failures with modern clients.

### Why 1280 MTU Breaks TLS

Go 1.24+ and OpenSSL 3.x enable **post-quantum key exchange (X25519MLKEM768)** by default. The Kyber key shares are ~1200 bytes, which don't fit in 1280 MTU packets:

```
Packet breakdown:
  IP header:        20 bytes
  TCP header:       20 bytes
  TLS record:        5 bytes
  ClientHello:    ~200 bytes
  Kyber key share: 1184 bytes
  ─────────────────────────────
  Total:          ~1429 bytes  → exceeds 1280 MTU
```

This causes packet fragmentation issues over Tailscale's userspace WireGuard, resulting in TLS handshake timeouts.

### The Fix

Explicitly set `MTU: 1450` (1500 physical MTU - 50 VXLAN overhead) so Cilium ignores the low-MTU Tailscale interface.

### Symptoms of Wrong MTU

- TLS 1.3 connections timeout from Go/OpenSSL clients
- `curl` works (uses SecureTransport on macOS, no post-quantum support yet)
- TLS 1.2 works (smaller key exchanges)
- Tailscale proxy logs show: `http: TLS handshake error from x.x.x.x: EOF`

### Key Size Comparison

| Algorithm | Type | Key Share Size |
|-----------|------|----------------|
| X25519 | Classical ECDH | 32 bytes |
| ML-KEM-768 (Kyber) | Post-quantum | 1184 bytes |
| X25519MLKEM768 | Hybrid | ~1216 bytes |

### References

- [Tailscale issue #15102](https://github.com/tailscale/tailscale/issues/15102) - Similar symptoms, different root cause
- [Cilium MTU docs](https://docs.cilium.io/en/stable/operations/performance/tuning/#mtu)
- [NIST Post-Quantum Cryptography](https://csrc.nist.gov/projects/post-quantum-cryptography)
