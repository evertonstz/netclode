/**
 * GitHub Copilot SDK adapter
 */

export { CopilotAdapter } from "./adapter.js";
export {
  createTranslatorState,
  resetTranslatorState,
  translateEvent,
  translateSessionIdle,
  type TranslatorState,
  type CopilotEvent,
} from "./translator.js";
