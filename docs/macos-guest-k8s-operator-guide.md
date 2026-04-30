# macOS Guest Kubernetes Operator Guide

This guide defines the first-rollout operator contract for using macOS hosts as
Kubernetes worker nodes. The control plane remains Linux.

## Scheduling Contract

macOS workloads must opt in. Ordinary Pods must not land on macOS nodes.

Required node labels:

```sh
kubectl label node <mac-node> \
  kubernetes.io/os=darwin \
  apple.com/macos-container=true \
  --overwrite
```

Required node taint:

```sh
kubectl taint node <mac-node> \
  apple.com/macos-container=true:NoSchedule \
  --overwrite
```

Required RuntimeClass:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: macos
handler: macos
scheduling:
  nodeSelector:
    kubernetes.io/os: darwin
    apple.com/macos-container: "true"
  tolerations:
    - key: apple.com/macos-container
      operator: Equal
      value: "true"
      effect: NoSchedule
```

Admission policy should enforce these rules:

- Pods selecting `kubernetes.io/os=darwin` must set `runtimeClassName: macos`.
- Pods using `runtimeClassName: macos` must not set `.spec.os.name`.
- Pods using `runtimeClassName: macos` must use a macOS workload image.
- Pods without the macOS RuntimeClass must not tolerate the macOS node taint.

The admission implementation can be the cluster's existing policy engine. The
contract above is the required behavior.

## Pod OS Contract

For the `v1.27.2` production baseline, macOS workload Pods must omit
`.spec.os.name`.

Do not set:

```yaml
spec:
  os:
    name: darwin
```

Do not set `linux` or `windows` for macOS workloads. The supported selection
signals are:

- `runtimeClassName: macos`
- `kubernetes.io/os=darwin`
- `apple.com/macos-container=true`
- the macOS node taint and matching toleration supplied by RuntimeClass
  scheduling

## API-Backed Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: macos-smoke
  labels:
    app: macos-smoke
spec:
  runtimeClassName: macos
  containers:
    - name: smoke
      image: ghcr.io/example/macos-smoke:26.3
      command: ["/bin/sh", "-lc"]
      args: ["sw_vers && sleep 3600"]
```

The Pod intentionally omits `.spec.os.name`; RuntimeClass scheduling carries the
node selector and taint toleration.

## Static Pod

Static Pods are placed directly on a macOS node by the local kubelet. They are
not scheduled by the control plane, so the macOS node label and RuntimeClass
scheduling rules do not select them.

Use a manifest like this in the kubelet static Pod path:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: macos-static-smoke
  namespace: default
spec:
  containers:
    - name: smoke
      image: ghcr.io/example/macos-smoke:26.3
      command: ["/bin/sh", "-lc"]
      args: ["sw_vers && sleep 3600"]
```

When the kubelet is connected to the API server and the RuntimeClass object is
available, static Pod manifests may set `runtimeClassName: macos`. Standalone
static Pod smoke tests should omit it and rely on the macOS-only CRI shim
configuration.

## First Rollout Workload Surface

The first production rollout supports a conservative macOS worker-node surface:

| Area | First rollout support |
| --- | --- |
| Control plane | Linux control plane only |
| Node role | macOS worker nodes only |
| Pod sources | API-backed Pods and kubelet static Pods |
| Pod shape | One macOS workload container per Pod for the production validation gate |
| Images | `darwin/arm64` macOS workload images |
| Logs | `kubectl logs` through CRI log adaptation |
| Exec | `kubectl exec` and CRI exec streaming |
| Port-forward | `kubectl port-forward` through the loopback streaming server |
| Probes | exec, HTTP, and TCP kubelet probes |
| Mounts | Supported CRI mount subset backed by boot-time `virtiofs` shares |
| Service | Single-node IPv4 ClusterIP TCP/UDP through `container-kube-proxy-macos`; production release is blocked until this passes real API server validation |
| NetworkPolicy | Not part of the first production rollout; keep disabled unless a separate validation effort promotes it |

Unsupported in the first production rollout:

- multi-node Service routing
- NodePort and LoadBalancer
- dual-stack Service routing
- session affinity
- Kubernetes NetworkPolicy
- Linux mount namespaces, cgroups, seccomp, user namespaces, and mount
  propagation semantics
