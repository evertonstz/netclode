# Debian-slim + mise agent image
#
# On-demand tooling via:
#   mise install python@3.12
#   mise install go@latest
#   mise install rust@latest
#
FROM debian:bookworm-slim AS base

# Install essentials + mise
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    git \
    ca-certificates \
    build-essential \
    && rm -rf /var/lib/apt/lists/* \
    && curl https://mise.run | sh

ENV PATH="/root/.local/bin:/root/.local/share/mise/shims:${PATH}"

# Install bun and node via mise, set global versions
RUN mise install bun@latest node@22 && \
    mise use -g bun@latest node@22 && \
    mise reshim

# =============================================================================
# Builder
# =============================================================================
FROM base AS builder

WORKDIR /build

COPY package.json bun.lock ./
COPY packages/protocol/package.json packages/protocol/
COPY apps/agent/package.json apps/agent/

RUN bun install

COPY packages/protocol packages/protocol
COPY apps/agent apps/agent

# Bundle agent
RUN cd apps/agent && bun build src/index.ts --target bun --outfile dist/agent.js

# Claude CLI
RUN bun add -g @anthropic-ai/claude-code

# =============================================================================
# Runtime
# =============================================================================
FROM base AS runtime

# Create non-root user
RUN useradd -m -u 1000 agent && \
    mkdir -p /workspace /opt/agent && \
    chown -R agent:agent /workspace /opt/agent

# Copy mise for agent user (including config)
RUN mkdir -p /home/agent/.local /home/agent/.config && \
    cp -r /root/.local/bin /home/agent/.local/ && \
    cp -r /root/.local/share /home/agent/.local/ && \
    cp -r /root/.config/mise /home/agent/.config/ 2>/dev/null || true && \
    chown -R agent:agent /home/agent/.local /home/agent/.config

# Copy bundled app
COPY --from=builder --chown=agent:agent /build/apps/agent/dist/agent.js /opt/agent/

# Copy claude CLI
COPY --from=builder --chown=agent:agent /root/.bun/install/global /home/agent/.bun/install/global
COPY --from=builder --chown=agent:agent /root/.bun/bin /home/agent/.bun/bin

USER agent
WORKDIR /opt/agent

ENV NODE_ENV=production
ENV WORKSPACE=/workspace
ENV PATH="/home/agent/.bun/bin:/home/agent/.local/bin:/home/agent/.local/share/mise/shims:${PATH}"
ENV HOME=/home/agent
ENV MISE_DATA_DIR=/home/agent/.local/share/mise

EXPOSE 3002

CMD ["bun", "run", "agent.js"]
