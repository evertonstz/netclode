#!/bin/bash

# Ensure directories exist and are owned by agent
# /agent is HOME (persisted on JuiceFS)
# /agent/workspace is for the user's code
mkdir -p /agent/workspace /agent/.local /agent/.cache
chown -R agent:agent /agent 2>/dev/null || true

# Try to start Docker daemon in background (optional, may fail in some environments)
if [ "${ENABLE_DOCKER:-false}" = "true" ]; then
    echo "[entrypoint] Starting Docker daemon..."
    mkdir -p /agent/docker
    dockerd --storage-driver=vfs --data-root=/agent/docker >/dev/null 2>&1 &

    # Brief wait, but don't block agent startup
    sleep 2
    if [ -S /var/run/docker.sock ]; then
        chmod 666 /var/run/docker.sock 2>/dev/null || true
        echo "[entrypoint] Docker daemon started"
    else
        echo "[entrypoint] Docker daemon not available (continuing without Docker)"
    fi
else
    echo "[entrypoint] Docker disabled (set ENABLE_DOCKER=true to enable)"
fi

# Drop privileges and run agent
echo "[entrypoint] Starting agent as user 'agent'..."
exec su -s /bin/bash agent -c "cd /opt/agent && node agent.js"
