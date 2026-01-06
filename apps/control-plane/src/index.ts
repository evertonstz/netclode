import { createWebSocketServer } from "./api/ws-server";
import { SessionManager } from "./sessions/manager";
import { initRedisStorage, getRedisStorage } from "./storage/redis";
import { config } from "./config";

async function main() {
  console.log("[startup] Starting control plane...");
  console.log("[startup] Config:", JSON.stringify({
    port: config.port,
    redisUrl: config.redisUrl,
    namespace: config.namespace,
    maxMessagesPerSession: config.maxMessagesPerSession,
    maxEventsPerSession: config.maxEventsPerSession,
  }, null, 2));

  // Initialize Redis connection
  console.log(`[startup] Connecting to Redis at ${config.redisUrl}...`);
  let storage;
  try {
    storage = await initRedisStorage();
    console.log("[startup] Redis connected successfully");
  } catch (error) {
    console.error("[startup] FATAL: Failed to connect to Redis:", error);
    process.exit(1);
  }

  // Initialize session manager with Redis storage
  console.log("[startup] Initializing session manager...");
  const sessionManager = new SessionManager(storage);
  await sessionManager.initialize();
  console.log("[startup] Session manager initialized");

  const server = Bun.serve({
    port: config.port,
    fetch(req, server) {
      const url = new URL(req.url);

      // Health check
      if (url.pathname === "/health") {
        return new Response("ok");
      }

      // WebSocket upgrade
      if (url.pathname === "/ws") {
        const success = server.upgrade(req, {
          data: { sessionManager, subscriptions: new Map() },
        });
        if (success) return undefined;
        return new Response("WebSocket upgrade failed", { status: 400 });
      }

      return new Response("Not found", { status: 404 });
    },
    websocket: createWebSocketServer(sessionManager),
  });

  console.log(`Control plane listening on http://localhost:${server.port}`);
  console.log(`WebSocket endpoint: ws://localhost:${server.port}/ws`);

  // Graceful shutdown
  const shutdown = async () => {
    console.log("Shutting down...");
    try {
      await getRedisStorage().close();
      console.log("Redis connection closed");
    } catch (error) {
      console.error("Error during shutdown:", error);
    }
    process.exit(0);
  };

  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main().catch((error) => {
  console.error("Startup failed:", error);
  process.exit(1);
});
