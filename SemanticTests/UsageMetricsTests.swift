// SPDX-License-Identifier: Apache-2.0
import Foundation

private final class TestClock: ForkUsageClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { self.lock.withLock { self.value } }
    func advance(_ seconds: TimeInterval) { self.lock.withLock { self.value.addTimeInterval(seconds) } }
    func set(_ value: Date) { self.lock.withLock { self.value = value } }
}

private final class MemoryStorage: ForkUsageStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var contents: Data?
    private var readCount = 0
    private var writeCount = 0
    private var failWrites = false
    init(_ contents: Data? = nil) { self.contents = contents }
    func load() throws -> Data? {
        self.lock.withLock { self.readCount += 1; return self.contents }
    }
    func save(_ data: Data) throws {
        try self.lock.withLock {
            if self.failWrites { throw CocoaError(.fileWriteNoPermission) }
            self.writeCount += 1
            self.contents = data
        }
    }
    func rejectWrites() { self.lock.withLock { self.failWrites = true } }
    var reads: Int { self.lock.withLock { self.readCount } }
    var writes: Int { self.lock.withLock { self.writeCount } }
    var data: Data? { self.lock.withLock { self.contents } }
    var state: ForkUsageState { try! JSONDecoder().decode(ForkUsageState.self, from: self.data!) }
}

private actor TestTransport: ForkUsageTransport {
    private var payloads: [Data] = []
    private var result = false
    private var held = false
    private var response: CheckedContinuation<Bool, Never>?
    private var requestWaiter: CheckedContinuation<Void, Never>?

    func setResult(_ result: Bool) { self.result = result }
    func hold() { self.held = true }
    func release(_ result: Bool) { self.held = false; self.response?.resume(returning: result); self.response = nil }
    func waitForRequest() async {
        if !self.payloads.isEmpty { return }
        await withCheckedContinuation { self.requestWaiter = $0 }
    }
    func send(_ data: Data, to endpoint: URL) async -> Bool {
        self.payloads.append(data)
        self.requestWaiter?.resume()
        self.requestWaiter = nil
        if self.held { return await withCheckedContinuation { self.response = $0 } }
        return self.result
    }
    var requests: [Data] { self.payloads }
    var envelopes: [ForkUsageEnvelope] { self.payloads.map { try! JSONDecoder().decode(ForkUsageEnvelope.self, from: $0) } }
}

