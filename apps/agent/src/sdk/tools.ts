import type Anthropic from "@anthropic-ai/sdk";
import { readFileSync, writeFileSync, existsSync } from "fs";
import { spawn } from "child_process";
import { config } from "../config";

export const TOOL_DEFINITIONS: Anthropic.Tool[] = [
  {
    name: "bash",
    description: "Execute a bash command and return the output",
    input_schema: {
      type: "object" as const,
      properties: {
        command: {
          type: "string",
          description: "The bash command to execute",
        },
      },
      required: ["command"],
    },
  },
  {
    name: "read_file",
    description: "Read the contents of a file",
    input_schema: {
      type: "object" as const,
      properties: {
        path: {
          type: "string",
          description: "The path to the file to read",
        },
      },
      required: ["path"],
    },
  },
  {
    name: "write_file",
    description: "Write content to a file",
    input_schema: {
      type: "object" as const,
      properties: {
        path: {
          type: "string",
          description: "The path to the file to write",
        },
        content: {
          type: "string",
          description: "The content to write to the file",
        },
      },
      required: ["path", "content"],
    },
  },
  {
    name: "list_files",
    description: "List files in a directory",
    input_schema: {
      type: "object" as const,
      properties: {
        path: {
          type: "string",
          description: "The directory path to list",
        },
      },
      required: ["path"],
    },
  },
];

export async function executeToolCall(
  name: string,
  input: Record<string, unknown>
): Promise<string> {
  switch (name) {
    case "bash":
      return executeBash(input.command as string);
    case "read_file":
      return readFile(input.path as string);
    case "write_file":
      return writeFile(input.path as string, input.content as string);
    case "list_files":
      return listFiles(input.path as string);
    default:
      return `Unknown tool: ${name}`;
  }
}

async function executeBash(command: string): Promise<string> {
  return new Promise((resolve) => {
    const proc = spawn("bash", ["-c", command], {
      cwd: config.workspacePath,
      timeout: 30000,
    });

    let stdout = "";
    let stderr = "";

    proc.stdout.on("data", (data) => {
      stdout += data.toString();
    });

    proc.stderr.on("data", (data) => {
      stderr += data.toString();
    });

    proc.on("close", (code) => {
      const output = stdout + (stderr ? `\nStderr: ${stderr}` : "");
      resolve(code === 0 ? output : `Exit code ${code}\n${output}`);
    });

    proc.on("error", (err) => {
      resolve(`Error: ${err.message}`);
    });
  });
}

function readFile(path: string): string {
  try {
    const fullPath = path.startsWith("/") ? path : `${config.workspacePath}/${path}`;
    if (!existsSync(fullPath)) {
      return `Error: File not found: ${fullPath}`;
    }
    return readFileSync(fullPath, "utf-8");
  } catch (err) {
    return `Error reading file: ${err instanceof Error ? err.message : String(err)}`;
  }
}

function writeFile(path: string, content: string): string {
  try {
    const fullPath = path.startsWith("/") ? path : `${config.workspacePath}/${path}`;
    writeFileSync(fullPath, content, "utf-8");
    return `Successfully wrote to ${fullPath}`;
  } catch (err) {
    return `Error writing file: ${err instanceof Error ? err.message : String(err)}`;
  }
}

function listFiles(path: string): string {
  try {
    const fullPath = path.startsWith("/") ? path : `${config.workspacePath}/${path}`;
    const { readdirSync } = require("fs");
    const files = readdirSync(fullPath);
    return files.join("\n");
  } catch (err) {
    return `Error listing files: ${err instanceof Error ? err.message : String(err)}`;
  }
}
