# ShreAI Swift SDK

POS / BOS event SDK for iOS and macOS. Single-file source, zero dependencies (URLSession + Foundation only). Same wire contract as the JavaScript v2 SDK.

```swift
import ShreAI

try await ShreAI.shared.start(.init(
  endpoint:        "https://apiauth.shre.ai",   // control plane
  eventsEndpoint:  "https://events.shre.ai",    // data plane
  tenantId:        "merchant_123",
  app:             "rapid_pos",
  mode:            .readOnly                    // default; no API key needed
))

ShreAI.shared.track(
  name: "price_updated",
  entityType: "item",
  entityId: "UPC_012345678905",
  metadata: ["oldValue": 10.49, "newValue": 10.99]
)
```

## Install

### Swift Package Manager (recommended)

In Xcode: **File → Add Package Dependencies…** → enter:

```
https://github.com/Shreai/sdk-swift.git
```

Pick **Up to Next Major Version** from `2.0.0`.

Or in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Shreai/sdk-swift.git", from: "2.0.0")
],
targets: [
    .target(name: "YourApp", dependencies: ["ShreAI"])
]
```

### Single-file copy

```bash
curl -O https://raw.githubusercontent.com/Shreai/sdk-swift/main/Sources/ShreAI/ShreAI.swift
```

Drag into your Xcode project. ~393 lines, no dependencies.

## Quick start

In your `AppDelegate.swift` or `@main App` struct:

```swift
import ShreAI

Task {
    do {
        try await ShreAI.shared.start(.init(
            endpoint:       "https://apiauth.shre.ai",
            eventsEndpoint: "https://events.shre.ai",
            tenantId:       "<your_tenant>",
            app:            "rapid_pos",                // or rapid_bos
            mode:           .readOnly                   // default; no API key needed
        ))
        ShreAI.shared.onError = { err, ctx in print("[ShreAI] \(ctx): \(err)") }
        ShreAI.shared.onFlush = { sent, failed in print("[ShreAI] flushed \(sent)/\(failed)") }
    } catch {
        print("[ShreAI] init failed: \(error)")
    }
}
```

Then track events anywhere:

```swift
ShreAI.shared.track(name: "screen_viewed",        entityType: "screen", entityId: "ItemEdit")
ShreAI.shared.track(name: "item_scanned",         entityType: "item",   entityId: barcode)
ShreAI.shared.track(name: "transaction_complete", entityType: "transaction", entityId: txn.id,
                    metadata: ["total": txn.total, "itemCount": txn.items.count])
```

The SDK queues locally, batches every 10 s (server-tunable), retries with exponential backoff on failure (5 → 15 → 30 → 60 → 300 s). Fire-and-forget — never blocks UI.

## Configuration reference

| Field | Required | Default | Notes |
| --- | --- | --- | --- |
| `endpoint` | yes | — | `https://apiauth.shre.ai` (control plane) |
| `eventsEndpoint` | no | = endpoint | `https://events.shre.ai` (data plane) |
| `tenantId` | yes | — | Your store/tenant identifier |
| `app` | yes | — | `^[a-z][a-z0-9_-]{0,31}$` — e.g. `rapid_pos`, `rapid_bos` |
| `mode` | no | `.readOnly` | `.readOnly` (anonymous) or `.readWrite` (requires `bootstrapKey`) |
| `bootstrapKey` | iff readWrite | — | Public bootstrap key issued by Shre AI ops |
| `storeId`, `userId`, `role` | no | — | Optional context |
| `flushIntervalSeconds` | no | 10 | Server may override |
| `batchSize` | no | 50 | Server may override |
| `maxQueueSize` | no | 5000 | Local queue cap; oldest dropped on overflow |
| `timeoutMs` | no | 8000 | Per-request HTTP timeout |

## Error handling

| HTTP | SDK reaction |
| --- | --- |
| 200 | Drain accepted events from queue |
| 401 | Re-bootstrap session (refresh JWT, read_write only) |
| 403 | Set local kill-switch — stop tracking until next config refresh |
| 429 / 5xx | Exponential backoff: 5 → 15 → 30 → 60 → 300 s |
| Network offline | Stay queued; flush on next interval after recovery |

Every event has a client-generated `eventId`. The server upserts on `(tenantId, eventId)` so retries never double-write.

## Forbidden hosts

The SDK refuses to initialize against any hostname starting with `downloads.` — that's the SDK package mirror, not an API. You'll get a runtime `ShreError.downloadHostBlocked` if you try.

## Privacy manifest

This SDK ships a `PrivacyInfo.xcprivacy` declaring:
- `NSPrivacyTracking`: false
- `NSPrivacyCollectedDataType`: ProductInteraction (linked, non-tracking, analytics + app functionality)
- `NSPrivacyAccessedAPICategoryUserDefaults`: reason CA92.1

When you build your app, Xcode auto-merges this with your app's manifest. No extra steps needed for the SDK's portion.

## Platforms

- iOS 15+
- macOS 12+
- Other Apple platforms (visionOS, watchOS, tvOS) not formally tested but should work — the SDK uses only Foundation + URLSession.

## License

MIT. See `LICENSE`.

## Spec

This SDK implements the [Shre AI Shared SDK Spec](https://github.com/Shreai/shreai/blob/main/aros-developer-portal/sdks/SHARED-SDK-SPEC.md). Drift between language SDKs is a release blocker.
