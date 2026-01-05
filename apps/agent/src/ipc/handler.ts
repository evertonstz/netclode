import type { AgentInstance } from "../sdk/agent";
import { emit } from "../events/emitter";

interface PromptMessage {
  type: "prompt";
  text: string;
  sessionId: string;
}

interface InterruptMessage {
  type: "interrupt";
}

interface ShutdownMessage {
  type: "shutdown";
}

type IpcMessage = PromptMessage | InterruptMessage | ShutdownMessage;

export interface IpcHandler {
  handleMessage(line: string): Promise<void>;
}

export function createIpcHandler(agent: AgentInstance): IpcHandler {
  return {
    async handleMessage(line: string) {
      try {
        const message = JSON.parse(line) as IpcMessage;

        switch (message.type) {
          case "prompt":
            emit("agent.start", { prompt: message.text });
            await agent.run(message.text);
            break;

          case "interrupt":
            agent.interrupt();
            break;

          case "shutdown":
            process.exit(0);

          default:
            emit("error", { message: `Unknown message type: ${(message as { type: string }).type}` });
        }
      } catch (error) {
        emit("error", {
          message: error instanceof Error ? error.message : "Failed to parse message",
        });
      }
    },
  };
}
