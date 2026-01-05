import * as k8s from "@kubernetes/client-node";
import { coreApi, NAMESPACE } from "./client";

export interface SandboxSpec {
  sessionId: string;
  runtimeClass?: string;
  resources?: {
    memory?: string;
    cpu?: string;
  };
}

const AGENT_IMAGE = process.env.AGENT_IMAGE || "ghcr.io/netclode/agent:latest";

export async function createSandbox(spec: SandboxSpec): Promise<k8s.V1Pod> {
  const { sessionId, runtimeClass = "kata-fc", resources } = spec;

  // Create PVC for workspace
  const pvc: k8s.V1PersistentVolumeClaim = {
    apiVersion: "v1",
    kind: "PersistentVolumeClaim",
    metadata: {
      name: `session-${sessionId}-workspace`,
      namespace: NAMESPACE,
      labels: {
        app: "agent",
        "netclode.io/session": sessionId,
      },
    },
    spec: {
      accessModes: ["ReadWriteOnce"],
      resources: {
        requests: {
          storage: "10Gi",
        },
      },
    },
  };

  try {
    await coreApi.createNamespacedPersistentVolumeClaim({
      namespace: NAMESPACE,
      body: pvc,
    });
  } catch (e: any) {
    // Ignore if already exists
    if (e.response?.statusCode !== 409) throw e;
  }

  // Create agent pod
  const pod: k8s.V1Pod = {
    apiVersion: "v1",
    kind: "Pod",
    metadata: {
      name: `session-${sessionId}`,
      namespace: NAMESPACE,
      labels: {
        app: "agent",
        "netclode.io/session": sessionId,
      },
    },
    spec: {
      runtimeClassName: runtimeClass,
      restartPolicy: "Never",
      terminationGracePeriodSeconds: 30,
      containers: [
        {
          name: "agent",
          image: AGENT_IMAGE,
          workingDir: "/workspace",
          ports: [
            {
              containerPort: 3002,
              name: "http",
            },
          ],
          readinessProbe: {
            httpGet: {
              path: "/health",
              port: 3002,
            },
            initialDelaySeconds: 5,
            periodSeconds: 5,
          },
          env: [
            { name: "SESSION_ID", value: sessionId },
            { name: "WORKSPACE_PATH", value: "/workspace" },
            {
              name: "ANTHROPIC_API_KEY",
              valueFrom: {
                secretKeyRef: {
                  name: "anthropic-credentials",
                  key: "ANTHROPIC_API_KEY",
                },
              },
            },
          ],
          resources: {
            requests: {
              memory: resources?.memory || "512Mi",
              cpu: resources?.cpu || "250m",
            },
            limits: {
              memory: "2Gi",
              cpu: "2000m",
            },
          },
          volumeMounts: [
            {
              name: "workspace",
              mountPath: "/workspace",
            },
          ],
          securityContext: {
            runAsUser: 1000,
            runAsGroup: 1000,
          },
        },
      ],
      volumes: [
        {
          name: "workspace",
          persistentVolumeClaim: {
            claimName: `session-${sessionId}-workspace`,
          },
        },
      ],
    },
  };

  const response = await coreApi.createNamespacedPod({
    namespace: NAMESPACE,
    body: pod,
  });

  return response;
}

export async function deleteSandbox(sessionId: string): Promise<void> {
  const podName = `session-${sessionId}`;
  const pvcName = `session-${sessionId}-workspace`;

  // Delete pod
  try {
    await coreApi.deleteNamespacedPod({
      name: podName,
      namespace: NAMESPACE,
    });
  } catch (e: any) {
    if (e.response?.statusCode !== 404) throw e;
  }

  // Note: PVC is kept for session resume. Delete manually if needed.
}

export async function deleteSandboxWithStorage(sessionId: string): Promise<void> {
  await deleteSandbox(sessionId);

  const pvcName = `session-${sessionId}-workspace`;

  // Delete PVC
  try {
    await coreApi.deleteNamespacedPersistentVolumeClaim({
      name: pvcName,
      namespace: NAMESPACE,
    });
  } catch (e: any) {
    if (e.response?.statusCode !== 404) throw e;
  }
}

export async function getSandboxStatus(sessionId: string): Promise<string | null> {
  const podName = `session-${sessionId}`;

  try {
    const pod = await coreApi.readNamespacedPodStatus({
      name: podName,
      namespace: NAMESPACE,
    });
    return pod.status?.phase || null;
  } catch (e: any) {
    if (e.response?.statusCode === 404) return null;
    throw e;
  }
}

export async function waitForSandboxReady(
  sessionId: string,
  timeoutMs: number = 60000
): Promise<boolean> {
  const podName = `session-${sessionId}`;
  const startTime = Date.now();

  while (Date.now() - startTime < timeoutMs) {
    try {
      const pod = await coreApi.readNamespacedPodStatus({
        name: podName,
        namespace: NAMESPACE,
      });

      const phase = pod.status?.phase;
      if (phase === "Running") {
        // Check if container is ready
        const containerStatus = pod.status?.containerStatuses?.[0];
        if (containerStatus?.ready) {
          return true;
        }
      } else if (phase === "Failed" || phase === "Succeeded") {
        return false;
      }
    } catch (e: any) {
      if (e.response?.statusCode !== 404) throw e;
    }

    await new Promise((r) => setTimeout(r, 1000));
  }

  return false;
}
