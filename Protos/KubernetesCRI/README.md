# Kubernetes CRI Proto Source

This directory contains the pinned Kubernetes CRI protobuf used to generate the
`ContainerCRI` Swift bindings.

- Upstream repository: <https://github.com/kubernetes/cri-api>
- Pinned tag: `v0.35.3`
- Upstream path: `pkg/apis/runtime/v1/api.proto`
- Regeneration command: `make cri-protos`

The generated Swift files live in `Sources/ContainerCRI` and should not be
edited by hand.
