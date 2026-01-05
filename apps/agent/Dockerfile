# Alpine + Nix agent image for Kata Containers
#
# Uses Alpine as base (works with read-only rootfs) and Nix for packages.
#
FROM alpine:3.21 AS base

# Install base dependencies
# Note: coreutils required for Nix installer (BusyBox cp is incompatible)
RUN apk add --no-cache \
    bash \
    curl \
    git \
    openssh-client \
    ca-certificates \
    xz \
    coreutils \
    findutils \
    gawk \
    gnupg

# Create /nix directory (required before Nix install)
RUN mkdir -m 0755 /nix && chown root /nix

# Configure Nix for single-user (no sandbox, no build users)
RUN mkdir -p /etc/nix && \
    echo "sandbox = false" >> /etc/nix/nix.conf && \
    echo "build-users-group =" >> /etc/nix/nix.conf && \
    echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

# Install Nix using Determinate Systems installer (container-friendly)
RUN curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install linux --no-confirm --init none

# Set up Nix environment (Determinate installer puts nix at /nix/var/nix/profiles/default/bin)
ENV PATH="/nix/var/nix/profiles/default/bin:${PATH}"

# Install essential packages via Nix
RUN nix-channel --add https://nixos.org/channels/nixos-unstable nixpkgs && \
    nix-channel --update && \
    nix-env -iA \
      nixpkgs.bun \
      nixpkgs.nodejs_22 \
      nixpkgs.git \
      nixpkgs.gh \
      nixpkgs.curl \
      nixpkgs.jq \
      nixpkgs.ripgrep \
      nixpkgs.fd \
      nixpkgs.tree \
      nixpkgs.gnumake \
      nixpkgs.gcc

# Build stage - install dependencies
FROM base AS builder

WORKDIR /app

# Copy workspace config and lockfile
COPY package.json bun.lock ./
COPY packages/protocol/package.json packages/protocol/
COPY apps/agent/package.json apps/agent/

# Install dependencies (bun is in PATH via ENV)
RUN bun install

# Install Claude Code CLI globally (required by SDK)
RUN bun add -g @anthropic-ai/claude-code

# Copy source code
COPY packages/protocol packages/protocol
COPY apps/agent apps/agent

# Build (if needed)
WORKDIR /app/apps/agent

# Runtime stage
FROM base AS runtime

# Create directories
RUN mkdir -p /workspace /opt/agent /home/agent && \
    adduser -D -h /home/agent -s /bin/bash agent && \
    chown -R agent:agent /workspace /home/agent

# Copy built app and dependencies
COPY --from=builder /app/node_modules /opt/agent/node_modules
COPY --from=builder /app/apps/agent /opt/agent/apps/agent
COPY --from=builder /app/packages /opt/agent/packages

WORKDIR /opt/agent/apps/agent

# Copy global bun packages (claude CLI) to agent user home
COPY --from=builder /root/.bun /home/agent/.bun
RUN chown -R agent:agent /home/agent/.bun /opt/agent

# Environment
ENV NODE_ENV=production
ENV WORKSPACE=/workspace
ENV HOME=/home/agent
ENV PATH="/home/agent/.bun/bin:/nix/var/nix/profiles/default/bin:${PATH}"

EXPOSE 3002

# Run as non-root user (required for --dangerously-skip-permissions)
USER agent

# Run agent
CMD ["bun", "run", "src/index.ts"]
