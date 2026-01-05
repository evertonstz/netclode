import { createWebSocketServer } from "./api/ws-server";
import { SessionManager } from "./sessions/manager";
import { config } from "./config";

const sessionManager = new SessionManager();

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
