// Modified for the unofficial CompEditor fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

/// Only these coarse actions can cross the usage reporting boundary.
enum ForkUsageFeature: String, CaseIterable, Sendable {
    case semanticCompletionAccepted = "semantic_completion_accepted"
    case copilotCompletionAccepted = "copilot_completion_accepted"
    case definitionRequested = "definition_requested"
}

struct ForkUsageConfiguration: Sendable {
    let endpoint: URL
    let appVersion: String

    init?(info: [String: Any], identifier: String?) {
        guard identifier == "dev.local.SemanticEditor",
              let raw = info["CompEditorUsageEndpoint"] as? String,
              let components = URLComponents(string: raw),
              components.scheme == "https", let host = components.host?.lowercased(),
              host.contains("."), !host.hasSuffix("."),
              !["localhost", "invalid", "test", "example"].contains(host.split(separator: ".").last.map(String.init) ?? ""),
              !["example.com", "example.net", "example.org"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath == "/v1/usage", let endpoint = components.url,
              let version = info["CFBundleShortVersionString"] as? String,
              Self.validVersion(version) else { return nil }
        self.endpoint = endpoint
        self.appVersion = version
    }

    static func validVersion(_ value: String) -> Bool {
        guard value.utf8.count <= 64,
              value.range(of: #"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z"#,
                          options: .regularExpression) != nil else { return false }
        let release = value.split(separator: "+", maxSplits: 1)[0]
        let parts = release.split(separator: "-", maxSplits: 1)
        guard parts.count == 2 else { return true }
        return parts[1].split(separator: ".").allSatisfy { part in
            !(part.count > 1 && part.first == "0" && part.utf8.allSatisfy { (48...57).contains($0) })
        }
    }
}

enum ForkUsageLimits {
    static let maximumEntries = 31
    static let maximumBytes = 16 * 1024
    static let retentionDays = 31
    static let maximumCounter = 10_000
    static let attemptInterval: TimeInterval = 60 * 60
    static let requestTimeout: TimeInterval = 5
}

/// The clock is local bookkeeping; no precise timestamp is included in a request.
protocol ForkUsageClock: Sendable {
    func now() -> Date
}

struct ForkUsageSystemClock: ForkUsageClock {
    func now() -> Date { Date() }
}

protocol ForkUsageStorage: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

protocol ForkUsageTransport: Sendable {
    /// True acknowledges all batches. A failed/uncertain response leaves every batch queued.
    func send(_ data: Data, to endpoint: URL) async -> Bool
}

struct ForkUsageFeatureCounts: Codable, Equatable, Sendable {
    var semanticCompletionAccepted = 0
    var copilotCompletionAccepted = 0
    var definitionRequested = 0

    private enum CodingKeys: String, CodingKey {
        case semanticCompletionAccepted = "semantic_completion_accepted"
        case copilotCompletionAccepted = "copilot_completion_accepted"
        case definitionRequested = "definition_requested"
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.semanticCompletionAccepted = try values.decodeIfPresent(Int.self, forKey: .semanticCompletionAccepted) ?? 0
        self.copilotCompletionAccepted = try values.decodeIfPresent(Int.self, forKey: .copilotCompletionAccepted) ?? 0
        self.definitionRequested = try values.decodeIfPresent(Int.self, forKey: .definitionRequested) ?? 0
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if self.semanticCompletionAccepted > 0 { try values.encode(self.semanticCompletionAccepted, forKey: .semanticCompletionAccepted) }
        if self.copilotCompletionAccepted > 0 { try values.encode(self.copilotCompletionAccepted, forKey: .copilotCompletionAccepted) }
        if self.definitionRequested > 0 { try values.encode(self.definitionRequested, forKey: .definitionRequested) }
    }

    var isValid: Bool {
        [self.semanticCompletionAccepted, self.copilotCompletionAccepted, self.definitionRequested]
            .allSatisfy { (0...ForkUsageLimits.maximumCounter).contains($0) }
    }

