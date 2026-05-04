// ShreAIObjC — Objective-C compatibility facade over the Swift SDK.
//
// Why this file exists: the Swift SDK uses Swift-only types (structs, enums
// with raw values, async/await, throwing functions) that don't bridge cleanly
// to Objective-C. This facade wraps the same internal SDK with @objc methods
// taking primitive types, so an Obj-C app can call:
//
//     [ShreAIObjC startWithEndpoint:@"https://apiauth.shre.ai"
//                    eventsEndpoint:@"https://events.shre.ai"
//                          tenantId:@"merchant_123"
//                               app:@"rapid_pos"
//                              mode:@"read_only"
//                      bootstrapKey:nil
//                completionHandler:^(NSError * _Nullable error) {
//                    if (error) NSLog(@"ShreAI init failed: %@", error);
//                }];
//
//     [ShreAIObjC trackName:@"price_updated"
//               entityType:@"item"
//                 entityId:@"UPC_123"
//                 metadata:@{@"old": @10.49, @"new": @10.99}];
//
// Swift callers should use the regular `ShreAI.shared.start(...)` API instead.

import Foundation

@objc(ShreAIObjC)
public final class ShreAIObjC: NSObject {

    /// Initialize the SDK. Errors flow through the completion handler as NSError.
    /// - Parameters:
    ///   - endpoint: control plane URL, e.g. "https://apiauth.shre.ai"
    ///   - eventsEndpoint: data plane URL, or nil to use endpoint for both
    ///   - tenantId: your tenant identifier (e.g. "merchant_123")
    ///   - app: ^[a-z][a-z0-9_-]{0,31}$ — e.g. "rapid_pos" or "rapid_bos"
    ///   - mode: "read_only" (default) or "read_write"
    ///   - bootstrapKey: required iff mode = "read_write"
    ///   - storeId / userId / role: optional context, pass nil to omit
    ///   - completion: called on the main queue with nil on success, NSError on failure
    @objc(startWithEndpoint:eventsEndpoint:tenantId:storeId:userId:role:app:mode:bootstrapKey:completionHandler:)
    public static func start(
        endpoint: String,
        eventsEndpoint: String?,
        tenantId: String,
        storeId: String?,
        userId: String?,
        role: String?,
        app: String,
        mode: String,
        bootstrapKey: String?,
        completionHandler: @escaping (NSError?) -> Void
    ) {
        let resolvedMode: ShreMode = (mode == "read_write") ? .readWrite : .readOnly
        do {
            let config = try ShreConfig(
                endpoint: endpoint,
                eventsEndpoint: eventsEndpoint,
                tenantId: tenantId,
                storeId: storeId,
                userId: userId,
                role: role,
                app: app,
                mode: resolvedMode,
                bootstrapKey: bootstrapKey
            )
            Task {
                do {
                    try await ShreAI.shared.start(config)
                    DispatchQueue.main.async { completionHandler(nil) }
                } catch let e as ShreError {
                    DispatchQueue.main.async {
                        completionHandler(NSError(
                            domain: "ai.shre.sdk",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: e.errorDescription ?? "ShreAI error"]
                        ))
                    }
                } catch {
                    DispatchQueue.main.async {
                        completionHandler(error as NSError)
                    }
                }
            }
        } catch let e as ShreError {
            DispatchQueue.main.async {
                completionHandler(NSError(
                    domain: "ai.shre.sdk",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: e.errorDescription ?? "ShreAI config error"]
                ))
            }
        } catch {
            DispatchQueue.main.async { completionHandler(error as NSError) }
        }
    }

    /// Convenience overload — read-only mode, no optional context, just the basics.
    @objc(startWithEndpoint:eventsEndpoint:tenantId:app:completionHandler:)
    public static func start(
        endpoint: String,
        eventsEndpoint: String?,
        tenantId: String,
        app: String,
        completionHandler: @escaping (NSError?) -> Void
    ) {
        start(
            endpoint: endpoint,
            eventsEndpoint: eventsEndpoint,
            tenantId: tenantId,
            storeId: nil,
            userId: nil,
            role: nil,
            app: app,
            mode: "read_only",
            bootstrapKey: nil,
            completionHandler: completionHandler
        )
    }

    /// Track an event. Fire-and-forget — never blocks, never throws to Obj-C.
    /// - Parameters:
    ///   - name: event name, max 128 chars
    ///   - entityType: optional ("item", "screen", "transaction", etc.)
    ///   - entityId: optional opaque identifier
    ///   - metadata: optional NSDictionary; values must be JSON-encodable (NSString, NSNumber, NSArray, NSDictionary, NSNull)
    @objc(trackName:entityType:entityId:metadata:)
    public static func track(
        name: String,
        entityType: String?,
        entityId: String?,
        metadata: [String: Any]?
    ) {
        ShreAI.shared.track(
            name: name,
            entityType: entityType,
            entityId: entityId,
            metadata: metadata ?? [:]
        )
    }

    /// Convenience overload — just an event name, no entity, no metadata.
    @objc(trackName:)
    public static func track(name: String) {
        ShreAI.shared.track(name: name, entityType: nil, entityId: nil, metadata: [:])
    }

    /// Force an immediate flush of the local queue.
    /// Errors are reported via the SDK's onError callback, not this completion.
    @objc(flushWithCompletionHandler:)
    public static func flush(completionHandler: @escaping () -> Void) {
        Task {
            await ShreAI.shared.flush()
            DispatchQueue.main.async { completionHandler() }
        }
    }

    /// Send a heartbeat ping (optional liveness signal).
    @objc(heartbeatWithDeviceId:completionHandler:)
    public static func heartbeat(deviceId: String?, completionHandler: @escaping () -> Void) {
        Task {
            await ShreAI.shared.heartbeat(deviceId: deviceId)
            DispatchQueue.main.async { completionHandler() }
        }
    }

    /// Stop the SDK and drain the queue. Call before app termination.
    @objc(stopWithCompletionHandler:)
    public static func stop(completionHandler: @escaping () -> Void) {
        Task {
            await ShreAI.shared.stop()
            DispatchQueue.main.async { completionHandler() }
        }
    }

    /// Set the error callback. Called from background queue.
    /// Pass nil to clear.
    @objc(setOnError:)
    public static func setOnError(_ callback: ((NSError, String) -> Void)?) {
        if let cb = callback {
            ShreAI.shared.onError = { err, ctx in cb(err as NSError, ctx) }
        } else {
            ShreAI.shared.onError = nil
        }
    }

    /// Set the flush callback. Called from background queue with sent + failed counts.
    /// Pass nil to clear.
    @objc(setOnFlush:)
    public static func setOnFlush(_ callback: ((Int, Int) -> Void)?) {
        if let cb = callback {
            ShreAI.shared.onFlush = { sent, failed in cb(sent, failed) }
        } else {
            ShreAI.shared.onFlush = nil
        }
    }
}
