import { config } from "./config";
import { spawn } from "bun";

const server = Bun.serve({
  port: config.port || 3002,
  async fetch(req) {
    const url = new URL(req.url);

    // Health check
    if (url.pathname === "/health") {
      return new Response("ok");
    }

    // Handle prompt requests
    if (url.pathname === "/prompt" && req.method === "POST") {
      const body = (await req.json()) as { sessionId: string; text: string };
      const { text } = body;
      console.error(`[prompt] Received: ${text.slice(0, 50)}...`);

      // Spawn subprocess to run SDK (avoids Bun.serve event loop issues)
      const proc = spawn({
        cmd: ["bun", "run", `${import.meta.dir}/run-prompt.ts`],
        stdin: "pipe",
        stdout: "pipe",
        stderr: "inherit",
        env: { ...process.env, WORKSPACE: config.workspacePath },
      });

      // Send prompt to subprocess
      proc.stdin.write(JSON.stringify({ text }) + "\n");
      proc.stdin.end();

      // Stream stdout as SSE
      return new Response(proc.stdout, {
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          Connection: "keep-alive",
        },
      });
    }

    // Interrupt (TODO: implement process killing)
    if (url.pathname === "/interrupt" && req.method === "POST") {
      return new Response(JSON.stringify({ ok: true }));
    }

    return new Response("Not found", { status: 404 });
  },
});

console.log(`Agent server listening on http://localhost:${server.port}`);
