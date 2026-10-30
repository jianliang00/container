# macOS cold disk bundle import

The host storage controller may restore a VM from a complete local disk bundle.
The runtime only imports host files; it does not implement an object store,
snapshot catalog, retention policy, or storage service credentials.

Enable `machineState.enabled` and `machineState.localDiskEnabled` in the CRI node
policy. The latter defaults to false. Keep node support enabled until all VMs
using it have retired; admission rollout belongs to the storage controller.

Verbose CRI Status advertises `container.macos.local-disk.v1` with
`schemaVersion=1`, `bundleImport=true`, `activeIdentityImport=true` and the effective `enabled` policy. A host
controller must check this capability before advertising local restore support.

The existing annotation prefix is
`io.container.runtime.macos.machine-state.v1/`. Local disk configuration uses:

| Annotation suffix | Meaning |
|---|---|
| `enabled=true` | Enable the managed lifecycle and stable persistence lease |
| `persistence-id` | Stable, node-policy-validated VM binding |
| `storage-generation` | Positive writable disk generation |
| `storage-kind=local-disk` | Use the normal local disk attachment |
| `disk-bundle-digest` | Optional lowercase SHA-256 of the exact bundle manifest bytes |

Without `disk-bundle-digest`, the runtime prepares the VM from its OCI image.
With it, the trusted storage controller must publish the following directory
before Pod creation:

```text
<machineState.storageRoot>/<persistence-id>/disks/g<storage-generation>/
  disk-bundle.json
  Disk.img
  AuxiliaryStorage
  HardwareModel.bin
  MachineIdentifier.bin
```

The root comes from node policy. An annotation cannot supply a host file path.
This cold import cannot be combined with external block devices or a saved
machine-state restore. Existing NBD configuration remains supported.

The manifest has this minimum schema; controllers may add their own metadata:

```json
{
  "version": 1,
  "persistenceID": "vm-example",
  "storageGeneration": 2,
  "files": [
    {"name": "Disk.img", "size": 68719476736},
    {"name": "AuxiliaryStorage", "size": 1048576},
    {"name": "HardwareModel.bin", "size": 80},
    {"name": "MachineIdentifier.bin", "size": 20}
  ]
}
```

The file order and names are fixed, sizes must match the actual files, and
directories must have trusted owners and no untrusted writable parents or
symlinks. Files must be regular files owned by the runtime user and must not be
writable by other users. The controller verifies download integrity and publishes
the completed bundle atomically before providing its manifest digest.

On APFS the runtime clones all four files into its separate VM directory. It
also installs `MachineIdentifier.bin` and `AuxiliaryStorage` into
`<machineState.storageRoot>/<persistence-id>/Identity/`, the active platform
state used by the sidecar. A snapshot producer must capture these two active
files, rather than the VM image's template firmware. An existing active machine
identifier must match the incoming bundle; an unrelated identity is rejected.
The import marker is committed only after both directories are synchronized.
After that commit, restarts validate the active identity without replacing its
firmware, preserving changes made by the running VM.

The runtime
does not overwrite an unrelated existing disk. An import marker binds retries
to the same digest. Once startup and the controller's readiness checks succeed,
the controller may remove the staging bundle. Subsequent runtime restarts use
the imported writable files and marker without requiring staging to remain.

The bundle contains no memory state. Guest processes restart on cold boot.
Node compatibility, source-VM retirement and scheduling remain the controller's
responsibility. A manifest hash by itself is not proof that the source VM has
stopped or that downloaded file contents were authenticated.
