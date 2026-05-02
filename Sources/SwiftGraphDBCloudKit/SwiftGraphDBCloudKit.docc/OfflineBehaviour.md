# Offline behaviour and account state

What happens when the network or the iCloud account drops out.

## Local writes are unaffected

The architecture invariant is: local reads and writes never depend on the network. Sync is a
replication layer, not a write path. While the transport is offline:

- New writes still commit through the actor.
- The `change_journal` keeps growing.
- Read queries, traversals, and snapshots all behave normally.

When connectivity or the account returns, the next sync round drains the journal in order.

## Account preflight

``CloudKitGraphSyncTransport.Configuration`` exposes
`preflightAccountState` (default `true`) and `accountProbe`. When both are set, every
`push` and `pull` first asks the probe for the current ``CloudKitAccountStatus``. If it isn't
``CloudKitAccountStatus``.`available`, the transport throws ``CloudKitAccountError``.`notAvailable`
and the sync registry transitions to `.offline`.

Apps that handle account state themselves (e.g. delegate to `CKSyncEngine.AccountChange`) can
disable the preflight by setting `preflightAccountState = false` or by passing `accountProbe:
nil`.

## Transient failures vs permanent

The transport classifies CloudKit errors:

- ``CloudKitTransportError``.`networkFailure` / `.throttled` — surfaces every change in the
  current batch as ``SyncRejectionReason``.`transient`. The journal entries stay; the next
  sync round retries them.
- ``CloudKitTransportError``.`limitExceeded` — the batch is silently halved and retried.
- ``CloudKitTransportError``.`rateLimited(retryAfter:)` /
  `.serviceUnavailable(retryAfter:)` — the transport sleeps for the suggested duration
  (capped at 5 minutes) before retrying.
- ``CloudKitConfigurationError`` — surfaced upstream so developers see entitlement and
  container misconfigurations immediately rather than as confusing transient errors.