/// URLSession's protocol override supplies all responses without opening any network connection.
private final class OfflineURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = self.request.url, let status = Int(url.lastPathComponent) else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!,
                                 cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct UsageMetricsTests {
    private static let origin = ForkUsageDay.date("2026-10-15")!
    private static let expectedEndpoint = "https://compeditor-usage-ingestion.moton9.chatgpt.site/v1/usage"
    private static var configured: ForkUsageConfiguration {
        // The configured URL is only passed to in-memory stubs or unresumed tasks, never to a live request.
        ForkUsageConfiguration(info: ["CompEditorUsageEndpoint": Self.expectedEndpoint,
                                      "CFBundleShortVersionString": "0.2.3"], identifier: "dev.local.SemanticEditor")!
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError(name) }
        print("PASS: " + name)
    }

    static func main() async throws {
        self.configurationPolicy()
        try self.compiledConfiguration(paths: Array(CommandLine.arguments.dropFirst()))
        await self.disabledHasNoSideEffects()
        try await self.retryIdentityAndHourlyThrottle()
        await self.concurrentEventsSurviveAcknowledgment()
        await self.utcActivityAndSleep()
        self.activityBoundarySchedule()
        try await self.queueBoundsAndCounterSaturation()
        await self.storageFailureFailsClosed()
        try self.realFileStorage()
        try await self.exclusiveStorageLease()
        await self.networkPolicy()
        await self.httpAcknowledgmentPolicy()
        print("Offline usage metrics checks complete; no network, credentials or production storage used.")
    }

    private static func configurationPolicy() {
        self.check(self.configured.endpoint.path == "/v1/usage", "explicit public HTTPS endpoint accepted")
        self.check(self.configured.endpoint.absoluteString == self.expectedEndpoint, "prepared public receiver endpoint is accepted exactly")
        var credentialEndpoint = URLComponents(string: "https://metrics.compeditor.dev/v1/usage")!
        credentialEndpoint.user = "synthetic-user"
        credentialEndpoint.password = "synthetic-password"
        let badEndpoints = ["", "$(COMPEDITOR_USAGE_ENDPOINT)", "http://metrics.compeditor.dev/v1/usage",
                            "https://metrics.compeditor.dev/v1/usage?name=private", "https://metrics.compeditor.dev/v1/usage#private",
                            credentialEndpoint.url!.absoluteString, "https://metrics.compeditor.dev:8443/v1/usage",
                            "https://metrics.compeditor.dev/v1/other", "https://metrics.compeditor.dev/v1/%75sage",
                            "https://example.com/v1/usage", "https://telemetry.example.org/v1/usage", "https://endpoint.invalid/v1/usage",
                            "https://localhost/v1/usage", "https://server.localhost/v1/usage"]
        for endpoint in badEndpoints {
            let configuration = ForkUsageConfiguration(info: ["CompEditorUsageEndpoint": endpoint, "CFBundleShortVersionString": "0.2.3"],
                                                       identifier: "dev.local.SemanticEditor")
            self.check(configuration == nil, "missing, placeholder or unsafe endpoint rejected")
        }
        let base: [String: Any] = ["CompEditorUsageEndpoint": self.configured.endpoint.absoluteString, "CFBundleShortVersionString": "0.2.3"]
        self.check(ForkUsageConfiguration(info: base, identifier: "com.coteditor.CotEditor") == nil, "upstream identity cannot enable fork metrics")
        for version in ["", "username", "0.2.3/private", "0.2.3\n", String(repeating: "1", count: 65), "0.2.3-利用者", "0.02.3", "0.2.3-01", "0.2.3-a..b", "0.2.3+."] {
            self.check(!ForkUsageConfiguration.validVersion(version), "non-version and unbounded app metadata rejected")
        }
        self.check(ForkUsageConfiguration.validVersion("0.2.3-beta.1+45"), "ASCII release and prerelease versions accepted")
    }

    private static func compiledConfiguration(paths: [String]) throws {
        for path in paths {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            self.check(info["CompEditorUsageEndpoint"] as? String == self.expectedEndpoint,
                       "compiled Info.plist contains the complete intended endpoint: " + path)
            let configuration = ForkUsageConfiguration(info: info, identifier: info["CFBundleIdentifier"] as? String)
            self.check(configuration?.endpoint.absoluteString == self.expectedEndpoint,
                       "compiled bundle metadata satisfies the native reporting policy: " + path)
        }
    }

    private static func disabledHasNoSideEffects() async {
        let storage = MemoryStorage()
        let transport = TestTransport()
        let recorder = ForkUsageRecorder(configuration: nil, storage: storage, transport: transport)
        await recorder.recordLaunch()
        await recorder.record(.definitionRequested)
        await recorder.recordActiveDay()
        await recorder.flushIfDue()
        self.check(storage.reads == 0 && storage.writes == 0 && storage.data == nil, "disabled metrics never read/write identity or queue")
        let requests = await transport.requests
        self.check(requests.isEmpty, "disabled metrics never invoke transport")
    }

    private static func retryIdentityAndHourlyThrottle() async throws {
        let storage = MemoryStorage()
        let clock = TestClock(self.origin)
        let transport = TestTransport()
        let recorder = ForkUsageRecorder(configuration: self.configured, storage: storage, transport: transport, clock: clock)
        await recorder.recordLaunch()
        let initial = await transport.envelopes[0]
        await recorder.record(.semanticCompletionAccepted)
        clock.advance(3_599)
        await recorder.record(.copilotCompletionAccepted)
        let requests = await transport.requests
        self.check(requests.count == 1, "rapid events cannot bypass one-hour attempt throttle")
        let secondTransport = TestTransport()
        let restarted = ForkUsageRecorder(configuration: self.configured, storage: storage, transport: secondTransport, clock: clock)
        await restarted.recordLaunch()
        let beforeHour = await secondTransport.requests
        self.check(beforeHour.isEmpty, "throttle survives relaunch")
        clock.advance(1)
        await restarted.flushIfDue()
        let retried = await secondTransport.envelopes[0]
        self.check(initial.installID == retried.installID, "install UUID survives relaunch")
        self.check(initial.batches[0] == retried.batches[0], "retry preserves original batch ID and all counts")
        self.check(retried.batches.count == 2 && retried.batches[0].batchID != retried.batches[1].batchID,
                   "later same-day events receive their own durable batch ID")
        self.check(retried.batches[1].launches == 1 && retried.batches[1].features.semanticCompletionAccepted == 1
                   && retried.batches[1].features.copilotCompletionAccepted == 1, "relaunch and feature deltas are preserved")
        let data = await secondTransport.requests[0]
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        self.check(Set(object.keys) == ["schema_version", "install_id", "batches"], "wire envelope contains only declared fields")
        let batches = object["batches"] as! [[String: Any]]
        self.check(batches.allSatisfy { Set($0.keys) == ["batch_id", "day", "app_version", "launches", "features"] },
                   "wire batches contain no paths, text, identity metadata or timestamps")
        self.check(initial.schemaVersion == 1 && initial.batches[0].day == "2026-10-15", "wire schema and UTC calendar day are fixed")
        clock.set(self.origin)
        await restarted.flushIfDue()
        let rolledBack = await secondTransport.requests
        self.check(rolledBack.count == 1, "clock rollback does not bypass persisted throttle")
        clock.set(self.origin.addingTimeInterval(7_200))
        await secondTransport.setResult(true)
        await restarted.flushIfDue()
        self.check(storage.state.entries.isEmpty, "acknowledgment removes only durably queued batches")
    }

    private static func concurrentEventsSurviveAcknowledgment() async {
        let storage = MemoryStorage()
        let clock = TestClock(self.origin)
        let transport = TestTransport()
        await transport.hold()
        let recorder = ForkUsageRecorder(configuration: self.configured, storage: storage, transport: transport, clock: clock)
        let launch = Task { await recorder.recordLaunch() }
        await transport.waitForRequest()
        await recorder.record(.definitionRequested)
        self.check(storage.state.sealed.count == 1 && storage.state.accumulating?.features.definitionRequested == 1,
                   "events arriving during upload use a separate accumulator")
        await transport.release(true)
        await launch.value
        self.check(storage.state.sealed.isEmpty && storage.state.accumulating?.features.definitionRequested == 1,
                   "successful upload cannot erase concurrent events")
        clock.advance(3_600)
        await recorder.flushIfDue()
        let envelope = await transport.envelopes[1]
        self.check(envelope.batches.count == 1 && envelope.batches[0].launches == 0
                   && envelope.batches[0].features.definitionRequested == 1, "next upload contains only unsent event delta")
    }

    private static func utcActivityAndSleep() async {
        let storage = MemoryStorage()
        let clock = TestClock(self.origin.addingTimeInterval(86_399))
        let transport = TestTransport()
        await transport.setResult(true)
        let recorder = ForkUsageRecorder(configuration: self.configured, storage: storage, transport: transport, clock: clock)
        await recorder.recordLaunch()
        let writes = storage.writes
        await recorder.recordActiveDay()
        self.check(storage.writes == writes, "same-day heartbeat causes no duplicate batch or disk write")
        clock.advance(2)
        await recorder.recordActiveDay()
        self.check(storage.state.accumulating?.day == "2026-10-16" && storage.state.accumulating?.launches == 0,
                   "foreground crossing UTC midnight records activity without a launch")
        let beforeInactivity = storage.state
        clock.advance(4 * 86_400)
        await recorder.flushIfDue()
        let afterInactivity = await transport.envelopes.last!
        self.check(afterInactivity.batches.map(\.day) == beforeInactivity.entries.map(\.day),
                   "flushing old events never invents activity while inactive")
        await recorder.recordActiveDay()
        self.check(storage.state.accumulating?.day == "2026-10-20", "resume records current UTC day only, without sleep-day backfill")
    }

    @MainActor private static func activityBoundarySchedule() {
        self.check(ForkUsageMetrics.heartbeatDelay(after: self.origin.addingTimeInterval(86_370)) == 30,
                   "foreground heartbeat wakes at UTC midnight even within a shorter active interval")
        self.check(ForkUsageMetrics.heartbeatDelay(after: self.origin.addingTimeInterval(86_410)) == 60,
                   "normal foreground heartbeat interval is one minute")
    }

    private static func queueBoundsAndCounterSaturation() async throws {
        let storage = MemoryStorage()
        let clock = TestClock(self.origin)
        let transport = TestTransport()
        let recorder = ForkUsageRecorder(configuration: self.configured, storage: storage, transport: transport, clock: clock)
        for _ in 0..<70 {
            await recorder.record(.semanticCompletionAccepted)
            clock.advance(3_600)
        }
        self.check(storage.state.entries.count == ForkUsageLimits.maximumEntries, "offline queue evicts oldest entries at 31")
        self.check(storage.data!.count <= ForkUsageLimits.maximumBytes, "serialized local queue stays at or below 16 KiB")
        let requests = await transport.requests
        self.check(requests.allSatisfy { $0.count <= ForkUsageLimits.maximumBytes }, "all upload payloads stay at or below 16 KiB")
        clock.advance(32 * 86_400)
        await recorder.recordActiveDay()
        self.check(storage.state.entries.count == 1 && storage.state.entries[0].day == ForkUsageDay.string(clock.now()),
                   "entries older than UTC today and preceding 30 days expire")
        clock.advance(32 * 86_400)
        await recorder.flushIfDue()
        self.check(storage.state.entries.isEmpty, "explicit flush persists expiry even when no batch remains to send")
        var counts = ForkUsageFeatureCounts()
        counts.semanticCompletionAccepted = ForkUsageLimits.maximumCounter
        counts.copilotCompletionAccepted = ForkUsageLimits.maximumCounter
        counts.definitionRequested = ForkUsageLimits.maximumCounter
        var seeded = ForkUsageState(installID: UUID(), lastAttempt: clock.now(), lastActiveDay: ForkUsageDay.string(clock.now()))
        seeded.accumulating = ForkUsageBatch(batchID: UUID(), day: ForkUsageDay.string(clock.now()), appVersion: "0.2.3",
                                            launches: ForkUsageLimits.maximumCounter, features: counts)
        let full = MemoryStorage(try JSONEncoder().encode(seeded))
        let capped = ForkUsageRecorder(configuration: self.configured, storage: full, transport: TestTransport(), clock: clock)
        await capped.recordLaunch()
        for feature in ForkUsageFeature.allCases { await capped.record(feature) }
        self.check(full.state.accumulating == seeded.accumulating, "all per-batch counters saturate at 10,000")
        var invalid = seeded
        invalid.accumulating!.launches = -1
        let poisoned = MemoryStorage(try JSONEncoder().encode(invalid))
        let refused = ForkUsageRecorder(configuration: self.configured, storage: poisoned, transport: TestTransport(), clock: clock)
        await refused.recordLaunch()
        self.check(poisoned.writes == 0, "invalid persisted counters fail closed instead of entering payloads")
    }

    private static func storageFailureFailsClosed() async {
        let storage = MemoryStorage()
        storage.rejectWrites()
        let transport = TestTransport()
        let recorder = ForkUsageRecorder(configuration: self.configured, storage: storage, transport: transport)
        await recorder.recordLaunch()
        let requests = await transport.requests
        self.check(requests.isEmpty, "unwritable identity/throttle prevents sending")
        let corrupt = MemoryStorage(Data("not json".utf8))
        let broken = ForkUsageRecorder(configuration: self.configured, storage: corrupt, transport: transport)
        await broken.recordLaunch()
        self.check(corrupt.writes == 0, "corrupt persisted state is not silently replaced with a new identity")
        let oversized = MemoryStorage(Data(repeating: 32, count: ForkUsageLimits.maximumBytes + 1))
        await ForkUsageRecorder(configuration: self.configured, storage: oversized, transport: transport).recordLaunch()
        self.check(oversized.writes == 0, "oversized persisted state is rejected before JSON decoding")
        let pending = MemoryStorage()
        let delayed = TestTransport()
        await delayed.hold()
        let inFlight = ForkUsageRecorder(configuration: self.configured, storage: pending, transport: delayed)
        let task = Task { await inFlight.recordLaunch() }
        await delayed.waitForRequest()
        let before = pending.data
        pending.rejectWrites()
        await delayed.release(true)
        await task.value
        self.check(pending.data == before, "failed acknowledgment persistence retains the original retry ID and contents")
    }

    private static func realFileStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CompEditor-UsageTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ForkUsageFileStorage(url: directory.appendingPathComponent("usage.json"))
        let missing = try storage.load()
        self.check(missing == nil, "missing state returns nil after acquiring the storage lease")
        try storage.save(Data("{}".utf8))
        let saved = try storage.load()
        self.check(saved == Data("{}".utf8), "atomic file storage round-trips data")
        let attributes = try FileManager.default.attributesOfItem(atPath: storage.url.path)
        self.check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "usage file is readable only by its owner")
        try Data(repeating: 0, count: ForkUsageLimits.maximumBytes * 2).write(to: storage.url)
        let oversized = try storage.load()
        self.check(oversized?.count == ForkUsageLimits.maximumBytes + 1, "file reads are bounded even for oversized input")
    }

    private static func exclusiveStorageLease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CompEditor-UsageLease-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.json")
        let clock = TestClock(self.origin)
        let firstTransport = TestTransport()
        let secondTransport = TestTransport()
        let first = ForkUsageRecorder(configuration: self.configured, storage: ForkUsageFileStorage(url: url),
                                      transport: firstTransport, clock: clock)
        let second = ForkUsageRecorder(configuration: self.configured, storage: ForkUsageFileStorage(url: url),
                                       transport: secondTransport, clock: clock)
        await first.recordLaunch()
        let original = try Data(contentsOf: url)
        await second.recordLaunch()
        await second.record(.copilotCompletionAccepted)
        let afterward = try Data(contentsOf: url)
        self.check(afterward == original, "another app instance cannot overwrite a cached queue or batch")
        let secondRequests = await secondTransport.requests
        self.check(secondRequests.isEmpty, "another app instance cannot bypass the hourly throttle")
        let releasedURL = directory.appendingPathComponent("released.json")
        do {
            let temporaryOwner = ForkUsageFileStorage(url: releasedURL)
            try temporaryOwner.save(Data("{}".utf8))
        }
        let nextOwner = ForkUsageFileStorage(url: releasedURL)
        let restored = try nextOwner.load()
        self.check(restored == Data("{}".utf8), "storage lease is released with its owner for the next app launch")
    }

    private static func networkPolicy() async {
        let configuration = ForkUsageURLTransport.configuration()
        self.check(configuration.timeoutIntervalForRequest == 5 && configuration.timeoutIntervalForResource == 5
                   && !configuration.waitsForConnectivity, "request and total-resource deadlines are five seconds")
        self.check(configuration.httpCookieStorage == nil && configuration.urlCredentialStorage == nil
                   && configuration.urlCache == nil && !configuration.httpShouldSetCookies,
                   "transport disables cookies, credential storage and cache")
        let url = self.configured.endpoint
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url) // Never resumed.
        let rejected = await withCheckedContinuation { continuation in
            ForkUsageURLTransport().urlSession(session, task: task,
                willPerformHTTPRedirection: HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)!,
                newRequest: URLRequest(url: URL(string: "https://other.compeditor.dev/v1/usage")!)) { request in
                    continuation.resume(returning: request == nil)
                }
        }
        self.check(rejected, "redirect delegate never forwards the payload to another URL")
    }

    private static func httpAcknowledgmentPolicy() async {
        let transport = ForkUsageURLTransport {
            let configuration = ForkUsageURLTransport.configuration()
            configuration.protocolClasses = [OfflineURLProtocol.self]
            return configuration
        }
        for status in [200, 202, 204, 301, 307, 400, 409, 429, 500, 503] {
            let acknowledged = await transport.send(Data("{}".utf8), to: URL(string: "https://offline.invalid/\(status)")!)
            self.check(acknowledged == (status == 204), "only durable whole-request HTTP 204 acknowledges: \(status)")
        }
        let failed = await transport.send(Data("{}".utf8), to: URL(string: "https://offline.invalid/timeout")!)
        self.check(!failed, "transport timeout remains an unacknowledged retry")
    }
}
