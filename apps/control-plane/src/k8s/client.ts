import * as k8s from "@kubernetes/client-node";

const kc = new k8s.KubeConfig();

// Load config from cluster (in-cluster) or default kubeconfig
if (process.env.KUBERNETES_SERVICE_HOST) {
  kc.loadFromCluster();
} else {
  kc.loadFromDefault();
}

export const coreApi = kc.makeApiClient(k8s.CoreV1Api);
export const exec = new k8s.Exec(kc);
export const kubeConfig = kc;

export const NAMESPACE = process.env.NAMESPACE || "netclode";
