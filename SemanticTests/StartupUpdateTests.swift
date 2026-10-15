import Foundation

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case response(Int, Data, Int?)
        case fail
        case stall
        case redirect(URL)
    }
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var reply: Reply = .stall
        var requests = 0
        var cancellations = 0
        func reset(_ reply: Reply) { lock.lock(); defer { lock.unlock() }; self.reply = reply; requests = 0; cancellations = 0 }
        func begin() -> Reply { lock.lock(); defer { lock.unlock() }; requests += 1; return reply }
        func stop() { lock.lock(); defer { lock.unlock() }; cancellations += 1 }
        var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (requests, cancellations) }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        switch Self.state.begin() {
        case .stall: break
        case .fail: client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .response(let status, let data, let expected):
            let headers = expected.map { ["Content-Length": String($0)] }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Two chunks exercise incremental size enforcement without relying on a Content-Length.
            client?.urlProtocol(self, didLoad: data.prefix(data.count / 2))
            client?.urlProtocol(self, didLoad: data.suffix(data.count - data.count / 2))
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let url):
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": url.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
        }
    }
    override func stopLoading() { Self.state.stop() }
}

@main struct StartupUpdateTests {
    @MainActor static func main() async throws {
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            guard value() else { fatalError(name) }
            print("PASS: " + name)
        }
        func item(_ version: String = "0.2.3", _ build: String = "859", tag: String? = nil, extra: String = "", archive: String? = nil) -> String {
            let url = archive ?? "https://github.com/KDU-i/CompEditor/releases/download/\(tag ?? "v" + version)/CompEditor.zip"
            return "<item><sparkle:shortVersionString>\(version)</sparkle:shortVersionString><sparkle:version>\(build)</sparkle:version>\(extra)<enclosure url=\"\(url)\" /></item>"
        }
        func feed(_ items: String) -> Data { Data("<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel>\(items)</channel></rss>".utf8) }
        func available(_ items: String, installed: String = "0.2.2", build: String = "858") -> ForkAvailableUpdate? {
            ForkStartupUpdateFeed.availableUpdate(in: feed(items), currentVersion: installed, currentBuild: build, systemVersion: "26.0.0")
        }
        check(available(item()) == ForkAvailableUpdate(version: "0.2.3", build: "859"), "new stable marketing version and build are offered")
        check(available(item("0.2.2", "859")) != nil, "same marketing version with newer build is offered")
        check(available(item("0.2.0", "856"), installed: "0.2.0-rc.2", build: "855") != nil, "prerelease upgrades to stable")
        check(available(item("0.2.0", "856"), installed: "0.2.0", build: "855") != nil, "historical rc with stable marketing version upgrades by build")
        check(available(item("0.2.10", "859"), installed: "0.2.9") != nil, "semantic version comparison is numeric")
        check(available(item("0.2.2+release.1", "859")) != nil, "semantic build metadata does not change precedence")
        check(available(item("0.2.3+" + String(repeating: "a", count: 65))) == nil, "oversized version label is rejected before updating the menu")
        check(available(item("0.2.3", "858")) == nil && available(item("0.2.3", "857")) == nil, "same or older bundle build is never offered")
        check(available(item("0.2.2", "861"), installed: "0.3.0-rc.1", build: "860") == nil, "higher build cannot downgrade semantic version")
        check(available(item("0.2.3-rc.1", "859")) == nil, "prerelease marketing version is rejected")
        check(available(item(tag: "v0.2.3-rc.1")) == nil, "prerelease archive tag is rejected even with stable display version")
        check(available(item(tag: "v0.2.4")) == nil, "archive tag must match display version")
        for channel in ["beta", "prerelease", "", "stable"] {
            check(available(item(extra: "<sparkle:channel>\(channel)</sparkle:channel>")) == nil, "explicit channel is excluded: \(channel)")
        }
        for version in ["", "0.2", "0.02.3", "0.2.3-", "0.2.3+", "0.2.3+bad..metadata"] {
            check(available(item(version)) == nil, "malformed marketing version is rejected: \(version)")
        }
        for build in ["", "v859", "859rc1", "-1", "1..2", "1.2.3.4", "999999999999999999999999999"] {
            check(available(item("0.2.3", build)) == nil, "malformed build is rejected: \(build)")
        }
        check(available(item("0.2.3", "858.1")) != nil, "numeric dotted bundle builds are supported")
        check(available(item("0.2.2", "858.0")) == nil, "trailing zero build components are equal")
        check(available(item(extra: "<sparkle:version>860</sparkle:version>")) == nil, "duplicate version metadata is rejected")
        check(available(item(extra: "<sparkle:informationalUpdate />")) == nil, "information-only items are excluded")
        check(available(item(archive: "https://example.invalid/archive.zip")) == nil, "foreign archive metadata is excluded")
        check(available(item(extra: "<sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>")) == nil, "unsupported minimum OS is excluded")
        check(available(item(extra: "<sparkle:maximumSystemVersion>25.0</sparkle:maximumSystemVersion>")) == nil, "unsupported maximum OS is excluded")
        check(available(item("0.3.0", "860", extra: "<sparkle:minimumSystemVersion>27</sparkle:minimumSystemVersion>") + item())?.build == "859", "unsupported newer release does not hide compatible stable release")
        check(available(item() + item("0.2.4", "860"))?.build == "860", "highest eligible bundle build is selected")
        check(available("") == nil, "empty feed is quiet")
        for data in [Data("<rss>".utf8), Data("<!DOCTYPE rss [<!ENTITY local SYSTEM 'file:///etc/passwd'>]><rss/>".utf8), Data(repeating: 32, count: ForkStartupUpdateFeed.maximumBytes + 1)] {
            check(ForkStartupUpdateFeed.availableUpdate(in: data, currentVersion: "0.2.2", currentBuild: "858", systemVersion: "26") == nil, "malformed/DTD/oversized feed is refused")
        }
        check(ForkUpdatePolicy.allowedAppcastRedirect(URL(string: "https://github.com/KDU-i/CompEditor/releases/download/v0.2.3/appcast.xml")!), "same repository fixed appcast redirect is allowed")
        check(ForkUpdatePolicy.allowedAppcastRedirect(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/123/abc?token=synthetic")!), "GitHub release CDN transport query is allowed")
        for url in ["http://github.com/KDU-i/CompEditor/releases/download/v0.2.3/appcast.xml", "https://github.com/other/CompEditor/releases/download/v0.2.3/appcast.xml", "https://example.invalid/appcast.xml", "https://release-assets.githubusercontent.com/other/appcast.xml", "https://release-assets.githubusercontent.com.evil.invalid/github-production-release-asset/x", "https://user@release-assets.githubusercontent.com/github-production-release-asset/x", "https://github.com/KDU-i/CompEditor/releases/download/v0.2.3/CompEditor.zip"] {
            check(!ForkUpdatePolicy.allowedAppcastRedirect(URL(string: url)!), "foreign/insecure/archive redirect is refused")
        }

        let suite = "CompEditorStartupUpdateTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let info: [String: Any] = ["SUFeedURL": "https://github.com/KDU-i/CompEditor/releases/latest/download/appcast.xml", "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(), "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true, "SUSignedFeedFailureExpirationInterval": 0, "SUEnableAutomaticChecks": false, "SUAllowsAutomaticUpdates": false, "SUSendProfileInfo": false]
        let policy = try ForkUpdatePolicy(info: info, identifier: "dev.local.SemanticEditor")
        func checker(timeout: TimeInterval = 0.3) -> ForkStartupUpdateChecker {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StubURLProtocol.self]
            return ForkStartupUpdateChecker(defaults: defaults, configuration: config, timeout: timeout)
        }
        func waitUntil(_ condition: @MainActor () -> Bool) async {
            for _ in 0..<300 {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
            fatalError("asynchronous check failed to finish")
        }
        var notices = 0
        let now = Date()
        StubURLProtocol.state.reset(.response(200, feed(item()), nil))
        let first = checker()
        check(first.check(policy: policy, currentVersion: "0.2.2", currentBuild: "858", systemVersion: "26", now: now) { _ in notices += 1 }, "startup schedules asynchronous metadata check")
        check(!first.check(policy: policy, currentVersion: "0.2.2", currentBuild: "858", systemVersion: "26", now: now) { _ in notices += 1 }, "duplicate startup calls do not start a second request")
        await waitUntil { !first.isChecking }
        check(notices == 1 && StubURLProtocol.state.counts.0 == 1, "successful check reports one notice with one metadata request")
        let restarted = checker()
        check(!restarted.check(policy: policy, currentVersion: "0.2.2", currentBuild: "858", systemVersion: "26", now: now.addingTimeInterval(60)) { _ in notices += 1 }, "persistent throttle survives a fresh checker/relaunch")

        for reply in [StubURLProtocol.Reply.fail, .response(503, feed(item()), nil), .response(200, Data("bad xml".utf8), nil), .response(200, Data(repeating: 32, count: ForkStartupUpdateFeed.maximumBytes + 1), nil), .response(200, feed(item()), ForkStartupUpdateFeed.maximumBytes + 1), .redirect(URL(string: "https://example.invalid/appcast.xml")!)] {
            defaults.removeObject(forKey: ForkStartupUpdateChecker.lastAttemptKey)
            StubURLProtocol.state.reset(reply)
            let failed = checker()
            failed.check(policy: policy, currentVersion: "0.2.2", currentBuild: "858", systemVersion: "26") { _ in notices += 1 }
            await waitUntil { !failed.isChecking }
            check(notices == 1, "network/status/XML/size/redirect failure finishes silently")
            check(StubURLProtocol.state.counts.0 == 1, "failed check never fetches a second URL or archive")
            check(defaults.object(forKey: ForkStartupUpdateChecker.lastAttemptKey) is Date, "failed attempt is persisted to avoid restart retry storms")
        }
        defaults.removeObject(forKey: ForkStartupUpdateChecker.lastAttemptKey)
        StubURLProtocol.state.reset(.stall)
        let stalled = checker(timeout: 0.08)
        let began = ContinuousClock.now
        stalled.check(policy: policy, currentVersion: "0.2.2", currentBuild: "858", systemVersion: "26") { _ in notices += 1 }
        var UIWorkRan = false
        Task { @MainActor in UIWorkRan = true }
        await waitUntil { !stalled.isChecking }
        await waitUntil { StubURLProtocol.state.counts.1 > 0 }
        check(began.duration(to: .now) < .seconds(1), "wall deadline cancels a stalled transport")
        check(UIWorkRan && notices == 1, "UI actor remains responsive and timeout has no notice")

        defaults.set(now, forKey: ForkStartupUpdateChecker.lastAttemptKey)
        StubURLProtocol.state.reset(.stall)
        let nextDay = checker()
        check(nextDay.check(policy: policy, currentVersion: "0.2.2", currentBuild: "858", systemVersion: "26", now: now.addingTimeInterval(ForkStartupUpdateChecker.interval)) { _ in notices += 1 }, "check resumes at the 24-hour boundary")
        await waitUntil { StubURLProtocol.state.counts.0 == 1 }
        nextDay.cancel()
        await waitUntil { StubURLProtocol.state.counts.1 > 0 }
        check(!nextDay.isChecking && notices == 1, "manual action can cancel startup without a late notice")
        defaults.set(now.addingTimeInterval(3600), forKey: ForkStartupUpdateChecker.lastAttemptKey)
        let rollback = checker()
        check(!rollback.check(policy: policy, currentVersion: "0.2.2", currentBuild: "858", systemVersion: "26", now: now) { _ in notices += 1 }, "clock rollback preserves the persistent frequency limit")
        check(StubURLProtocol.state.counts.0 == 1, "clock rollback cannot cause another startup request")
        print("Offline startup update checks complete; URLProtocol intercepted all requests. No network, signing keys, archive download or installation.")
    }
}
