import type { Session, SessionCreateRequest, ServerMessage } from "@netclode/protocol";
import {
  createSandbox,
  deleteSandbox,
  deleteSandboxWithStorage,
  waitForSandboxReady,
  getSandboxStatus,
} from "../k8s/sandbox";
import { connectToAgent, type AgentConnection } from "../k8s/exec";

export type MessageHandler = (message: ServerMessage) => void;

interface SessionState {
  session: Session;
  agent: AgentConnection | null;
  messageHandlers: Set<MessageHandler>;
}

export class SessionManager {
  private sessions: Map<string, SessionState> = new Map();

  async create(request: SessionCreateRequest): Promise<Session> {
    const id = crypto.randomUUID();
    const session: Session = {
      id,
      name: request.name || `session-${id.slice(0, 8)}`,
      status: "creating",
      repo: request.repo,
      createdAt: new Date().toISOString(),
      lastActiveAt: new Date().toISOString(),
    };

    this.sessions.set(id, {
      session,
      agent: null,
      messageHandlers: new Set(),
    });

    // Create sandbox pod
    try {
      await createSandbox({ sessionId: id });
      console.log(`[${id}] Sandbox pod created, waiting for ready...`);

      // Wait for pod to be ready
      const ready = await waitForSandboxReady(id, 120000);
      if (!ready) {
        session.status = "error";
        throw new Error("Sandbox failed to become ready");
      }

      session.status = "ready";
      console.log(`[${id}] Sandbox ready`);
    } catch (e) {
      console.error(`[${id}] Failed to create sandbox:`, e);
      session.status = "error";
      throw e;
    }

    return session;
  }

  async list(): Promise<Session[]> {
    return Array.from(this.sessions.values()).map((s) => s.session);
  }

  async get(id: string): Promise<Session | undefined> {
    return this.sessions.get(id)?.session;
  }

  async resume(id: string): Promise<Session> {
    const state = this.sessions.get(id);
    if (!state) {
      throw new Error(`Session ${id} not found`);
    }

    // Check if pod exists and is running
    const podStatus = await getSandboxStatus(id);
    if (!podStatus || podStatus !== "Running") {
      // Recreate sandbox if needed
      console.log(`[${id}] Pod not running (status: ${podStatus}), recreating...`);
      await createSandbox({ sessionId: id });
      const ready = await waitForSandboxReady(id, 120000);
      if (!ready) {
        state.session.status = "error";
        throw new Error("Failed to resume sandbox");
      }
    }

    state.session.status = "running";
    state.session.lastActiveAt = new Date().toISOString();

    // Connect to agent if not already connected
    if (!state.agent || !state.agent.connected) {
      try {
        state.agent = await connectToAgent({
          sessionId: id,
          onMessage: (msg) => {
            for (const handler of state.messageHandlers) {
              handler(msg);
            }
          },
          onDone: () => {
            state.session.status = "ready";
          },
          onError: (error) => {
            console.error(`[${id}] Agent error:`, error);
            for (const handler of state.messageHandlers) {
              handler({
                type: "agent.error",
                sessionId: id,
                error: error.message,
              });
            }
          },
        });
        console.log(`[${id}] Connected to agent`);
      } catch (e) {
        console.error(`[${id}] Failed to connect to agent:`, e);
        throw e;
      }
    }

    return state.session;
  }

  async pause(id: string): Promise<Session> {
    const state = this.sessions.get(id);
    if (!state) {
      throw new Error(`Session ${id} not found`);
    }

    if (state.agent) {
      state.agent.interrupt();
      state.agent.close();
      state.agent = null;
    }

    // Delete pod but keep PVC
    await deleteSandbox(id);

    state.session.status = "paused";
    state.session.lastActiveAt = new Date().toISOString();

    return state.session;
  }

  async delete(id: string): Promise<void> {
    const state = this.sessions.get(id);
    if (!state) {
      throw new Error(`Session ${id} not found`);
    }

    if (state.agent) {
      state.agent.interrupt();
      state.agent.close();
    }

    // Delete pod and storage
    await deleteSandboxWithStorage(id);

    this.sessions.delete(id);
  }

  async sendPrompt(id: string, text: string): Promise<void> {
    const state = this.sessions.get(id);
    if (!state) {
      throw new Error(`Session ${id} not found`);
    }

    if (!state.agent || !state.agent.connected) {
      throw new Error(`Session ${id} agent not connected`);
    }

    await state.agent.sendPrompt(text);
  }

  interrupt(id: string): void {
    const state = this.sessions.get(id);
    if (!state?.agent) return;

    state.agent.interrupt();
  }

  subscribe(id: string, handler: MessageHandler): () => void {
    const state = this.sessions.get(id);
    if (!state) {
      throw new Error(`Session ${id} not found`);
    }

    state.messageHandlers.add(handler);
    return () => state.messageHandlers.delete(handler);
  }
}
