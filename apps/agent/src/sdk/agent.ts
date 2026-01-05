import { query, type SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { emit } from "../events/emitter";
import { config } from "../config";

export interface AgentInstance {
  run(prompt: string): Promise<void>;
  interrupt(): void;
}

let currentQuery: ReturnType<typeof query> | null = null;

export function createAgent(): AgentInstance {
  return {
    async run(prompt: string) {
      try {
        currentQuery = query({
          prompt,
          options: {
            tools: { type: "preset", preset: "claude_code" },
            allowedTools: ["Read", "Write", "Edit", "Bash", "Glob", "Grep"],
            permissionMode: "bypassPermissions",
            allowDangerouslySkipPermissions: true,
            cwd: config.workspacePath,
            model: "claude-sonnet-4-20250514",
            persistSession: false,
          },
        });

        for await (const message of currentQuery) {
          handleMessage(message);
        }

        emit("agent.done", {});
      } catch (error) {
        if (error instanceof Error && error.message.includes("abort")) {
          emit("agent.interrupted", {});
        } else {
          console.error("[agent] Error:", error);
          emit("agent.error", {
            error: error instanceof Error ? error.message : String(error),
          });
        }
      } finally {
        currentQuery = null;
      }
    },

    interrupt() {
      currentQuery?.interrupt();
    },
  };
}

function handleMessage(message: SDKMessage) {
  switch (message.type) {
    case "system":
      emit("agent.system", { subtype: message.subtype });
      break;

    case "assistant":
      if (message.message?.content) {
        for (const block of message.message.content) {
          if (block.type === "text") {
            emit("agent.message", { content: block.text, partial: false });
          } else if (block.type === "tool_use") {
            emit("agent.event", {
              event: {
                kind: "tool_start",
                tool: block.name,
                toolUseId: block.id,
                input: block.input,
                timestamp: new Date().toISOString(),
              },
            });
          }
        }
      }
      break;

    case "user":
      if (message.message?.content && Array.isArray(message.message.content)) {
        for (const block of message.message.content) {
          if (typeof block === "object" && block.type === "tool_result") {
            emit("agent.event", {
              event: {
                kind: "tool_end",
                toolUseId: block.tool_use_id,
                timestamp: new Date().toISOString(),
              },
            });
          }
        }
      }
      break;

    case "result":
      if (message.subtype === "success") {
        emit("agent.result", {
          result: message.result,
          numTurns: message.num_turns,
          costUsd: message.total_cost_usd,
        });
      }
      break;

    case "stream_event":
      if (message.event.type === "content_block_delta") {
        const delta = message.event.delta;
        if (delta && "text" in delta) {
          emit("agent.message", { content: delta.text, partial: true });
        }
      }
      break;
  }
}
