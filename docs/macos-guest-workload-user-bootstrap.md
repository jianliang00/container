# macOS Workload User Bootstrap Context

macOS workload processes can run as a non-root image user, such as `admin`.
For those processes, the effective uid/gid is not enough to reproduce a normal
user session. Some system frameworks resolve per-user state through the process
bootstrap namespace managed by `launchd`. Keychain Services is one visible
example: a process with `uid=501` can still use the System bootstrap namespace
and then `security find-identity` without an explicit keychain path reads the
System/root search list instead of the user's search list.

The guest agent therefore starts non-root workload commands in the target user's
bootstrap namespace before dropping privileges. This gives tools such as
`security`, `codesign`, and `xcodebuild` the same user-domain keychain view that
they get from a login-style user session.

## Runtime Flow

The guest agent is installed as a root LaunchDaemon inside the macOS guest. When
the runtime asks it to start a workload command, it resolves the target identity
from the exec request:

- root targets keep the original direct fork/exec path.
- non-root targets started by the root guest agent use `launchctl asuser <uid>`.

For a non-root target, the guest agent creates an anonymous temporary payload
file, writes the intended executable, arguments, environment, working directory,
uid, gid, and supplemental groups to it, and passes the open file descriptor to
an internal `exec-helper` subcommand. The helper runs under the target user's
bootstrap namespace while it is still root, then applies the requested groups,
gid, and uid, changes to the requested working directory, and executes the final
workload command.

The payload file is unlinked immediately after creation. Only the inherited file
descriptor remains visible to the helper. The existing startup status pipe is
kept open through `launchctl` and the helper, then marked close-on-exec just
before the final workload command is executed. This preserves the original
startup contract: exec failures are reported before the runtime sends the process
start acknowledgement.

## Expected Behavior

A healthy non-root workload process should report the target user from both
identity and launchd context:

```sh
id
launchctl manageruid
launchctl managername
```

For an `admin` workload, `id` should show `uid=501(admin)`,
`launchctl manageruid` should print `501`, and `launchctl managername` should
print `Background` or another user-domain manager name. A process that shows
`uid=501(admin)` but `launchctl manageruid` prints `0` is still running in the
System bootstrap namespace.

For keychain-sensitive build jobs, user-domain keychain commands should work
without passing the keychain path to every tool:

```sh
security list-keychains
security default-keychain
security find-identity -v -p codesigning
```

The list should include the user's keychain entries rather than only
`/Library/Keychains/System.keychain` and root's login keychain.

## Operational Notes

This runtime behavior does not install certificates or create build keychains.
Workloads that need signing material still create and unlock their own keychain
at build time. The runtime only ensures the process has the correct macOS user
bootstrap context so framework defaults resolve against the workload user.

If a signing job still cannot see identities, check these items in order:

1. The process user from `id`.
2. The launchd manager from `launchctl manageruid` and `launchctl managername`.
3. The user keychain search list from `security list-keychains -d user`.
4. The default search list from `security list-keychains`.
5. The explicit identity result from `security find-identity -v -p codesigning <keychain-path>`.

When the explicit keychain lookup succeeds but the default lookup fails, the
process is usually not running in the expected user bootstrap namespace.
