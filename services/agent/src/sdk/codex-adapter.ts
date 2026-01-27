/**
 * OpenAI Codex SDK Adapter
 *
 * Uses @openai/codex-sdk to communicate with OpenAI's Codex agent.
 *
 * ## Authentication
 *
 * The Codex SDK supports two authentication modes:
 *
 * 1. **API Key Mode** (default)
 *    - Uses OPENAI_API_KEY environment variable
 *    - Standard OpenAI API authentication
 *
 * 2. **ChatGPT OAuth Mode**
 *    - Uses OAuth tokens from ChatGPT login
 *    - Tokens written to ~/.codex/auth.json
 *    - Allows using ChatGPT subscription for Codex
 */

import { Codex, type Thread, type ThreadEvent, type ThreadItem } from "@openai/codex-sdk";
import type { SDKAdapter, SDKConfig, PromptConfig, PromptEvent } from "./types.js";
import { isSessionInitialized, markSessionInitialized } from "../services/session.js";
import { setupRepository } from "../git.js";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import * as os from "node:os";

const WORKSPACE_DIR = "/agent/workspace";

// Codex session ID mapping (Netclode session ID -> Codex thread ID)
const codexThreadMap = new Map<string, string>();

export class CodexAdapter implements SDKAdapter {
  private config: SDKConfig | null = null;
  private codex: Codex | null = null;
  private thread: Thread | null = null;
  private interruptSignal = false;
  private currentGitRepo: string | null = null;
  private currentGithubToken: string | null = null;

  // Track tool start times for duration calculation
  private toolStartTimes = new Map<string, number>();

  // Accumulate usage data for result event
  private lastUsage: { inputTokens: number; outputTokens: number } | null = null;

  // Track current thinking block for correlating reasoning
  private currentThinkingId: string | null = null;
  private thinkingIdCounter = 0;

  async initialize(config: SDKConfig): Promise<void> {
    this.config = config;

    console.log("[codex-adapter] Initializing");
    console.log("[codex-adapter] Model:", config.model || "default");
    console.log("[codex-adapter] OAuth tokens available:", Boolean(config.codexAccessToken));

    // If OAuth tokens are provided, write them to ~/.codex/auth.json
    // The Codex CLI binary reads credentials from this location
    if (config.codexAccessToken && config.codexIdToken) {
      await this.writeCodexAuth(config.codexAccessToken, config.codexIdToken);
    }

    // Create Codex client
    // Note: If OAuth tokens are written, the CLI will use them automatically
    // If not, it will fall back to OPENAI_API_KEY env var
    this.codex = new Codex({
      // apiKey is optional - if not provided, uses env var or OAuth tokens
      env: {
        ...process.env,
        // Ensure OPENAI_API_KEY is available if set
        ...(process.env.OPENAI_API_KEY && { OPENAI_API_KEY: process.env.OPENAI_API_KEY }),
      },
    });

    console.log("[codex-adapter] Client created");
  }

  /**
   * Write OAuth tokens to Codex auth file
   * The Codex CLI reads from ~/.codex/auth.json
   */
  private async writeCodexAuth(accessToken: string, idToken: string): Promise<void> {
    const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
    await fs.mkdir(codexHome, { recursive: true });

    const authData = {
      tokens: {
        access_token: accessToken,
        id_token: idToken,
        // refresh_token would be here too if we had it
      },
      last_refresh: new Date().toISOString(),
    };

    const authPath = path.join(codexHome, "auth.json");
    await fs.writeFile(authPath, JSON.stringify(authData, null, 2), { mode: 0o600 });
    console.log("[codex-adapter] OAuth tokens written to", authPath);
  }

