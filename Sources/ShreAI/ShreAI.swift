// ShreAI Swift SDK v2 — single file, zero dependencies (URLSession only).
// Spec: aros-developer-portal/sdks/SHARED-SDK-SPEC.md
//
// Quick start:
//   import ShreAI
//   try? ShreAI.shared.start(.init(
//     endpoint: "https://apiauth.shre.ai",
//     eventsEndpoint: "https://events.shre.ai",
//     tenantId: "merchant_123",
//     app: "rapid_pos",
//     mode: .readOnly
//   ))
//   ShreAI.shared.track(name: "screen_viewed", entityType: "screen", entityId: "ItemEdit")

import Foundation

public enum ShreMode: String, Codable, Sendable {
    case readOnly = "read_only"
    case readWrite = "read_write"
}

public struct ShreConfig: Sendable {
    public let endpoint: URL
    public let eventsEndpoint: URL
    public let tenantId: String
    public let storeId: String?
    public let userId: String?
    public let role: String?
    public let app: String
    public let mode: ShreMode
    public let bootstrapKey: String?
    public let sdkVersion: String
    public let flushIntervalSeconds: Int
    public let batchSize: Int
    public let maxQueueSize: Int
    public let timeoutMs: Int

    public init(
        endpoint: String,
        eventsEndpoint: String? = nil,
        tenantId: String,
        storeId: String? = nil,
        userId: String? = nil,
        role: String? = nil,
        app: String,
        mode: ShreMode = .readOnly,
        bootstrapKey: String? = nil,
        sdkVersion: String = "swift/2.0.0",
        flushIntervalSeconds: Int = 10,
        batchSize: Int = 50,
        maxQueueSize: Int = 5000,
        timeoutMs: Int = 8000
    ) throws {
        guard let ep = URL(string: endpoint), let host = ep.host else {
            throw ShreError.invalidEndpoint(endpoint)
        }
        if host.lowercased().hasPrefix("downloads.") {
            throw ShreError.downloadHostBlocked(host)
        }
        let evRaw = eventsEndpoint ?? endpoint
        guard let ev = URL(string: evRaw), let evHost = ev.host else {
            throw ShreError.invalidEndpoint(evRaw)
        }
        if evHost.lowercased().hasPrefix("downloads.") {
            throw ShreError.downloadHostBlocked(evHost)
        }
        if !ShreConfig.appPattern.contains(app) {
            throw ShreError.invalidApp(app)
        }
        if mode == .readWrite, (bootstrapKey ?? "").isEmpty {
            throw ShreError.missingBootstrapKey
        }
        self.endpoint = ep
        self.eventsEndpoint = ev
        self.tenantId = tenantId
        self.storeId = storeId
        self.userId = userId
        self.role = role
        self.app = app
        self.mode = mode
        self.bootstrapKey = bootstrapKey
        self.sdkVersion = sdkVersion
        self.flushIntervalSeconds = flushIntervalSeconds
        self.batchSize = batchSize
        self.maxQueueSize = maxQueueSize
        self.timeoutMs = timeoutMs
    }

    static let appPattern: NSRegularExpression = {
        // ^[a-z][a-z0-9_-]{0,31}$
        try! NSRegularExpression(pattern: "^[a-z][a-z0-9_-]{0,31}$")
    }()
}

extension NSRegularExpression {
    func contains(_ s: String) -> Bool {
        firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}

public enum ShreError: Error, LocalizedError {
    case invalidEndpoint(String)
    case downloadHostBlocked(String)
    case invalidApp(String)
    case missingBootstrapKey
    case sessionFailed(Int, String)
    case batchFailed(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let s): return "ShreAI: invalid endpoint URL '\(s)'"
        case .downloadHostBlocked(let h):
            return "ShreAI: hostname '\(h)' looks like a download host. Use https://apiauth.shre.ai (control) and https://events.shre.ai (data)."
        case .invalidApp(let a): return "ShreAI: app '\(a)' must match ^[a-z][a-z0-9_-]{0,31}$"
        case .missingBootstrapKey: return "ShreAI: read_write mode requires bootstrapKey"
        case .sessionFailed(let s, let m): return "ShreAI session failed (\(s)): \(m)"
        case .batchFailed(let s, let m): return "ShreAI batch failed (\(s)): \(m)"
        }
    }
}

public struct ShreEvent: Sendable {
    public let eventId: String
    public let eventName: String
    public let entityType: String?
    public let entityId: String?
    public let metadata: [String: Any]
    public let timestamp: Date

