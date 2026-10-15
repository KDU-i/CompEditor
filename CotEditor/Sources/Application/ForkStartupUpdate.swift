// Modified for the unofficial CompEditor fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import Foundation
import SemanticVersioning

/// Unverified availability metadata. Only the manual Sparkle flow may authorize an installation.
struct ForkAvailableUpdate: Equatable, Sendable {
    let version: String
    let build: String
}

enum ForkStartupUpdateFeed {
    static let maximumBytes = 256 * 1024
    private static let sparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"

    /// A missing/invalid version is never guessed from the appcast title or build number.
    static func version(_ raw: String) -> Version? {
        // The version is displayed in a menu; feed metadata must not create an unbounded label.
        guard raw.utf8.count <= 64 else { return nil }
        let parts = raw.split(separator: "+", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        if parts.count == 2 {
            guard parts[1].split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
            }) else { return nil }
        }
        return Version(String(parts[0]))
    }

    /// Sparkle orders CFBundleVersion independently of the displayed semantic version.
    static func build(_ raw: String) -> [UInt64]? {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let numbers = parts.compactMap { UInt64($0) }
        guard numbers.count == parts.count else { return nil }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    static func availableUpdate(in data: Data, currentVersion: String, currentBuild: String, systemVersion: String) -> ForkAvailableUpdate? {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              let installedVersion = version(currentVersion), let installedBuild = build(currentBuild),
              let system = build(systemVersion),
              let document = try? XMLDocument(data: data, options: .nodeLoadExternalEntitiesNever),
              let root = document.rootElement(), root.name == "rss",
              root.elements(forName: "channel").count == 1 else { return nil }
        var best: (update: ForkAvailableUpdate, build: [UInt64])?
        for item in root.elements(forName: "channel")[0].elements(forName: "item") {
            let elements = (item.children ?? []).compactMap { $0 as? XMLElement }
            func sparkleElements(_ name: String) -> [XMLElement] {
                elements.filter { $0.localName == name && $0.uri == sparkleNamespace }
            }
            let enclosures = item.elements(forName: "enclosure")
            guard enclosures.count == 1, let enclosure = enclosures.first,
                  sparkleElements("channel").isEmpty, sparkleElements("informationalUpdate").isEmpty,
                  let rawURL = enclosure.attribute(forName: "url")?.stringValue, let url = URL(string: rawURL),
                  ForkUpdatePolicy.allowedArchive(url),
                  enclosure.attribute(forLocalName: "installationType", uri: sparkleNamespace)?.stringValue ?? "application" == "application",
                  enclosure.attribute(forLocalName: "os", uri: sparkleNamespace)?.stringValue ?? "macos" == "macos" else { continue }
            func value(_ name: String) -> String? {
                let nodes = sparkleElements(name)
                let attribute = enclosure.attribute(forLocalName: name, uri: sparkleNamespace)?.stringValue
                guard nodes.count <= 1 else { return nil }
                let element = nodes.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let element, let attribute, element != attribute { return nil }
                return element ?? attribute
            }
            guard let rawVersion = value("shortVersionString"), let candidateVersion = version(rawVersion), !candidateVersion.isPrerelease,
                  let rawBuild = value("version"), let candidateBuild = build(rawBuild),
                  candidateVersion >= installedVersion, installedBuild.lexicographicallyPrecedes(candidateBuild) else { continue }
            // Historical candidates used a stable display version, so the fixed release tag must agree too.
            let tag = url.path.split(separator: "/")[4]
            guard tag.hasPrefix("v"), let tagVersion = version(String(tag.dropFirst())),
                  !tagVersion.isPrerelease, tagVersion == candidateVersion else { continue }
            var compatible = true
            for (name, minimum) in [("minimumSystemVersion", true), ("maximumSystemVersion", false)] {
                guard !sparkleElements(name).isEmpty else { continue }
                guard let raw = value(name), let bound = build(raw) else { compatible = false; break }
                if minimum ? system.lexicographicallyPrecedes(bound) : bound.lexicographicallyPrecedes(system) { compatible = false }
            }
            guard compatible else { continue }
            if let best, !best.build.lexicographicallyPrecedes(candidateBuild) { continue }
            best = (ForkAvailableUpdate(version: rawVersion, build: rawBuild), candidateBuild)
        }
        return best?.update
    }
}

