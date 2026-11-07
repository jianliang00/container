# Native ASIF overlay probe

This standalone diagnostic requires macOS 27 at runtime. Xcode 27 and the macOS
27 SDK are required only on the build machine. The probe does not install a
runtime, start a VM, change a cluster, or upgrade macOS.

Build on a machine with the SDK, then copy the signed executable to the test Mac:

```sh
xcrun swiftc -O -target arm64-apple-macosx27.0 \
  scripts/macos-native-overlay-probe/Probe.swift -o native-overlay-probe
```

The dedicated GitHub Actions workflow uses `xcode-27`. It publishes a Developer
ID signed diagnostic artifact with a SHA-256 digest and build provenance. This
artifact is not a notarized production node package.

```sh
./native-overlay-probe self-test
./native-overlay-probe create-overlay /absolute/base.img /absolute/new-overlay.asif
./native-overlay-probe inspect-overlay /absolute/base.img /absolute/new-overlay.asif
```

`self-test` creates a private 64 MiB RAW fixture and ASIF overlay, constructs a VZ
storage attachment, closes and reopens the stack, checks that the base is
unchanged, and removes its fixture. Other commands retain the specified files.
Use only stopped, dedicated test images. A RAW base has no layer UUID; production
archive manifests must independently bind its content digest to the overlay.

Passing these checks establishes API availability and stack construction only.
Guest writes, flush and pause consistency, crash recovery, data corruption,
TOS archive round trips, and performance require separate VM validation.
