import { createAgent } from "./sdk/agent";
import { config } from "./config";

const agent = createAgent();

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

      // Stream response via SSE
      const stream = new ReadableStream({
        async start(controller) {
          const encoder = new TextEncoder();
          const send = (data: object) => {
            controller.enqueue(encoder.encode(`data: ${JSON.stringify(data)}\n\n`));
          };

          // Capture emitted events by temporarily replacing emit
          const originalWrite = process.stdout.write.bind(process.stdout);
          process.stdout.write = (chunk: any) => {
            try {
              const msg = JSON.parse(chunk.toString().trim());
              send(msg);
            } catch {
              // Not JSON, ignore
            }
            return true;
          };

          try {
            await agent.run(text);
          } finally {
            process.stdout.write = originalWrite;
            controller.close();
          }
        },
      });

      return new Response(stream, {
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          Connection: "keep-alive",
        },
      });
    }

    // Interrupt
    if (url.pathname === "/interrupt" && req.method === "POST") {
      agent.interrupt();
      return new Response(JSON.stringify({ ok: true }));
    }

    return new Response("Not found", { status: 404 });
  },
});

console.log(`Agent server listening on http://localhost:${server.port}`);
