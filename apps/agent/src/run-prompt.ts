#!/usr/bin/env bun
/**
 * Subprocess script to run SDK prompts
 * Reads prompt from PROMPT_TEXT env var
 */
import { query } from "@anthropic-ai/claude-agent-sdk";

const cwd = process.env.WORKSPACE || "/workspace";
const promptText = process.env.PROMPT_TEXT;

if (!promptText) {
  console.error("PROMPT_TEXT env var required");
  process.exit(1);
}

const input = { text: promptText };

const send = (data: object) => {
  process.stdout.write(`data: ${JSON.stringify(data)}\n\n`);
};

try {
  send({ type: "start" });

  const q = query({
    prompt: input.text,
    options: {
      cwd,
      dangerouslySkipPermissions: true,
      model: "claude-opus-4-5-20251101",
    },
  });

  for await (const message of q) {
    switch (message.type) {
      case "system":
        send({ type: "agent.system", subtype: message.subtype });
        break;
      case "assistant":
        if (message.message?.content) {
          for (const block of message.message.content) {
            if (block.type === "text") {
              send({ type: "agent.message", content: block.text, partial: false });
            } else if (block.type === "tool_use") {
              send({
                type: "agent.event",
                event: { kind: "tool_start", tool: block.name, toolUseId: block.id, input: block.input },
              });
            }
          }
        }
        break;
      case "user":
        if (message.message?.content && Array.isArray(message.message.content)) {
          for (const block of message.message.content) {
            if (typeof block === "object" && block.type === "tool_result") {
              send({ type: "agent.event", event: { kind: "tool_end", toolUseId: block.tool_use_id } });
            }
          }
        }
        break;
      case "result":
        if (message.subtype === "success") {
          send({ type: "agent.result", result: message.result, numTurns: message.num_turns, costUsd: message.total_cost_usd });
        }
        break;
      case "stream_event":
        if (message.event.type === "content_block_delta") {
          const delta = message.event.delta;
          if (delta && "text" in delta) {
            send({ type: "agent.message", content: delta.text, partial: true });
          }
        }
        break;
    }
  }

  send({ type: "done" });
} catch (error) {
  console.error("[run-prompt] Error:", error);
  send({ type: "error", error: String(error) });
}
