#!/usr/bin/env node
import { connectToControlPlane } from "./connect-client.js";

const controlPlaneUrl = process.env.CONTROL_PLANE_URL || "http://control-plane.netclode.svc.cluster.local";
const sessionId = process.env.SESSION_ID;

if (!sessionId) {
  console.error("[agent] SESSION_ID environment variable is required");
  process.exit(1);
}

console.log("[agent] Starting agent...");
console.log(`[agent] Config: controlPlaneUrl=${controlPlaneUrl}, sessionId=${sessionId}`);
console.log(`[agent] Environment: ANTHROPIC_API_KEY=${process.env.ANTHROPIC_API_KEY ? "set" : "NOT SET"}`);

// Connect to control plane
async function main() {
  try {
    await connectToControlPlane(controlPlaneUrl, sessionId!);
  } catch (error) {
    console.error("[agent] Failed to connect to control plane:", error);
    process.exit(1);
  }
}

main();
