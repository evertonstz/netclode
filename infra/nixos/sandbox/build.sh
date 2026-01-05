#!/usr/bin/env bash
set -euo pipefail

# Build Netclode Agent Sandbox VM Image
# Requires: nix with flakes enabled

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

FORMAT="${1:-raw}"
OUTPUT_DIR="${2:-./result}"

echo "Building Netclode Agent Sandbox ($FORMAT)..."

case "$FORMAT" in
  raw)
    echo "Building raw disk image for Kata/Firecracker..."
    nix build .#raw -o "$OUTPUT_DIR"
    echo "Image built: $OUTPUT_DIR/nixos.img"
    ;;
  qcow2|qcow)
    echo "Building QCOW2 image for Kata/QEMU..."
    nix build .#qcow2 -o "$OUTPUT_DIR"
    echo "Image built: $OUTPUT_DIR/nixos.qcow2"
    ;;
  docker)
    echo "Building Docker/OCI image..."
    nix build .#docker -o "$OUTPUT_DIR"
    echo "Image built: $OUTPUT_DIR"
    echo "Load with: docker load < $OUTPUT_DIR"
    ;;
  *)
    echo "Unknown format: $FORMAT"
    echo "Usage: $0 [raw|qcow2|docker] [output-dir]"
    exit 1
    ;;
esac

echo ""
echo "Build complete!"
echo ""
echo "For Kata Containers, copy the image to your k3s node:"
echo "  scp $OUTPUT_DIR/nixos.* user@node:/var/lib/kata/images/"
echo ""
echo "Then configure Kata to use this image in:"
echo "  /etc/kata-containers/configuration.toml"
echo ""
echo "  [hypervisor.qemu]"
echo "  image = \"/var/lib/kata/images/nixos.qcow2\""