  async *executePrompt(sessionId: string, text: string, promptConfig?: PromptConfig): AsyncGenerator<PromptEvent> {
    if (!this.codex) {
      throw new Error("Codex client not initialized");
    }

    // Reset tracking for new prompt
    this.currentThinkingId = null;

    console.log(
      `[codex-adapter] ExecutePrompt (session=${sessionId}): "${text.slice(0, 100)}${text.length > 100 ? "..." : ""}"`
    );

    // Initialize repo for this session if needed
    if (sessionId && promptConfig) {
      if (!isSessionInitialized(sessionId)) {
        console.log(`[codex-adapter] Initializing session ${sessionId}`);

        this.currentGitRepo = promptConfig.repo || null;
        this.currentGithubToken = promptConfig.githubToken || null;

        if (this.currentGitRepo) {
          yield { type: "repoClone", stage: "cloning", repo: this.currentGitRepo, message: "Cloning repository..." };

          try {
            await setupRepository(
              this.currentGitRepo,
              WORKSPACE_DIR,
              sessionId,
              this.currentGithubToken || undefined
            );
            yield {
              type: "repoClone",
              stage: "done",
              repo: this.currentGitRepo,
              message: "Repository cloned successfully",
            };
          } catch (error) {
            yield {
              type: "repoClone",
              stage: "error",
              repo: this.currentGitRepo,
              message: `Failed to clone: ${error instanceof Error ? error.message : String(error)}`,
            };
          }
        }

        markSessionInitialized(sessionId);
      }
    }

    // Clear interrupt signal and reset state
    this.clearInterruptSignal();
    this.lastUsage = null;

    // Get or create Codex thread
    const existingThreadId = codexThreadMap.get(sessionId);

    try {
      if (existingThreadId) {
        console.log(`[codex-adapter] Resuming Codex thread: ${existingThreadId}`);
        this.thread = this.codex.resumeThread(existingThreadId, {
          workingDirectory: WORKSPACE_DIR,
          sandboxMode: "danger-full-access",
          approvalPolicy: "never",
          model: this.config?.model,
        });
      } else {
        console.log(`[codex-adapter] Creating new Codex thread`);
        this.thread = this.codex.startThread({
          workingDirectory: WORKSPACE_DIR,
          sandboxMode: "danger-full-access",
          approvalPolicy: "never",
          model: this.config?.model,
          skipGitRepoCheck: true, // We handle git setup ourselves
        });
      }
    } catch (error) {
      console.error("[codex-adapter] Failed to create/resume thread:", error);
      yield {
        type: "error",
        message: `Failed to create thread: ${error instanceof Error ? error.message : String(error)}`,
        retryable: true,
      };
      return;
    }

    try {
      // Run the prompt with streaming
      const { events } = await this.thread.runStreamed(text);

      for await (const event of events) {
        if (this.interruptSignal) {
          yield { type: "system", message: "interrupted" };
          return;
        }

        // Capture thread ID from first event
        if (event.type === "thread.started" && this.thread.id) {
          codexThreadMap.set(sessionId, this.thread.id);
        }

        // Track usage from turn.completed
        if (event.type === "turn.completed") {
          this.lastUsage = {
            inputTokens: event.usage.input_tokens,
            outputTokens: event.usage.output_tokens,
          };
        }

        // Translate and yield events
        const promptEvents = this.translateEvent(event);
        for (const pe of promptEvents) {
          yield pe;
        }
      }

      // Emit final result
      yield {
        type: "result",
        inputTokens: this.lastUsage?.inputTokens || 0,
        outputTokens: this.lastUsage?.outputTokens || 0,
        totalTurns: 1,
      };
    } catch (error) {
      console.error("[codex-adapter] Error during prompt execution:", error);
      yield {
        type: "error",
        message: `Prompt execution error: ${error instanceof Error ? error.message : String(error)}`,
        retryable: false,
      };
    }
  }

  /**
   * Translate Codex SDK events to PromptEvent format
   */
  private translateEvent(event: ThreadEvent): PromptEvent[] {
    // Log events for debugging
    console.log(`[codex-adapter] Event: ${event.type}`);

    switch (event.type) {
      case "item.started":
        return this.translateItemStarted(event.item);

      case "item.completed":
        return this.translateItemCompleted(event.item);

      case "item.updated":
        // Could handle todo list updates here
        return [];

      case "turn.started":
      case "turn.completed":
      case "thread.started":
        // Lifecycle events - no direct mapping needed
        return [];

      case "turn.failed":
        return [{
          type: "error",
          message: event.error.message || "Turn failed",
          retryable: false,
        }];

      case "error":
        return [{
          type: "error",
          message: event.message || "Unknown error",
          retryable: false,
        }];

      default:
        return [];
    }
  }

