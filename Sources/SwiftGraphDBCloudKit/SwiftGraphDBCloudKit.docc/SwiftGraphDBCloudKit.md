# ``SwiftGraphDBCloudKit``

Reference CloudKit adapter for SwiftGraphDB's sync protocol.

## Overview

`SwiftGraphDBCloudKit` is a separate Swift Package product. The core engine ``SwiftGraphDB``
has no CloudKit dependency; apps that don't ship with iCloud can leave this package out
entirely. Apps that do ship with iCloud add a single import to flip on cross-device sync.

## Topics

### Getting started

- <doc:EnablingCloudKitSync>

### Conflict and offline handling

- <doc:ConflictResolution>
- <doc:OfflineBehaviour>

### Public types

- ``CloudKitGraphSyncTransport``
- ``CloudKitDatabase``
- ``CloudKitAccountStatusProbe``
- ``RecordCodec``
- ``CloudKitTransportError``
- ``CloudKitAccountError``
- ``CloudKitConfigurationError``

## See also

- [SPEC.md §11](https://github.com/DevKang/SwiftGraphDB/blob/main/SPEC.md) — sync protocol and
  CloudKit adapter notes.
- [README.md](https://github.com/DevKang/SwiftGraphDB/blob/main/README.md) — installation,
  examples, design rationale.
- [CHANGELOG.md](https://github.com/DevKang/SwiftGraphDB/blob/main/CHANGELOG.md) — release notes.
- [CONTRIBUTING.md](https://github.com/DevKang/SwiftGraphDB/blob/main/CONTRIBUTING.md) — how
  to file bugs and submit PRs.
