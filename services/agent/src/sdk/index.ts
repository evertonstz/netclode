/**
 * SDK Abstraction Layer
 *
 * Exports all SDK-related types and functions
 */

export type { SDKAdapter, SDKConfig, PromptConfig, PromptEvent, SdkType, CopilotBackend } from "./types.js";
export { createSDKAdapter, parseSdkType, getAdapter, shutdownAllAdapters } from "./factory.js";
export { ClaudeSDKAdapter } from "./claude-adapter.js";
export { OpenCodeAdapter } from "./opencode-adapter.js";
export { CopilotAdapter } from "./copilot-adapter.js";