/// One attempt per launch, with a persistent limit that also covers failed/offline attempts.
@MainActor final class ForkStartupUpdateChecker {
    nonisolated static let lastAttemptKey = "CompEditorStartupUpdateLastAttempt"
    nonisolated static let interval: TimeInterval = 24 * 60 * 60
    nonisolated static let timeout: TimeInterval = 8
    private let defaults: UserDefaults
    private let configuration: URLSessionConfiguration
    private let timeout: TimeInterval
    private var attempted = false
    private var generation: UUID?
    private var download: ForkAppcastDownload?
    private(set) var isChecking = false

    init(defaults: UserDefaults = .standard, configuration: URLSessionConfiguration = .ephemeral, timeout: TimeInterval = ForkStartupUpdateChecker.timeout) {
        self.defaults = defaults
        self.configuration = configuration
        self.timeout = timeout
    }

    /// Returns immediately; the callback runs on the main actor only when a newer stable build is found.
    @discardableResult func check(policy: ForkUpdatePolicy, currentVersion: String, currentBuild: String, systemVersion: String, now: Date = Date(), onAvailable: @escaping @MainActor @Sendable (ForkAvailableUpdate) -> Void) -> Bool {
        guard !attempted else { return false }
        attempted = true
        guard ForkStartupUpdateFeed.version(currentVersion) != nil, ForkStartupUpdateFeed.build(currentBuild) != nil else { return false }
        if let last = defaults.object(forKey: Self.lastAttemptKey) as? Date {
            let elapsed = now.timeIntervalSince(last)
            // A backwards clock must not turn repeated relaunches into repeated network attempts.
            if elapsed < Self.interval { return false }
        }
        defaults.set(now, forKey: Self.lastAttemptKey)
        let generation = UUID()
        self.generation = generation
        isChecking = true
        let download = ForkAppcastDownload(configuration: configuration, timeout: timeout) { [weak self] result in
            // Both parsing and network work stay off the UI actor.
            let available = (try? result.get()).flatMap {
                ForkStartupUpdateFeed.availableUpdate(in: $0, currentVersion: currentVersion, currentBuild: currentBuild, systemVersion: systemVersion)
            }
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.generation = nil
                self.download = nil
                self.isChecking = false
                if let available { onAvailable(available) }
            }
        }
        self.download = download
        download.start(url: policy.feed)
        return true
    }

    func cancel() {
        generation = nil
        isChecking = false
        download?.cancel()
        download = nil
    }
}

/// Mutable transport state is confined to queue, including URLSession delegate calls and its deadline.
private final class ForkAppcastDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.local.SemanticEditor.startup-appcast", qos: .utility)
    private let configuration: URLSessionConfiguration
    private let timeout: TimeInterval
    private let completion: @Sendable (Result<Data, any Error>) -> Void
    private var session: URLSession?
    private var timer: (any DispatchSourceTimer)?
    private var deadline = DispatchTime.now()
    private var data = Data()
    private var finished = false
    private var redirects = 0

    init(configuration: URLSessionConfiguration, timeout: TimeInterval, completion: @escaping @Sendable (Result<Data, any Error>) -> Void) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.timeout = timeout
        self.completion = completion
    }

    func start(url: URL) {
        queue.async { [self] in
            guard !finished else { return }
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            configuration.waitsForConnectivity = false
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            delegateQueue.underlyingQueue = queue
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            deadline = .now() + timeout
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: deadline)
            timer.setEventHandler { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
            self.timer = timer
            timer.resume()
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            request.setValue("application/rss+xml, application/xml", forHTTPHeaderField: "Accept")
            session?.dataTask(with: request).resume()
        }
    }

    func cancel() { queue.async { [self] in finish(.failure(URLError(.cancelled))) } }

    private func finish(_ result: Result<Data, any Error>) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        session?.invalidateAndCancel()
        session = nil
        completion(result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        redirects += 1
        guard !finished, redirects <= 3, let url = request.url, ForkUpdatePolicy.allowedAppcastRedirect(url) else {
            completionHandler(nil)
            finish(.failure(URLError(.redirectToNonExistentLocation)))
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard !finished, let response = response as? HTTPURLResponse, response.statusCode == 200,
              let url = response.url, ForkUpdatePolicy.allowedAppcastRedirect(url),
              response.expectedContentLength <= Int64(ForkStartupUpdateFeed.maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard !finished else { return }
        guard chunk.count <= ForkStartupUpdateFeed.maximumBytes - data.count else {
            finish(.failure(URLError(.dataLengthExceedsMaximum)))
            return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)) }
        else if DispatchTime.now() >= deadline { finish(.failure(URLError(.timedOut))) }
        else { finish(.success(data)) }
    }
}