  /**
   * Translate item.started events
   */
  private translateItemStarted(item: ThreadItem): PromptEvent[] {
    switch (item.type) {
      case "command_execution":
        this.toolStartTimes.set(item.id, Date.now());
        return [{
          type: "toolStart",
          tool: "bash",
          toolUseId: item.id,
        }];

      case "file_change":
        this.toolStartTimes.set(item.id, Date.now());
        // Determine tool name based on change type
        const firstChange = item.changes[0];
        const toolName = firstChange?.kind === "add" ? "write" : "edit";
        return [{
          type: "toolStart",
          tool: toolName,
          toolUseId: item.id,
        }];

      case "mcp_tool_call":
        this.toolStartTimes.set(item.id, Date.now());
        return [{
          type: "toolStart",
          tool: item.tool,
          toolUseId: item.id,
        }];

      case "reasoning":
        // Generate thinking ID
        this.currentThinkingId = `thinking_${Date.now()}_${++this.thinkingIdCounter}`;
        return [{
          type: "thinking",
          thinkingId: this.currentThinkingId,
          content: item.text || "",
          partial: true,
        }];

      case "web_search":
        this.toolStartTimes.set(item.id, Date.now());
        return [{
          type: "toolStart",
          tool: "web_search",
          toolUseId: item.id,
        }];

      case "agent_message":
      case "todo_list":
      case "error":
        // These don't map to toolStart
        return [];

      default:
        return [];
    }
  }

  /**
   * Translate item.completed events
   */
  private translateItemCompleted(item: ThreadItem): PromptEvent[] {
    const startTime = this.toolStartTimes.get(item.id);
    const durationMs = startTime ? Date.now() - startTime : undefined;
    this.toolStartTimes.delete(item.id);

    switch (item.type) {
      case "command_execution":
        return [
          {
            type: "toolInputComplete",
            toolUseId: item.id,
            input: { command: item.command },
          },
          {
            type: "toolEnd",
            tool: "bash",
            toolUseId: item.id,
            result: item.aggregated_output || "",
            error: item.status === "failed" ? "Command failed" : undefined,
            ...(durationMs !== undefined && { durationMs }),
          },
        ];

      case "file_change":
        // Summarize changes
        const changesSummary = item.changes
          .map((c) => `${c.kind}: ${c.path}`)
          .join(", ");
        const firstChange = item.changes[0];
        const toolName = firstChange?.kind === "add" ? "write" : "edit";
        return [{
          type: "toolEnd",
          tool: toolName,
          toolUseId: item.id,
          result: changesSummary,
          error: item.status === "failed" ? "File change failed" : undefined,
          ...(durationMs !== undefined && { durationMs }),
        }];

      case "mcp_tool_call":
        return [{
          type: "toolEnd",
          tool: item.tool,
          toolUseId: item.id,
          result: item.result ? JSON.stringify(item.result) : undefined,
          error: item.error?.message,
          ...(durationMs !== undefined && { durationMs }),
        }];

      case "agent_message":
        // Final text response
        return [{
          type: "textDelta",
          content: item.text || "",
          partial: false,
        }];

      case "reasoning":
        // End of reasoning block
        const thinkingId = this.currentThinkingId || `thinking_${Date.now()}_${++this.thinkingIdCounter}`;
        this.currentThinkingId = null;
        return [{
          type: "thinking",
          thinkingId,
          content: item.text || "",
          partial: false,
        }];

      case "web_search":
        return [{
          type: "toolEnd",
          tool: "web_search",
          toolUseId: item.id,
          result: `Search: ${item.query}`,
          ...(durationMs !== undefined && { durationMs }),
        }];

      case "error":
        return [{
          type: "error",
          message: item.message,
          retryable: false,
        }];

      case "todo_list":
        // Could emit updates here if needed
        return [];

      default:
        return [];
    }
  }

  setInterruptSignal(): void {
    this.interruptSignal = true;
    console.log("[codex-adapter] Interrupt signal set");
  }

  clearInterruptSignal(): void {
    this.interruptSignal = false;
    this.toolStartTimes.clear();
  }

  isInterrupted(): boolean {
    return this.interruptSignal;
  }

  getCurrentGitRepo(): string | null {
    return this.currentGitRepo;
  }

  async shutdown(): Promise<void> {
    console.log("[codex-adapter] Shutting down...");
    this.thread = null;
    this.codex = null;
    codexThreadMap.clear();
    this.toolStartTimes.clear();
  }
}