    mutating func increment(_ feature: ForkUsageFeature) {
        switch feature {
            case .semanticCompletionAccepted: self.semanticCompletionAccepted = min(self.semanticCompletionAccepted + 1, ForkUsageLimits.maximumCounter)
            case .copilotCompletionAccepted: self.copilotCompletionAccepted = min(self.copilotCompletionAccepted + 1, ForkUsageLimits.maximumCounter)
            case .definitionRequested: self.definitionRequested = min(self.definitionRequested + 1, ForkUsageLimits.maximumCounter)
        }
    }
}

struct ForkUsageBatch: Codable, Equatable, Sendable {
    let batchID: UUID
    let day: String
    let appVersion: String
    var launches: Int
    var features: ForkUsageFeatureCounts

    private enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case day
        case appVersion = "app_version"
        case launches, features
    }

    var isValid: Bool {
        ForkUsageDay.date(self.day) != nil && ForkUsageConfiguration.validVersion(self.appVersion)
            && (0...ForkUsageLimits.maximumCounter).contains(self.launches) && self.features.isValid
    }
}

struct ForkUsageEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let installID: UUID
    let batches: [ForkUsageBatch]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case installID = "install_id"
        case batches
    }
}

/// Sealed batches are immutable, including across failed uploads and later events.
/// Only the unsent accumulator may change; it is sealed durably before any network call.
struct ForkUsageState: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let installID: UUID
    var lastAttempt: Date?
    var lastActiveDay: String?
    var sealed: [ForkUsageBatch] = []
    var accumulating: ForkUsageBatch?

    var entries: [ForkUsageBatch] { self.sealed + [self.accumulating].compactMap { $0 } }

    var isValid: Bool {
        self.schemaVersion == 1 && self.entries.count <= ForkUsageLimits.maximumEntries
            && self.entries.allSatisfy(\.isValid)
            && Set(self.entries.map(\.batchID)).count == self.entries.count
            && self.lastAttempt.map { $0.timeIntervalSince1970.isFinite } != false
            && self.lastActiveDay.map { ForkUsageDay.date($0) != nil } != false
    }
}

enum ForkUsageDay {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    static func string(_ date: Date) -> String {
        let parts = self.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func date(_ string: String) -> Date? {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard string.utf8.count == 10, parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), (1...9999).contains(year),
              let month = Int(parts[1]), let day = Int(parts[2]),
              let date = self.calendar.date(from: DateComponents(year: year, month: month, day: day)),
              self.string(date) == string else { return nil }
        return date
    }
}

