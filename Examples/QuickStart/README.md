# SwiftGraphDB QuickStart

A minimal SwiftUI app that exercises SwiftGraphDB's public API end to end. It is intentionally
a separate Swift Package (`Examples/QuickStart/Package.swift`) so SwiftPM consumers of
`SwiftGraphDB` don't pick it up.

## What it shows

- Opens an in-memory `GraphStore`, seeds three people and three `KNOWS` edges.
- Lists every node labeled `Person` in a sidebar.
- Selecting a person runs a 1-hop `traverse(direction: .outgoing, edgeType: "KNOWS")` and
  renders the neighbours.
- A toggle pairs the primary store with a second in-memory store via `InMemorySyncBackend` +
  `FieldLevelMergeResolver`, so you can watch the public sync API converge two stores in the
  same process — no CloudKit entitlements required.

## Run it

### macOS — quickest path

```bash
cd Examples/QuickStart
swift run QuickStart
```

A native window opens with the seeded graph. The `init()` on `QuickStartApp` calls
`NSApplication.setActivationPolicy(.regular)` so the executable surfaces as a regular app
instead of a background process.

### macOS — from Xcode

1. `File ▸ Open…` and select the `Examples/QuickStart` folder (the one with `Package.swift`).
2. Wait for SwiftPM resolution.
3. Pick the `QuickStart` scheme and the `My Mac` run destination.
4. ⌘R.

### iOS Simulator

SwiftPM executable products do not deploy to iOS Simulator on their own — Xcode needs an
iOS app target to install a `.app` bundle. To try the sample on iOS:

1. Create a new Xcode iOS App project anywhere.
2. `File ▸ Add Package Dependencies…` and add SwiftGraphDB (use `Add Local…` and point at
   the `SwiftGraphDB` repository root, or use the public URL once it's published).
3. Replace the generated `App.swift` and `ContentView.swift` with the contents of
   [`QuickStartApp.swift`](Sources/QuickStart/QuickStartApp.swift). Drop the
   `init()` block — iOS doesn't need the activation-policy dance.
4. Run on any iOS Simulator.

## Manual smoke-test checklist

When changing the example or its dependencies, walk through these by hand:

- [ ] Cold launch shows three people (Alice, Bob, Cath).
- [ ] Tapping the `+` toolbar button adds a person; relaunching the example loses that node
      because the example uses `openInMemory()` (this is by design — keeps the sample
      hermetic).
- [ ] Selecting Alice shows Bob and Cath as 1-hop neighbours.
- [ ] Selecting Bob shows Cath. Selecting Cath shows nobody (no outgoing `KNOWS` edges).
- [ ] Toggling "Pair with secondary store" populates the right-hand readout with the same
      number of people as the primary store.
- [ ] Adding a person on the primary while pairing is on still works without error (the
      sample doesn't auto-resync on every write — call `syncNow` if you want immediate
      convergence after a write).

## CloudKit demo

Out of scope for the default sample to keep the example buildable without iCloud
entitlements. To wire CloudKit, replace the `InMemorySyncBackend` block with a
`CloudKitGraphSyncTransport` and a `CloudKitDatabase` adapter — see the
[`SwiftGraphDBCloudKit` DocC catalog](../../Sources/SwiftGraphDBCloudKit/SwiftGraphDBCloudKit.docc/EnablingCloudKitSync.md)
for the wiring template.
