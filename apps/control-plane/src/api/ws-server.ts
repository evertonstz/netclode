import type { ServerWebSocket } from "bun";
import type { ClientMessage, ServerMessage } from "@netclode/protocol";
import type { SessionManager } from "../sessions/manager";

interface WSData {
  sessionManager: SessionManager;
  subscriptions: Map<string, () => void>;
}

export function createWebSocketServer(sessionManager: SessionManager) {
  return {
    open(ws: ServerWebSocket<WSData>) {
      console.log("Client connected");
    },

    close(ws: ServerWebSocket<WSData>) {
      // Clean up subscriptions
      for (const unsub of ws.data.subscriptions.values()) {
        unsub();
      }
      console.log("Client disconnected");
    },

    async message(ws: ServerWebSocket<WSData>, message: string | Buffer) {
      try {
        const data = JSON.parse(
          typeof message === "string" ? message : message.toString()
        ) as ClientMessage;

        await handleMessage(data, sessionManager, ws);
      } catch (error) {
        const errorResponse: ServerMessage = {
          type: "error",
          message: error instanceof Error ? error.message : "Unknown error",
        };
        ws.send(JSON.stringify(errorResponse));
      }
    },
  };
}

async function handleMessage(
  message: ClientMessage,
  sessionManager: SessionManager,
  ws: ServerWebSocket<WSData>
): Promise<void> {
  const send = (msg: ServerMessage) => ws.send(JSON.stringify(msg));

  switch (message.type) {
    case "session.create": {
      const session = await sessionManager.create({
        name: message.name,
        repo: message.repo,
      });

      // Auto-subscribe to agent messages
      if (!ws.data.subscriptions.has(session.id)) {
        const unsub = sessionManager.subscribe(session.id, (msg) => {
          ws.send(JSON.stringify(msg));
        });
        ws.data.subscriptions.set(session.id, unsub);
      }

      send({ type: "session.created", session });
      break;
    }

    case "session.list": {
      const sessions = await sessionManager.list();
      send({ type: "session.list", sessions });
      break;
    }

    case "session.resume": {
      const session = await sessionManager.resume(message.id);

      // Subscribe to agent messages for this session
      if (!ws.data.subscriptions.has(message.id)) {
        const unsub = sessionManager.subscribe(message.id, (msg) => {
          ws.send(JSON.stringify(msg));
        });
        ws.data.subscriptions.set(message.id, unsub);
      }

      send({ type: "session.updated", session });
      break;
    }

    case "session.pause": {
      const session = await sessionManager.pause(message.id);

      // Unsubscribe from agent messages
      const unsub = ws.data.subscriptions.get(message.id);
      if (unsub) {
        unsub();
        ws.data.subscriptions.delete(message.id);
      }

      send({ type: "session.updated", session });
      break;
    }

    case "session.delete": {
      // Unsubscribe first
      const unsub = ws.data.subscriptions.get(message.id);
      if (unsub) {
        unsub();
        ws.data.subscriptions.delete(message.id);
      }

      await sessionManager.delete(message.id);
      send({ type: "session.deleted", id: message.id });
      break;
    }

    case "prompt": {
      // Fire and forget - responses come via subscription
      sessionManager.sendPrompt(message.sessionId, message.text).catch((error) => {
        send({
          type: "agent.error",
          sessionId: message.sessionId,
          error: error instanceof Error ? error.message : "Failed to send prompt",
        });
      });
      break;
    }

    case "prompt.interrupt": {
      sessionManager.interrupt(message.sessionId);
      break;
    }

    case "terminal.input": {
      // TODO: Forward to PTY when implemented
      console.log(`Terminal input for session ${message.sessionId}: ${message.data}`);
      break;
    }

    case "terminal.resize": {
      // TODO: Resize PTY when implemented
      console.log(`Terminal resize for session ${message.sessionId}: ${message.cols}x${message.rows}`);
      break;
    }

    default:
      send({ type: "error", message: "Unknown message type" });
  }
}
