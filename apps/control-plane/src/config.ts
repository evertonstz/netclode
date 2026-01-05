export const config = {
  port: Number(process.env.PORT) || 3001,
  anthropicApiKey: process.env.ANTHROPIC_API_KEY || "",
  kubeconfig: process.env.KUBECONFIG || undefined,
  namespace: process.env.NAMESPACE || "default",
};
