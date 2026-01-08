import { readFileSync, existsSync } from "fs";
import { join } from "path";

// Load .env from root if exists
function loadEnv() {
  const envPaths = [
    join(process.cwd(), ".env"),
    join(process.cwd(), "../..", ".env"),
    join(process.cwd(), "../../..", ".env"),
  ];

  for (const envPath of envPaths) {
    if (existsSync(envPath)) {
      const content = readFileSync(envPath, "utf-8");
      for (const line of content.split("\n")) {
        const match = line.match(/^([^=]+)=(.*)$/);
        if (match && !process.env[match[1]]) {
          process.env[match[1]] = match[2];
        }
      }
      break;
    }
  }
}

loadEnv();

export const config = {
  anthropicApiKey: process.env.ANTHROPIC_API_KEY || "",
  sessionId: process.env.SESSION_ID || "",
  workspacePath: process.env.WORKSPACE_PATH || "/tmp/workspace",
  port: parseInt(process.env.AGENT_PORT || "3002", 10),
};

if (!config.anthropicApiKey) {
  console.error("Warning: ANTHROPIC_API_KEY not set");
}
