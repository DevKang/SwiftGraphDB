# Changelog

All notable changes to the SwiftGraphDB documentation and architecture plan will be recorded in this file.

This project follows the spirit of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and uses semantic versioning once public releases begin.

---

## [Unreleased]

### Added

- _(nothing yet — post-0.1.0 work lands here)_

## [0.1.0] - 2026-05-02

First public release. The core graph engine, query layer, sync protocol, and CloudKit
reference adapter are all considered Stable for the 0.1.x line. See
[`Scripts/public-api-allowlist.txt`](Scripts/public-api-allowlist.txt) for the frozen
public surface and the SwiftGraphDB / SwiftGraphDBCloudKit DocC catalogs for documentation.

### Added

- Added a backend-agnostic sync protocol direction for the core package.
- Added `GraphChange` as the canonical change model for sync adapters.
- Added `GraphSyncTransport` as the minimal transport boundary:
  - `push(_:)`
  - `pull(since:)`
  - opaque backend checkpoints
- Added `GraphConflictResolver` and built-in resolver policy direction:
  - remote-wins
  - local-wins
  - field-level merge
  - explicit delete/update conflict handling
- Added a core `change_journal` concept backed by SQLite.
- Added generic sync tables:
  - `sync_checkpoints`
  - `sync_record_versions`
- Added package boundary guidance:
  - `SwiftGraphDB` for local graph engine and sync protocol types
  - `SwiftGraphDBCloudKit` for CloudKit reference adapter
  - possible future REST, Firebase, Supabase, and custom adapters
- Added adapter contract testing requirements.
- Added multi-device sync simulation guidance using an in-memory backend.
- Added explicit revision model direction using `(actorID, counter, wallClock)`.
- Added sync protocol versioning and payload format versioning guidance.

### Changed

- Repositioned SwiftGraphDB as a local-first embedded graph database with pluggable sync, not as a CloudKit-first graph database.
- Changed README architecture diagram to include:
  - change journal
  - sync protocol boundary
  - optional adapter packages
- Changed Quick Start to remain local-only.
- Changed CloudKit usage from a core feature to a separate reference adapter package.
- Changed sync language from "Sync Layer" to "Sync Protocol".
- Changed persistence schema guidance from CloudKit-specific `sync_metadata` to backend-neutral sync metadata.
- Changed conflict resolution from CloudKit `serverRecordChanged` terminology to backend-neutral three-way graph record merge terminology.
- Changed performance language to treat sync as background and non-blocking rather than CloudKit-specific.
- Changed README Requirements to distinguish core package requirements from CloudKit adapter requirements.
- Changed contributing guidance to include sync adapter contract tests and in-memory fake backend tests.

### Removed

- Removed CloudKit-specific schema details from the core SPEC.
- Removed `CKRecord`, `CKRecordZone`, CloudKit change token, and `CKSyncEngine` concepts from the core API design.
- Removed `enableCloudKitSync(...)` from the core README examples.
- Removed the implication that CloudKit is required for SwiftGraphDB's identity or adoption.

### Migration Notes

- Replace core sync APIs shaped like this:

```swift
try await graph.enableCloudKitSync(container: .default)
```

with adapter-based sync:

```swift
let transport = CloudKitGraphSyncTransport(
    container: .default,
    databaseScope: .private,
    zoneName: "graphdb-private"
)

try await graph.enableSync(
    transport: transport,
    resolver: .fieldLevelMerge()
)
```

- Move CloudKit-specific metadata into the CloudKit adapter package.
- Keep `GraphChange`, `GraphRevision`, `SyncCheckpoint`, and `GraphConflictResolver` in the core package unless a future package split creates `SwiftGraphDBSync`.
- Treat delete/update conflicts as explicit product decisions. Do not silently choose delete-wins or remote-wins without an app-level policy.

### Rationale

The new direction keeps the core graph engine small and backend-independent while preserving a strong sync story. This mirrors successful local-first systems where the core data model and change protocol are independent from concrete networking and storage providers.

CloudKit remains important for Apple-first apps, but it should be a reference adapter rather than a core dependency.
