# macOS Guest Kubernetes Operator Guide

This guide defines the first-rollout operator contract for using macOS hosts as
Kubernetes worker nodes. The control plane remains Linux.

## Scheduling Contract

macOS workloads must opt in. Ordinary Pods must not land on macOS nodes.

`container-macos-kubeadm join` registers the node labels and taints that match
the selected network mode. Operators should not label or taint the node as a
separate deployment step.

Full-mode nodes are registered with these labels:

```text
kubernetes.io/os=darwin
node.kubernetes.io/macos=true
node.kubernetes.io/macos-network=full
```

Full-mode nodes are registered with this taint:

```text
node.kubernetes.io/macos=true:NoSchedule
```

Compat-mode nodes are registered with these labels:

```text
kubernetes.io/os=darwin
node.kubernetes.io/macos=true
node.kubernetes.io/macos-network=compat
```

Compat-mode nodes are registered with these taints:

```text
node.kubernetes.io/macos=true:NoSchedule
node.kubernetes.io/macos-network=compat:NoSchedule
```

Full-mode nodes use the `macos` RuntimeClass:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: macos
handler: macos
scheduling:
  nodeSelector:
    kubernetes.io/os: darwin
    node.kubernetes.io/macos: "true"
    node.kubernetes.io/macos-network: "full"
  tolerations:
    - key: node.kubernetes.io/macos
      operator: Equal
      value: "true"
      effect: NoSchedule
```

Older macOS hosts joined with `--network-mode compat` use the `macos-compat`
RuntimeClass:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: macos-compat
handler: macos-compat
scheduling:
  nodeSelector:
    kubernetes.io/os: darwin
    node.kubernetes.io/macos: "true"
    node.kubernetes.io/macos-network: "compat"
  tolerations:
    - key: node.kubernetes.io/macos
      operator: Equal
      value: "true"
      effect: NoSchedule
    - key: node.kubernetes.io/macos-network
      operator: Equal
      value: "compat"
      effect: NoSchedule
```

Admission policy should enforce these rules:

- Pods selecting `kubernetes.io/os=darwin` must set `runtimeClassName: macos`
  or `runtimeClassName: macos-compat`.
- Pods using a macOS RuntimeClass must not set `.spec.os.name`.
- Pods using a macOS RuntimeClass must use a macOS workload image.
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
- `runtimeClassName: macos-compat`
- `kubernetes.io/os=darwin`
- `node.kubernetes.io/macos=true`
- `node.kubernetes.io/macos-network=full`
- `node.kubernetes.io/macos-network=compat`
- the macOS node taint and matching toleration supplied by RuntimeClass
  scheduling

## Sandbox Image Selection

The default RuntimeClass for a joined node uses the sandbox image configured
with `container-macos-kubeadm join --sandbox-image`.

Operators can expose additional administrator-defined sandbox images by
repeating `--runtime-class <name>=<sandbox-image>` during join:

```sh
sudo container-macos-kubeadm join 10.0.0.10:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --node-name macos-node-1 \
  --network-mode compat \
  --runtime-class macos-15-2=ghcr.io/jianliang00/macos-base:15.2 \
  --runtime-class macos-15-4=ghcr.io/jianliang00/macos-base:15.4
```

Each additional RuntimeClass uses the node's selected network mode. Pods select
the desired sandbox image through `spec.runtimeClassName`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: macos-15-2-smoke
spec:
  runtimeClassName: macos-15-2
  containers:
    - name: smoke
      image: ghcr.io/example/macos-workload:15.2
      command: ["/bin/sh", "-lc"]
      args: ["sw_vers && sleep 3600"]
```

The CRI shim also accepts a Pod annotation override for the sandbox image:

```yaml
metadata:
  annotations:
    container-macos.io/sandbox-image: ghcr.io/jianliang00/macos-base:15.2
```

Clusters that expose this annotation to ordinary workload authors should
enforce their own admission policy for accepted sandbox images and callers.

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

Compat-mode Pods use `runtimeClassName: macos-compat` and the same Pod OS
contract:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: macos-compat-smoke
  labels:
    app: macos-compat-smoke
spec:
  runtimeClassName: macos-compat
  containers:
    - name: smoke
      image: ghcr.io/example/macos-workload:15.2
      command: ["/bin/sh", "-lc"]
      args: ["sw_vers && sleep 3600"]
```

Compat-mode Pods have NAT egress only. They do not have a real Pod IP, ClusterIP
Service semantics, NetworkPolicy, or inbound Service reachability.

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
available, static Pod manifests may set `runtimeClassName: macos` on full-mode
nodes or `runtimeClassName: macos-compat` on compat-mode nodes. Standalone
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
| Service | Full mode supports the kube-proxy-backed Service surface validated for the release. Compat mode does not provide ClusterIP or inbound Service semantics |
| NetworkPolicy | Full mode may enable a separately validated implementation. Compat mode does not provide NetworkPolicy |

Unsupported in the first production rollout:

- multi-node Service routing
- NodePort and LoadBalancer
- dual-stack Service routing
- session affinity
- Kubernetes NetworkPolicy
- Linux mount namespaces, cgroups, seccomp, user namespaces, and mount
  propagation semantics
