// Emit events to control plane via stdout (JSON lines)
export function emit(type: string, data: Record<string, unknown>) {
  const message = JSON.stringify({ type, ...data });
  // Use process.stdout.write directly to avoid buffering issues in piped mode
  process.stdout.write(message + "\n");
}
