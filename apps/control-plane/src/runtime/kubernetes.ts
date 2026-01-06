/**
 * Kubernetes runtime using agent-sandbox CRDs
 *
 * Uses SandboxClaim to consume from SandboxWarmPool for fast startup
 */
import * as k8s from "@kubernetes/client-node";

// Use getter to ensure env var is read at runtime, not bundle time
function getNamespace(): string {
  const ns = process.env.K8S_NAMESPACE || "netclode";
  return ns;
}

const SANDBOX_TEMPLATE = "netclode-agent";

export interface VMConfig {
  sessionId: string;
  cpus?: number;
  memoryMB?: number;
  image?: string;
  env?: Record<string, string>;
}

export interface VMInfo {
  id: string;
  name: string;
  status: string;
  serviceFQDN?: string;
}

interface SandboxClaimStatus {
  conditions?: k8s.V1Condition[];
  sandbox?: {
    Name: string;
  };
}

interface SandboxStatus {
  serviceFQDN?: string;
  conditions?: k8s.V1Condition[];
}

export class KubernetesRuntime {
  private kc: k8s.KubeConfig;
  private customApi: k8s.CustomObjectsApi;
  private coreApi: k8s.CoreV1Api;

  constructor() {
    this.kc = new k8s.KubeConfig();

    // Load config from default locations (in-cluster or KUBECONFIG env)
    if (process.env.KUBERNETES_SERVICE_HOST) {
      this.kc.loadFromCluster();
    } else {
      this.kc.loadFromDefault();
    }

    this.customApi = this.kc.makeApiClient(k8s.CustomObjectsApi);
    this.coreApi = this.kc.makeApiClient(k8s.CoreV1Api);
  }

  /**
   * Create a new sandbox claim for a session
   * Uses SandboxClaim to consume from warm pool for fast startup
   */
  async createSandbox(vmConfig: VMConfig): Promise<string> {
    const { sessionId } = vmConfig;
    const name = `sess-${sessionId}`;

    // Create SandboxClaim - controller will assign a warm sandbox
    const claim = {
      apiVersion: "extensions.agents.x-k8s.io/v1alpha1",
      kind: "SandboxClaim",
      metadata: {
        name,
        namespace: getNamespace(),
        labels: {
          "netclode.io/session": sessionId,
        },
      },
      spec: {
        sandboxTemplateRef: {
          name: SANDBOX_TEMPLATE,
        },
      },
    };

    await this.customApi.createNamespacedCustomObject({
      group: "extensions.agents.x-k8s.io",
      version: "v1alpha1",
      namespace: getNamespace(),
      plural: "sandboxclaims",
      body: claim,
    });

    console.log(`[${sessionId}] SandboxClaim created: ${name}`);
    return name;
  }

  /**
   * Get sandbox status by session ID
   * First gets the claim, then the assigned sandbox
   */
  async getSandboxStatus(sessionId: string): Promise<VMInfo | null> {
    const claimName = `sess-${sessionId}`;

    try {
      // Get the SandboxClaim
      const claim = (await this.customApi.getNamespacedCustomObject({
        group: "extensions.agents.x-k8s.io",
        version: "v1alpha1",
        namespace: getNamespace(),
        plural: "sandboxclaims",
        name: claimName,
      })) as {
        metadata: k8s.V1ObjectMeta;
        status?: SandboxClaimStatus;
      };

      // Check if claim is bound to a sandbox
      const sandboxName = claim.status?.sandbox?.Name;
      if (!sandboxName) {
        return {
          id: claimName,
          name: claimName,
          status: this.mapConditionsToStatus(claim.status?.conditions),
        };
      }

      // Get the assigned Sandbox to get serviceFQDN
      const sandbox = (await this.customApi.getNamespacedCustomObject({
        group: "agents.x-k8s.io",
        version: "v1alpha1",
        namespace: getNamespace(),
        plural: "sandboxes",
        name: sandboxName,
      })) as {
        metadata: k8s.V1ObjectMeta;
        status?: SandboxStatus;
      };

      return {
        id: claimName,
        name: sandboxName,
        status: this.mapConditionsToStatus(sandbox.status?.conditions),
        serviceFQDN: sandbox.status?.serviceFQDN,
      };
    } catch (e: unknown) {
      const error = e as { response?: { statusCode?: number } };
      if (error.response?.statusCode === 404) {
        return null;
      }
      throw e;
    }
  }

  /**
   * Delete a sandbox claim by session ID
   */
  async deleteSandbox(sessionId: string): Promise<void> {
    const name = `sess-${sessionId}`;

    // Delete SandboxClaim - controller handles sandbox cleanup
    try {
      await this.customApi.deleteNamespacedCustomObject({
        group: "extensions.agents.x-k8s.io",
        version: "v1alpha1",
        namespace: getNamespace(),
        plural: "sandboxclaims",
        name,
      });
    } catch (e: unknown) {
      const error = e as { response?: { statusCode?: number } };
      if (error.response?.statusCode !== 404) {
        throw e;
      }
    }

    console.log(`[${sessionId}] SandboxClaim deleted`);
  }

  /**
   * Wait for sandbox to be ready and return service FQDN
   */
  async waitForReady(sessionId: string, timeoutMs = 120000): Promise<string | null> {
    const startTime = Date.now();
    const checkInterval = 1000; // Check every second for faster response

    while (Date.now() - startTime < timeoutMs) {
      const info = await this.getSandboxStatus(sessionId);

      if (info?.status === "ready" && info.serviceFQDN) {
        // Try to reach the agent health endpoint
        try {
          const response = await fetch(`http://${info.serviceFQDN}:3002/health`, {
            signal: AbortSignal.timeout(2000),
          });
          if (response.ok) {
            console.log(`[${sessionId}] Agent ready at ${info.serviceFQDN}`);
            return info.serviceFQDN;
          }
        } catch {
          // Not ready yet
        }
      }

      await new Promise((resolve) => setTimeout(resolve, checkInterval));
    }

    console.error(`[${sessionId}] Timeout waiting for agent to be ready`);
    return null;
  }

  /**
   * List all sandbox claims
   */
  async listSandboxes(): Promise<VMInfo[]> {
    const list = (await this.customApi.listNamespacedCustomObject({
      group: "extensions.agents.x-k8s.io",
      version: "v1alpha1",
      namespace: getNamespace(),
      plural: "sandboxclaims",
      labelSelector: "netclode.io/session",
    })) as {
      items: Array<{
        metadata: k8s.V1ObjectMeta;
        status?: SandboxClaimStatus;
      }>;
    };

    return list.items.map((item) => ({
      id: item.metadata.name || "",
      name: item.metadata.name || "",
      status: this.mapConditionsToStatus(item.status?.conditions),
    }));
  }

  /**
   * Check if sandbox is running
   */
  async isSandboxRunning(sessionId: string): Promise<boolean> {
    const info = await this.getSandboxStatus(sessionId);
    return info?.status === "ready";
  }

  private mapConditionsToStatus(conditions?: k8s.V1Condition[]): string {
    if (!conditions?.length) return "pending";

    const ready = conditions.find((c) => c.type === "Ready");
    if (ready?.status === "True") return "ready";
    if (ready?.status === "False") return "error";

    return "creating";
  }
}

// Export singleton instance
export const kubernetesRuntime = new KubernetesRuntime();
