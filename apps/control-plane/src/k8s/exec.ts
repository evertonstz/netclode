import type { ServerMessage, AgentEvent } from "@netclode/protocol";
import { coreApi, NAMESPACE } from "./client";

export interface AgentConnection {
  sendPrompt(text: string): Promise<void>;
  interrupt(): void;
  close(): void;
  readonly connected: boolean;
}

export interface AgentConnectionOptions {
  sessionId: string;
  onMessage: (message: ServerMessage) => void;
  onDone: () => void;
  onError: (error: Error) => void;
}

/**
 * Gets the pod IP for a session's agent pod.
 */
async function getPodIP(sessionId: string): Promise<string> {
  const podName = `session-${sessionId}`;
  const pod = await coreApi.readNamespacedPod({
    name: podName,
    namespace: NAMESPACE,
  });

  const podIP = pod.status?.podIP;
  if (!podIP) {
    throw new Error(`Pod ${podName} has no IP assigned`);
  }

  return podIP;
}

/**
 * Creates a connection to an agent pod via HTTP.
 * The agent runs an HTTP server on port 3002.
 */
export function connectToAgent(
  options: AgentConnectionOptions
): AgentConnection {
  const { sessionId, onMessage, onDone, onError } = options;

  let abortController: AbortController | null = null;
  let agentUrl: string | null = null;
  let connected = false;

  // Initialize connection by getting pod IP
  getPodIP(sessionId)
    .then((ip) => {
      agentUrl = `http://${ip}:3002`;
      connected = true;
      console.log(`[${sessionId}] Agent URL: ${agentUrl}`);
    })
    .catch((err) => {
      onError(new Error(`Failed to get agent pod IP: ${err.message}`));
    });

  return {
    async sendPrompt(text: string) {
      if (!agentUrl) {
        // Wait a bit for connection to initialize
        await new Promise((r) => setTimeout(r, 1000));
        if (!agentUrl) {
          throw new Error("Agent not connected - no pod IP");
        }
      }

      abortController = new AbortController();

      try {
        const response = await fetch(`${agentUrl}/prompt`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ sessionId, text }),
          signal: abortController.signal,
        });

        if (!response.ok) {
          throw new Error(`Agent returned ${response.status}`);
        }

        // Read SSE stream
        const reader = response.body?.getReader();
        if (!reader) throw new Error("No response body");

        const decoder = new TextDecoder();
        let buffer = "";

        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split("\n\n");
          buffer = lines.pop() || "";

          for (const line of lines) {
            if (line.startsWith("data: ")) {
              try {
                const data = JSON.parse(line.slice(6));
                handleAgentMessage(sessionId, data, onMessage);
              } catch (e) {
                console.error(`[${sessionId}] Failed to parse:`, line);
              }
            }
          }
        }

        onDone();
      } catch (error) {
        if (error instanceof Error && error.name === "AbortError") {
          onMessage({ type: "agent.done", sessionId });
        } else {
          onError(error instanceof Error ? error : new Error(String(error)));
        }
      } finally {
        abortController = null;
      }
    },

    interrupt() {
      abortController?.abort();
      if (agentUrl) {
        fetch(`${agentUrl}/interrupt`, { method: "POST" }).catch(() => {});
      }
    },

    close() {
      abortController?.abort();
      connected = false;
    },

    get connected() {
      return connected && agentUrl !== null;
    },
  };
}

function handleAgentMessage(
  sessionId: string,
  data: Record<string, unknown>,
  onMessage: (msg: ServerMessage) => void
) {
  const type = data.type as string;

  switch (type) {
    case "agent.message":
      onMessage({
        type: "agent.message",
        sessionId,
        content: data.content as string,
      });
      break;
    case "agent.event":
      onMessage({
        type: "agent.event",
        sessionId,
        event: data.event as AgentEvent,
      });
      break;
    case "agent.done":
      onMessage({ type: "agent.done", sessionId });
      break;
    case "agent.error":
      onMessage({
        type: "agent.error",
        sessionId,
        error: data.error as string,
      });
      break;
    case "agent.system":
    case "agent.result":
      console.log(`[${sessionId}] ${type}:`, data);
      // Forward result as a message
      if (type === "agent.result" && data.result) {
        onMessage({
          type: "agent.message",
          sessionId,
          content: data.result as string,
        });
      }
      break;
  }
}