    public init(
        name: String,
        entityType: String? = nil,
        entityId: String? = nil,
        metadata: [String: Any] = [:],
        timestamp: Date = Date()
    ) {
        self.eventId = UUID().uuidString.lowercased()
        self.eventName = name
        self.entityType = entityType
        self.entityId = entityId
        self.metadata = metadata
        self.timestamp = timestamp
    }

    fileprivate var jsonObject: [String: Any] {
        var o: [String: Any] = [
            "eventId": eventId,
            "eventName": eventName,
            "metadata": metadata,
            "timestamp": ISO8601DateFormatter().string(from: timestamp)
        ]
        if let t = entityType { o["entityType"] = t }
        if let i = entityId { o["entityId"] = i }
        return o
    }
}

public final class ShreAI {
    public static let shared = ShreAI()
    private init() {}

    private let queueLock = NSLock()
    private var queue: [ShreEvent] = []
    private var inFlight = false
    private var retryAttempt = 0
    private let backoffSec: [TimeInterval] = [5, 15, 30, 60, 300]

    private var cfg: ShreConfig?
    private var sdkToken: String?
    private var sessionId: String?
    private var tokenExpiresAt: Date = .distantPast
    private var trackingEnabled = true
    private var disabledEvents: Set<String> = []
    private var flushTimer: Timer?
    private var configTimer: Timer?

    public var onError: ((Error, String) -> Void)?
    public var onFlush: ((Int, Int) -> Void)?

    public func start(_ config: ShreConfig) async throws {
        cfg = config
        try await bootstrap()
        startTimers()
        registerTerminationDrain()
    }

    public func track(
        name: String,
        entityType: String? = nil,
        entityId: String? = nil,
        metadata: [String: Any] = [:]
    ) {
        guard let cfg, trackingEnabled, !disabledEvents.contains(name) else { return }
        let evt = ShreEvent(name: name, entityType: entityType, entityId: entityId, metadata: metadata)
        queueLock.lock()
        defer { queueLock.unlock() }
        queue.append(evt)
        if queue.count > cfg.maxQueueSize { queue.removeFirst(queue.count - cfg.maxQueueSize) }
    }

    public func flush() async {
        guard let cfg else { return }
        queueLock.lock()
        if inFlight || queue.isEmpty {
            queueLock.unlock()
            return
        }
        inFlight = true
        let batch = Array(queue.prefix(cfg.batchSize))
        queue.removeFirst(min(cfg.batchSize, queue.count))
        queueLock.unlock()

        do {
            let ack = try await postBatch(batch)
            queueLock.lock(); inFlight = false; queueLock.unlock()
            retryAttempt = 0
            onFlush?(ack.accepted, ack.rejected)
            if ack.nextFlushSeconds > 0, ack.nextFlushSeconds != cfg.flushIntervalSeconds {
                restartFlushTimer(seconds: ack.nextFlushSeconds)
            }
        } catch let e as ShreError {
            // requeue at front
            queueLock.lock(); queue.insert(contentsOf: batch, at: 0); inFlight = false; queueLock.unlock()
            onFlush?(0, batch.count)
            switch e {
            case .batchFailed(let s, _) where s == 401: try? await bootstrap()
            case .batchFailed(let s, _) where s == 403: trackingEnabled = false
            case .batchFailed(let s, _) where s == 429 || s >= 500: scheduleBackoff()
            default: onError?(e, "flush")
            }
        } catch {
            queueLock.lock(); queue.insert(contentsOf: batch, at: 0); inFlight = false; queueLock.unlock()
            onError?(error, "flush")
            scheduleBackoff()
        }
    }

    public func heartbeat(deviceId: String? = nil) async {
        guard let cfg else { return }
        var body: [String: Any] = [
            "tenantId": cfg.tenantId,
            "app": cfg.app,
            "sdkVersion": cfg.sdkVersion
        ]
        if let s = cfg.storeId { body["storeId"] = s }
        if let d = deviceId { body["deviceId"] = d }
        body["eventsQueued"] = queue.count
        let url = cfg.eventsEndpoint.appendingPathComponent("v1/sdk/heartbeat")
        _ = try? await post(url: url, body: body, expectAuth: false)
    }

    public func stop() async {
        flushTimer?.invalidate(); flushTimer = nil
        configTimer?.invalidate(); configTimer = nil
        await flush()
    }

    // MARK: - Internals

