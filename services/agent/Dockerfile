# Debian-slim + mise agent image
#
# On-demand tooling via:
#   mise install python@3.12
#   mise install go@latest
#   mise install rust@latest
#
FROM debian:trixie-slim AS base

# Install essentials + mise + docker
# Note: Use iptables-legacy because Kata VM kernel lacks nftables support
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    git \
    ca-certificates \
    build-essential \
    docker.io \
    docker-cli \
    iptables \
    sudo \
    && update-alternatives --set iptables /usr/sbin/iptables-legacy \
    && update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy \
    && rm -rf /var/lib/apt/lists/* \
    && curl https://mise.run | sh

ENV PATH="/root/.local/bin:/root/.local/share/mise/shims:${PATH}"

# Install node via mise
RUN mise install node@24 && \
    mise use -g node@24 && \
    mise reshim

# =============================================================================
# Builder
# =============================================================================
FROM base AS builder

# Install Python for node-gyp (required by node-pty)
RUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Install esbuild for bundling
RUN npm install -g esbuild

# Copy agent source
COPY services/agent services/agent

# Install agent dependencies
WORKDIR /build/services/agent
RUN --mount=type=cache,target=/root/.npm npm install

# Bundle agent
RUN esbuild src/index.ts --bundle --platform=node --format=esm --packages=external --outfile=dist/agent.js

# Claude CLI
RUN --mount=type=cache,target=/root/.npm \
    npm install -g @anthropic-ai/claude-code

# OpenCode CLI (download Linux x64 binary from GitHub releases)
RUN curl -fsSL "https://github.com/anomalyco/opencode/releases/latest/download/opencode-linux-x64.tar.gz" -o /tmp/opencode.tar.gz && \
    tar -xzf /tmp/opencode.tar.gz -C /tmp && \
    mv /tmp/opencode /usr/local/bin/opencode && \
    chmod +x /usr/local/bin/opencode && \
    rm -rf /tmp/opencode.tar.gz

# Install bun for OpenCode plugin installation
RUN curl -fsSL https://bun.sh/install | bash

# Pre-install OpenCode plugins by running it once
# This downloads all required npm packages so they're cached in the image
ENV PATH="/root/.bun/bin:${PATH}"
RUN mkdir -p /opt/opencode-cache/config /opt/opencode-cache/cache && \
    XDG_CONFIG_HOME=/opt/opencode-cache/config XDG_CACHE_HOME=/opt/opencode-cache/cache \
    timeout 120 /bin/sh -c 'opencode serve --port 19999 2>&1 & \
    sleep 3 && \
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do \
      if curl -s http://127.0.0.1:19999/session > /dev/null 2>&1; then \
        echo "OpenCode ready after ${i}0 seconds"; \
        break; \
      fi; \
      sleep 10; \
    done; \
    pkill opencode || true'

# =============================================================================
# Runtime
# =============================================================================
FROM base AS runtime

# Create non-root user with docker access and passwordless sudo
# Note: /agent is the persistent home dir, mounted from JuiceFS
# Sudo is safe because we run inside an isolated Kata VM
RUN useradd -m -u 1000 -G docker -d /agent agent && \
    echo 'agent ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/agent && \
    chmod 0440 /etc/sudoers.d/agent && \
    mkdir -p /agent /opt/agent && \
    chown -R agent:agent /agent /opt/agent

# Copy bundled app and dependencies
COPY --from=builder --chown=agent:agent /build/services/agent/dist/agent.js /opt/agent/
COPY --from=builder --chown=agent:agent /build/services/agent/node_modules /opt/agent/node_modules

# Copy OpenCode binary and pre-cached plugins from builder
COPY --from=builder /usr/local/bin/opencode /usr/local/bin/opencode
COPY --from=builder /opt/opencode-cache /opt/opencode-cache

# Copy mise and node to /opt (NOT /agent which is a volume mount)
# mise binary and shims need to be in a persistent location
RUN mkdir -p /opt/mise/bin /opt/mise/shims && \
    cp /root/.local/bin/mise /opt/mise/bin/ && \
    cp -r /root/.local/share/mise /opt/mise/share
COPY --from=builder /root/.local/share/mise/installs/node/24 /opt/node

# Install bun (download binary directly)
RUN apt-get update && apt-get install -y --no-install-recommends unzip && \
    curl -fsSL "https://github.com/oven-sh/bun/releases/latest/download/bun-linux-x64.zip" -o /tmp/bun.zip && \
    unzip /tmp/bun.zip -d /tmp && \
    mv /tmp/bun-linux-x64/bun /opt/bun && \
    chmod +x /opt/bun && \
    rm -rf /tmp/bun.zip /tmp/bun-linux-x64 /var/lib/apt/lists/*

# Create profile for agent user that sets PATH and mise env vars
# This ensures any shell spawned (including by Claude Code) has access to mise
# Add to both /etc/profile.d (login shells) and /etc/bash.bashrc (interactive non-login)
# MISE_DATA_DIR is in /agent so installed tools persist across pod restarts
# Shims path is included so mise-installed tools are available
# XDG_CONFIG_HOME avoids JuiceFS .config file at mount root
RUN echo 'export MISE_DATA_DIR=/agent/.local/share/mise' >> /etc/profile.d/mise.sh && \
    echo 'export MISE_CACHE_DIR=/agent/.cache/mise' >> /etc/profile.d/mise.sh && \
    echo 'export XDG_CONFIG_HOME=/agent/.local/config' >> /etc/profile.d/mise.sh && \
    echo 'export XDG_CACHE_HOME=/agent/.cache' >> /etc/profile.d/mise.sh && \
    echo 'export PATH="/agent/.local/share/mise/shims:/opt/mise/bin:/opt/node/bin:/opt:$PATH"' >> /etc/profile.d/mise.sh && \
    chmod +x /etc/profile.d/mise.sh && \
    echo 'export MISE_DATA_DIR=/agent/.local/share/mise' >> /etc/bash.bashrc && \
    echo 'export MISE_CACHE_DIR=/agent/.cache/mise' >> /etc/bash.bashrc && \
    echo 'export XDG_CONFIG_HOME=/agent/.local/config' >> /etc/bash.bashrc && \
    echo 'export XDG_CACHE_HOME=/agent/.cache' >> /etc/bash.bashrc && \
    echo 'export PATH="/agent/.local/share/mise/shims:/opt/mise/bin:/opt/node/bin:/opt:$PATH"' >> /etc/bash.bashrc && \
    echo 'export PS1='"'"'\[\033[01;32m\]\u\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '"'" >> /etc/bash.bashrc

# Copy entrypoint script
COPY services/agent/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /opt/agent

ENV NODE_ENV=production
ENV HOME=/agent
ENV MISE_DATA_DIR=/agent/.local/share/mise
ENV MISE_CACHE_DIR=/agent/.cache/mise
ENV XDG_CONFIG_HOME=/agent/.local/config
ENV XDG_CACHE_HOME=/agent/.cache
ENV PATH="/agent/.local/share/mise/shims:/opt/mise/bin:/opt/node/bin:/opt:${PATH}"

EXPOSE 3002

# Start as root to run dockerd, then drop to agent user
ENTRYPOINT ["/entrypoint.sh"]
