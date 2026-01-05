import type { ServerMessage } from "@netclode/protocol";

const AGENT_URL = process.env.AGENT_URL || "http://localhost:3002";

export interface AgentProcess {
  sendPrompt(text: string): Promise<void>;
  interrupt(): void;
  readonly running: boolean;
}

export interface AgentProcessOptions {
  sessionId: string;
  onMessage: (message: ServerMessage) => void;
  onDone: () => void;
}

export function createAgentClient(options: AgentProcessOptions): AgentProcess {
  const { sessionId, onMessage, onDone } = options;
  let abortController: AbortController | null = null;

  return {
    async sendPrompt(text: string) {
      abortController = new AbortController();

      try {
        const response = await fetch(`${AGENT_URL}/prompt`, {
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
          onMessage({
            type: "agent.error",
            sessionId,
            error: error instanceof Error ? error.message : String(error),
          });
        }
      } finally {
        abortController = null;
      }
    },

    interrupt() {
      abortController?.abort();
      fetch(`${AGENT_URL}/interrupt`, { method: "POST" }).catch(() => {});
    },

    get running() {
      return abortController !== null;
    },
  };
}

function handleAgentMessage(
  sessionId: string,
  data: any,
  onMessage: (msg: ServerMessage) => void
) {
  switch (data.type) {
    case "agent.message":
      onMessage({ type: "agent.message", sessionId, content: data.content });
      break;
    case "agent.event":
      onMessage({ type: "agent.event", sessionId, event: data.event });
      break;
    case "agent.done":
      onMessage({ type: "agent.done", sessionId });
      break;
    case "agent.error":
      onMessage({ type: "agent.error", sessionId, error: data.error });
      break;
    case "agent.system":
    case "agent.result":
      console.log(`[${sessionId}] ${data.type}:`, data);
      break;
  }
}