    private func bootstrap() async throws {
        guard let cfg else { return }
        var body: [String: Any] = [
            "tenantId": cfg.tenantId,
            "app": cfg.app,
            "mode": cfg.mode.rawValue,
            "sdkVersion": cfg.sdkVersion
        ]
        if let s = cfg.storeId { body["storeId"] = s }
        if let u = cfg.userId { body["userId"] = u }
        if let r = cfg.role { body["role"] = r }
        if let k = cfg.bootstrapKey { body["bootstrapKey"] = k }
        let url = cfg.endpoint.appendingPathComponent("v1/sdk/session")
        let (data, status) = try await rawPost(url: url, body: body, headers: commonHeaders())
        guard status == 200 else {
            throw ShreError.sessionFailed(status, String(data: data, encoding: .utf8) ?? "")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            sdkToken = json["sdkToken"] as? String
            sessionId = json["sessionId"] as? String
            trackingEnabled = (json["trackingEnabled"] as? Bool) ?? true
            if let exp = json["expiresIn"] as? Int {
                tokenExpiresAt = Date().addingTimeInterval(TimeInterval(exp))
            }
        }
        // pull config (kill switch + disabled events)
        await refreshRemoteConfig()
    }

    private func refreshRemoteConfig() async {
        guard let cfg else { return }
        let url = cfg.endpoint.appendingPathComponent("v1/sdk/config")
        var req = URLRequest(url: url, timeoutInterval: TimeInterval(cfg.timeoutMs) / 1000)
        for (k, v) in commonHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let te = json["trackingEnabled"] as? Bool { trackingEnabled = te }
        if let de = json["disabledEvents"] as? [String] { disabledEvents = Set(de) }
    }

    private func postBatch(_ events: [ShreEvent]) async throws -> (accepted: Int, rejected: Int, nextFlushSeconds: Int) {
        guard let cfg else { return (0, 0, 10) }
        if cfg.mode == .readWrite, tokenExpiresAt.timeIntervalSinceNow < 60 {
            try await bootstrap()
        }
        let body: [String: Any] = ["events": events.map { $0.jsonObject }]
        let url = cfg.eventsEndpoint.appendingPathComponent("v1/events/batch")
        let (data, status) = try await rawPost(url: url, body: body, headers: commonHeaders())
        guard status == 200 else {
            throw ShreError.batchFailed(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (0, 0, 10) }
        return (
            (j["accepted"] as? Int) ?? 0,
            (j["rejected"] as? Int) ?? 0,
            (j["nextFlushSeconds"] as? Int) ?? cfg.flushIntervalSeconds
        )
    }

    private func post(url: URL, body: [String: Any], expectAuth: Bool) async throws -> Data {
        let (data, _) = try await rawPost(url: url, body: body, headers: commonHeaders())
        return data
    }

    private func rawPost(url: URL, body: [String: Any], headers: [String: String]) async throws -> (Data, Int) {
        guard let cfg else { return (Data(), 0) }
        var req = URLRequest(url: url, timeoutInterval: TimeInterval(cfg.timeoutMs) / 1000)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func commonHeaders() -> [String: String] {
        guard let cfg else { return [:] }
        var h: [String: String] = [
            "X-Shre-Tenant": cfg.tenantId,
            "X-Shre-App": cfg.app,
            "X-Shre-SDK-Version": cfg.sdkVersion
        ]
        if let s = cfg.storeId { h["X-Shre-Store"] = s }
        if let t = sdkToken { h["Authorization"] = "Bearer \(t)" }
        return h
    }

    private func startTimers() {
        guard let cfg else { return }
        DispatchQueue.main.async {
            self.restartFlushTimer(seconds: cfg.flushIntervalSeconds)
            self.configTimer?.invalidate()
            self.configTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
                Task { await self.refreshRemoteConfig() }
            }
        }
    }

    private func restartFlushTimer(seconds: Int) {
        DispatchQueue.main.async {
            self.flushTimer?.invalidate()
            self.flushTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(2, seconds)), repeats: true) { _ in
                Task { await self.flush() }
            }
        }
    }

    private func scheduleBackoff() {
        let idx = min(retryAttempt, backoffSec.count - 1)
        let delay = backoffSec[idx]
        retryAttempt += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { await self?.flush() }
        }
    }

    private func registerTerminationDrain() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in Task { await ShreAI.shared.flush() } }
        #elseif canImport(AppKit)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in Task { await ShreAI.shared.flush() } }
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