actor ForkUsageRecorder {
    private let configuration: ForkUsageConfiguration?
    private let storage: any ForkUsageStorage
    private let transport: any ForkUsageTransport
    private let clock: any ForkUsageClock
    private var state: ForkUsageState?
    private var disabled = false
    private var sending = false

    init(configuration: ForkUsageConfiguration?, storage: any ForkUsageStorage,
         transport: any ForkUsageTransport, clock: any ForkUsageClock = ForkUsageSystemClock()) {
        self.configuration = configuration
        self.storage = storage
        self.transport = transport
        self.clock = clock
    }

    func recordLaunch() async { await self.record(launch: true, feature: nil) }
    func record(_ feature: ForkUsageFeature) async { await self.record(launch: false, feature: feature) }

    /// Call only when the app is active. Does not backfill days skipped during sleep/inactivity.
    func recordActiveDay() async { await self.record(launch: false, feature: nil) }

    private func record(launch: Bool, feature: ForkUsageFeature?) async {
        guard self.loadStateIfNeeded(), let configuration = self.configuration, var next = self.state else { return }
        let now = self.clock.now()
        let day = ForkUsageDay.string(now)
        self.prune(&next, now: now)
        if launch || feature != nil || next.lastActiveDay != day {
            if next.accumulating?.day != day || next.accumulating?.appVersion != configuration.appVersion {
                if let accumulating = next.accumulating { next.sealed.append(accumulating) }
                next.accumulating = ForkUsageBatch(batchID: UUID(), day: day, appVersion: configuration.appVersion,
                                                  launches: 0, features: ForkUsageFeatureCounts())
            }
            if launch { next.accumulating!.launches = min(next.accumulating!.launches + 1, ForkUsageLimits.maximumCounter) }
            if let feature { next.accumulating!.features.increment(feature) }
            next.lastActiveDay = day
        }
        guard self.commit(next, now: now) else { return }
        await self.flushIfDue()
    }

    func flushIfDue() async {
        guard !self.sending, self.loadStateIfNeeded(),
              let configuration = self.configuration, var next = self.state else { return }
        let now = self.clock.now()
        self.prune(&next, now: now)
        if let lastAttempt = next.lastAttempt, now.timeIntervalSince(lastAttempt) < ForkUsageLimits.attemptInterval {
            _ = self.commit(next, now: now)
            return
        }
        if let accumulating = next.accumulating {
            next.sealed.append(accumulating)
            next.accumulating = nil
        }
        guard !next.sealed.isEmpty else {
            _ = self.commit(next, now: now)
            return
        }
        next.lastAttempt = now
        // The throttle and exact batches must survive a crash before the server receives them.
        guard self.commit(next, now: now), let committed = self.state,
              let payload = try? Self.encode(ForkUsageEnvelope(schemaVersion: 1, installID: committed.installID, batches: committed.sealed)),
              payload.count <= ForkUsageLimits.maximumBytes else { return }
        let sentIDs = Set(committed.sealed.map(\.batchID))
        self.sending = true
        let acknowledged = await self.transport.send(payload, to: configuration.endpoint)
        self.sending = false
        if acknowledged, var current = self.state {
            current.sealed.removeAll { sentIDs.contains($0.batchID) }
            // Newly accumulated events are preserved even if they arrived while awaiting the server.
            _ = self.commit(current, now: self.clock.now())
        }
    }

    private func loadStateIfNeeded() -> Bool {
        // This guard precedes storage access and UUID creation, including for explicit flush calls.
        guard self.configuration != nil, !self.disabled else { return false }
        if self.state != nil { return true }
        do {
            if let data = try self.storage.load() {
                guard data.count <= ForkUsageLimits.maximumBytes else { self.disabled = true; return false }
                let decoded = try JSONDecoder().decode(ForkUsageState.self, from: data)
                guard decoded.isValid else { self.disabled = true; return false }
                self.state = decoded
            } else {
                self.state = ForkUsageState(installID: UUID())
            }
            return true
        } catch {
            // Usage reporting must not interrupt editing. Corrupt/unwritable storage disables this session.
            self.disabled = true
            return false
        }
    }

    private func commit(_ candidate: ForkUsageState, now: Date) -> Bool {
        guard !self.disabled else { return false }
        var next = candidate
        self.prune(&next, now: now)
        if next == self.state { return true }
        do {
            var data = try Self.encode(next)
            while data.count > ForkUsageLimits.maximumBytes, !next.sealed.isEmpty {
                next.sealed.removeFirst()
                data = try Self.encode(next)
            }
            guard data.count <= ForkUsageLimits.maximumBytes, next.isValid else { self.disabled = true; return false }
            try self.storage.save(data)
            self.state = next
            return true
        } catch {
            // In particular, never upload after failing to persist the retry throttle or batch IDs.
            self.disabled = true
            return false
        }
    }

    private func prune(_ state: inout ForkUsageState, now: Date) {
        let today = ForkUsageDay.calendar.startOfDay(for: now)
        let oldest = ForkUsageDay.calendar.date(byAdding: .day, value: -(ForkUsageLimits.retentionDays - 1), to: today)!
        let minimumDay = ForkUsageDay.string(oldest)
        let maximumDay = ForkUsageDay.string(today)
        state.sealed.removeAll { $0.day < minimumDay || $0.day > maximumDay }
        if let pending = state.accumulating, pending.day < minimumDay || pending.day > maximumDay { state.accumulating = nil }
        while state.entries.count > ForkUsageLimits.maximumEntries { state.sealed.removeFirst() }
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

/// One process owns a queue for its lifetime; a second app instance silently disables reporting.
final class ForkUsageFileStorage: ForkUsageStorage, @unchecked Sendable {
    let url: URL
    private let leaseLock = NSLock()
    private var leaseDescriptor: Int32?

    init(url: URL) { self.url = url }

    deinit {
        if let leaseDescriptor { Darwin.close(leaseDescriptor) }
    }

    func load() throws -> Data? {
        try self.acquireLease()
        guard FileManager.default.fileExists(atPath: self.url.path) else { return nil }
        let file = try FileHandle(forReadingFrom: self.url)
        defer { try? file.close() }
        return try file.read(upToCount: ForkUsageLimits.maximumBytes + 1) ?? Data()
    }

    func save(_ data: Data) throws {
        guard data.count <= ForkUsageLimits.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try self.acquireLease()
        try data.write(to: self.url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
    }

    private func acquireLease() throws {
        try self.leaseLock.withLock {
            if self.leaseDescriptor != nil { return }
            try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // A separate inode survives atomic queue replacement. Never block startup waiting for another instance.
            let descriptor = Darwin.open(self.url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let lockFile: (Int32, Int32) -> Int32 = flock
            guard lockFile(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let failure = errno
                Darwin.close(descriptor)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
            }
            self.leaseDescriptor = descriptor
        }
    }
}

final class ForkUsageURLTransport: NSObject, ForkUsageTransport, URLSessionTaskDelegate {
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration

    init(makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration = ForkUsageURLTransport.configuration) {
        self.makeConfiguration = makeConfiguration
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = ForkUsageLimits.requestTimeout
        configuration.timeoutIntervalForResource = ForkUsageLimits.requestTimeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    func send(_ data: Data, to endpoint: URL) async -> Bool {
        guard data.count <= ForkUsageLimits.maximumBytes else { return false }
        let session = URLSession(configuration: self.makeConfiguration(), delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: ForkUsageLimits.requestTimeout)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CompEditor-Usage/1", forHTTPHeaderField: "User-Agent")
        do {
            // Only response headers are needed; never retain or log a server response body.
            let (_, response) = try await session.bytes(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 204
        } catch {
            return false
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Foreground integration only. Recording and file/network I/O run on the recorder actor.
@MainActor final class ForkUsageMetrics {
    static let shared = ForkUsageMetrics()
    private let recorder: ForkUsageRecorder?
    private var started = false
    private var active = false
    private var heartbeat: Task<Void, Never>?

    private init() {
        guard let configuration = ForkUsageConfiguration(info: Bundle.main.infoDictionary ?? [:], identifier: Bundle.main.bundleIdentifier),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            self.recorder = nil
            return
        }
        let file = support.appendingPathComponent("CompEditor", isDirectory: true).appendingPathComponent("usage-metrics.json")
        self.recorder = ForkUsageRecorder(configuration: configuration, storage: ForkUsageFileStorage(url: file), transport: ForkUsageURLTransport())
    }

    func start(isActive: Bool) {
        guard !self.started, let recorder else { return }
        self.started = true
        Task { await recorder.recordLaunch() }
        self.setApplicationActive(isActive)
    }

    func setApplicationActive(_ isActive: Bool) {
        guard self.started, let recorder, self.active != isActive else { return }
        self.active = isActive
        self.heartbeat?.cancel()
        self.heartbeat = nil
        guard isActive else { return }
        self.heartbeat = Task { [weak self] in
            guard !Task.isCancelled, self?.active == true else { return }
            Task { await recorder.recordActiveDay() }
            while !Task.isCancelled {
                // An active interval shorter than one minute can still span two UTC days.
                // Schedule independently of uploads so a five-second request cannot postpone midnight.
                do { try await Task.sleep(for: .seconds(Self.heartbeatDelay(after: Date()))) } catch { return }
                guard !Task.isCancelled, self?.active == true else { return }
                Task { await recorder.recordActiveDay() }
            }
        }
    }

    static func heartbeatDelay(after now: Date) -> TimeInterval {
        let today = ForkUsageDay.calendar.startOfDay(for: now)
        let nextDay = ForkUsageDay.calendar.date(byAdding: .day, value: 1, to: today)!
        return min(60, max(0.001, nextDay.timeIntervalSince(now)))
    }

    func record(_ feature: ForkUsageFeature) {
        guard self.started, let recorder else { return }
        Task { await recorder.record(feature) }
    }
}
