// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

/// Synchronous termination hook: AppKit must not exit before async actor cleanup runs.
final class LSPProcesses: @unchecked Sendable {
    static let shared = LSPProcesses()
    private let lock = NSLock()
    private var processes: [Process] = []
    private var generation = 0
    func ticket() -> Int { lock.lock(); defer { lock.unlock() }; return generation }
    func launch(_ process: Process, ticket: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard ticket == generation else { throw LSPError.stopped }
        // Serialize the short OS spawn with Off so a queued startup cannot escape termination.
        try process.run()
        processes.removeAll { !$0.isRunning }
        processes.append(process)
    }
    func stopAll() {
        lock.lock(); generation += 1; let owned = processes; processes.removeAll(); lock.unlock()
        for process in owned where process.isRunning {
            process.terminate()
            // Only exact Process objects launched by this client are terminated.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

/// One owned stdio process per enabled language and explicitly selected workspace.
/// All pipe writes run on a serial worker queue; no server work runs on the UI thread.
actor LSPClient {
    private let ownershipTicket = LSPProcesses.shared.ticket()
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let writer = DispatchQueue(label: "dev.semantic-editor.lsp-writes")
    private var framer = LSPFramer()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<LSPJSON, any Error>] = [:]
    private var stopped = false
    private var opened: [String: Int] = [:]
    private var ready = false
    private var canResolve = false
    private(set) var lastDiagnosticNotification: LSPJSON = .null
    private(set) var capabilities: LSPJSON = .null
    private var diagnosticsHandler: (@Sendable (LSPDiagnosticBatch) -> Void)?
    private var diagnosticsByURI: [String: LSPDiagnosticBatch] = [:]
    private var canNavigate = false
    private var inspectionPending: Set<String> = []
    private var canHover = false
    private var canShowSignatures = false
    private var syncKind = 1
    private var openClose = true
    private var workspace: URL?
    private var settings: LSPJSON = .null
    private var streamContinuation: AsyncStream<Data>.Continuation?

    func start(_ server: LSPConfiguration.Server, workspace: URL) async throws {
        try Task.checkCancellation()
        guard !stopped else { throw LSPError.stopped }
        self.workspace = workspace
        process.executableURL = URL(fileURLWithPath: server.executable)
        let workspaceKey = workspace.absoluteString.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let storage = URL.cachesDirectory.appendingPathComponent("SemanticEditor/LSP/\(server.language.rawValue)/\(String(workspaceKey, radix: 16))")
        if server.arguments.contains(where: { $0.contains("{workspaceStorage}") }) {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        }
        process.arguments = server.arguments.map { $0.replacingOccurrences(of: "{workspaceStorage}", with: storage.path) }
        process.currentDirectoryURL = workspace
        // Do not pass the host's environment (which can contain credentials) to servers.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        process.terminationHandler = { [weak self] _ in Task { await self?.stop() } }
        do { try LSPProcesses.shared.launch(process, ticket: ownershipTicket) } catch { stop(); throw error }
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(8)) { continuation in
            streamContinuation = continuation
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                if !bytes.isEmpty {
                    guard bytes.count <= 8 * 1024 * 1024 else {
                        continuation.finish(); Task { await self?.stop() }; return
                    }
                    if case .dropped = continuation.yield(bytes) {
                        // Fail closed on overload; never parse a stream with missing chunks.
                        continuation.finish(); Task { await self?.stop() }
                    }
                }
                else { continuation.finish() }
            }
        }
        // One async stream consumer preserves chunk order without blocking cooperative threads.
        Task { [weak self] in
            for await bytes in stream { await self?.receive(bytes) }
            await self?.stop()
        }
        errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        let settings: LSPJSON = .object([
            "python": .object(["analysis": .object(["autoSearchPaths": .bool(false), "diagnosticMode": .string("openFilesOnly"), "indexing": .bool(false), "autoImportCompletions": .bool(true)])]),
            "java": .object([
                "signatureHelp": .object(["enabled": .bool(true)]),
                "autobuild": .object(["enabled": .bool(false)]),
                "import": .object(["gradle": .object(["enabled": .bool(false)]), "maven": .object(["enabled": .bool(false)])]),
                "configuration": .object(["updateBuildConfiguration": .string("disabled")]),
                "completion": .object(["guessMethodArguments": .bool(false)]),
                "referencesCodeLens": .object(["enabled": .bool(false)])
            ])
        ])
        self.settings = settings
        let result = try await request("initialize", .object([
            "processId": .number(Int(getpid())), "rootUri": .string(workspace.absoluteString),
            "workspaceFolders": .array([.object(["uri": .string(workspace.absoluteString), "name": .string(workspace.lastPathComponent)])]),
            "capabilities": .object([
                "general": .object(["positionEncodings": .array([.string("utf-16")])]),
                "workspace": .object(["configuration": .bool(true), "applyEdit": .bool(false), "workspaceFolders": .bool(true)]),
                "textDocument": .object([
                    "publishDiagnostics": .object(["versionSupport": .bool(true)]),
                    "definition": .object(["linkSupport": .bool(true)]),
                    "codeAction": .object(["codeActionLiteralSupport": .object(["codeActionKind": .object(["valueSet": .array([.string("quickfix"), .string("source.organizeImports")])])]), "resolveSupport": .object(["properties": .array([.string("edit")])])]),
                    "hover": .object(["contentFormat": .array([.string("plaintext"), .string("markdown")])]),
                    "signatureHelp": .object(["signatureInformation": .object(["activeParameterSupport": .bool(true), "parameterInformation": .object(["labelOffsetSupport": .bool(true)]), "documentationFormat": .array([.string("plaintext"), .string("markdown")])])]),
                    "completion": .object([
                    "completionItem": .object(["snippetSupport": .bool(false), "resolveSupport": .object(["properties": .array([.string("additionalTextEdits")])])])
                ])])
            ]),
            "initializationOptions": .object(["settings": settings, "bundles": .array([])])
        ]))
        let capabilities = result["capabilities"]
        self.capabilities = capabilities
        guard capabilities["positionEncoding"] == .null || capabilities["positionEncoding"].string == "utf-16" else { stop(); throw LSPError.server("The server requires a non-UTF-16 encoding.") }
        canResolve = capabilities["completionProvider"]["resolveProvider"] == .bool(true)
        canNavigate = capabilities["definitionProvider"] == .bool(true) || capabilities["definitionProvider"].object != nil
        canHover = capabilities["hoverProvider"] == .bool(true) || capabilities["hoverProvider"].object != nil
        canShowSignatures = capabilities["signatureHelpProvider"].object != nil
        triggerCharacters = Set((capabilities["completionProvider"]["triggerCharacters"].array ?? []).compactMap(\.string))
        let sync = capabilities["textDocumentSync"]
        syncKind = sync.int ?? sync["change"].int ?? 0
        openClose = sync.int != nil || sync["openClose"] == .bool(true)
        guard [1, 2].contains(syncKind), openClose else { stop(); throw LSPError.server("The server must support open/close and full or incremental synchronization.") }
        try notify("initialized", .object([:]))
        try notify("workspace/didChangeConfiguration", .object(["settings": settings]))
        ready = true
    }

    func setDiagnosticsHandler(_ handler: @escaping @Sendable (LSPDiagnosticBatch) -> Void) { diagnosticsHandler = handler }
    func synchronizeDocument(uri: URL, language: LSPLanguage, text: String) throws { try synchronize(uri: uri, language: language, text: text) }
    func version(of uri: URL) -> Int? { opened[uri.absoluteString] }
    func diagnostics(for uri: URL) -> LSPDiagnosticBatch? { diagnosticsByURI[uri.absoluteString] }
    func definition(uri: URL, language: LSPLanguage, text: String, offset: Int) async throws -> LSPJSON {
        guard canNavigate else { return .null }
        try await synchronizeForInspection(uri: uri, language: language, text: text, offset: offset)
        return try await request("textDocument/definition", .object(["textDocument": .object(["uri": .string(uri.absoluteString)]), "position": try LSPText.position(offset, in: text)]))
    }
    func codeActions(uri: URL, language: LSPLanguage, text: String, range: NSRange) async throws -> [LSPJSON] {
        guard capabilities["codeActionProvider"] == .bool(true) || capabilities["codeActionProvider"].object != nil else { return [] }
        try await synchronizeForInspection(uri: uri, language: language, text: text, offset: range.location)
        // Explicit fixes need current diagnostics. JDT publishes after its validation barrier.
        // Await bounded server analysis on the actor, never block the UI or infer missing diagnostics.
        let wantedVersion = opened[uri.absoluteString]
        for _ in 0..<30 {
            try Task.checkCancellation()
            guard snapshots[uri.absoluteString] == text, opened[uri.absoluteString] == wantedVersion else { throw CancellationError() }
            if diagnosticsByURI[uri.absoluteString]?.version == wantedVersion { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let current = diagnosticsByURI[uri.absoluteString]
        let diagnostics = current?.snapshot == text && current?.version == opened[uri.absoluteString] ? current!.items : []
        let result = try await request("textDocument/codeAction", .object([
            "textDocument": .object(["uri": .string(uri.absoluteString)]),
            "range": .object(["start": try LSPText.position(range.location, in: text), "end": try LSPText.position(NSMaxRange(range), in: text)]),
            "context": .object(["diagnostics": .array(diagnostics), "only": .array([.string("quickfix")]), "triggerKind": .number(1)])
        ]))
        return Array((result.array ?? []).prefix(100))
    }
    func resolveAction(_ action: LSPJSON) async throws -> LSPJSON {
        if action["edit"] == .null, action["data"] != .null, capabilities["codeActionProvider"]["resolveProvider"] == .bool(true) {
            return try await request("codeAction/resolve", action)
        }
        return action
    }
    var supportsHover: Bool { canHover }
    var supportsSignatures: Bool { canShowSignatures }
    private(set) var triggerCharacters: Set<String> = []

    private func synchronize(uri: URL, language: LSPLanguage, text: String) throws {
        try Task.checkCancellation()
        guard ready, !stopped else { throw LSPError.stopped }
        let key = uri.absoluteString
        if let version = opened[key], snapshots[key] != text {
            let next = version + 1
            var change: [String: LSPJSON] = ["text": .string(text)]
            if syncKind == 2 {
                // The previous snapshot is retained to compute a full-range incremental edit.
                let previous = snapshots[key] ?? ""
                change["range"] = .object(["start": .object(["line": .number(0), "character": .number(0)]), "end": try LSPText.position((previous as NSString).length, in: previous)])
            }
            try notify("textDocument/didChange", .object([
                "textDocument": .object(["uri": .string(key), "version": .number(next)]),
                "contentChanges": .array([.object(change)])
            ]))
            opened[key] = next
        } else if opened[key] == nil {
            try notify("textDocument/didOpen", .object(["textDocument": .object([
                "uri": .string(key), "languageId": .string(language.rawValue), "version": .number(1), "text": .string(text)
            ])]))
            opened[key] = 1
        }
        if snapshots[key] != text { inspectionPending.insert(key); diagnosticsByURI.removeValue(forKey: key) }
        snapshots[key] = text
    }

    func complete(uri: URL, language: LSPLanguage, text: String, caret: Int, trigger: String? = nil) async throws -> [LSPJSON] {
        try synchronize(uri: uri, language: language, text: text)
        let key = uri.absoluteString
        let result = try await request("textDocument/completion", .object([
            "textDocument": .object(["uri": .string(key)]), "position": try LSPText.position(caret, in: text),
            "context": .object(trigger.map { ["triggerKind": .number(2), "triggerCharacter": .string($0)] } ?? ["triggerKind": .number(1)])
        ]))
        // itemDefaults are not advertised. Refuse unsupported defaults rather than silently misapply them.
        guard result["itemDefaults"] == .null else { throw LSPError.unsupportedEdit }
        return result.array ?? result["items"].array ?? []
    }
    private func synchronizeForInspection(uri: URL, language: LSPLanguage, text: String, offset: Int) async throws {
        try synchronize(uri: uri, language: language, text: text)
        let key = uri.absoluteString
        if language == .java, canNavigate, inspectionPending.contains(key) {
            // JDT LS 1.61 hover/signature handlers do not wait for document lifecycle jobs.
            // Definition does. Ignore its links: this read-only barrier never navigates,
            // opens files, executes commands, saves text or triggers a project build.
            _ = try await request("textDocument/definition", .object([
                "textDocument": .object(["uri": .string(key)]), "position": try LSPText.position(offset, in: text)
            ]))
            try Task.checkCancellation()
            if snapshots[key] == text { inspectionPending.remove(key) }
        }
    }
    func hover(uri: URL, language: LSPLanguage, text: String, offset: Int) async throws -> LSPJSON {
        try Task.checkCancellation()
        guard ready, !stopped else { throw LSPError.stopped }
        guard canHover else { return .null }
        try await synchronizeForInspection(uri: uri, language: language, text: text, offset: offset)
        return try await request("textDocument/hover", .object([
            "textDocument": .object(["uri": .string(uri.absoluteString)]), "position": try LSPText.position(offset, in: text)
        ]))
    }
    func signatures(uri: URL, language: LSPLanguage, text: String, offset: Int) async throws -> LSPJSON {
        try Task.checkCancellation()
        guard ready, !stopped else { throw LSPError.stopped }
        guard canShowSignatures else { return .null }
        try await synchronizeForInspection(uri: uri, language: language, text: text, offset: offset)
        return try await request("textDocument/signatureHelp", .object([
            "textDocument": .object(["uri": .string(uri.absoluteString)]), "position": try LSPText.position(offset, in: text),
            "context": .object(["triggerKind": .number(1), "isRetrigger": .bool(false)])
        ]))
    }
    /// A server may support hover but reject signature help at a particular source position.
    /// Preserve valid hover and the shared completion client; cancellation remains fatal.
    func signatureSupplement(uri: URL, language: LSPLanguage, text: String, offset: Int) async throws -> (value: LSPJSON, problem: String?) {
        do { return (try await signatures(uri: uri, language: language, text: text, offset: offset), nil) }
        catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            return (.null, error.localizedDescription)
        }
    }
    private var snapshots: [String: String] = [:]

    func resolve(_ item: LSPJSON) async throws -> LSPJSON {
        if canResolve { return try await request("completionItem/resolve", item) }
        return item
    }

    func close(_ uri: URL) {
        let key = uri.absoluteString
        diagnosticsByURI.removeValue(forKey: key)
        inspectionPending.remove(key)
        if opened.removeValue(forKey: key) != nil {
            try? notify("textDocument/didClose", .object(["textDocument": .object(["uri": .string(key)])]))
        }
        snapshots.removeValue(forKey: key)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; ready = false
        diagnosticsByURI.removeAll(); diagnosticsHandler = nil; lastDiagnosticNotification = .null
        streamContinuation?.finish(); streamContinuation = nil
        // Off is immediate: cancel requests and close stdin, then TERM with bounded KILL escalation.
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: LSPError.stopped) }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
        if process.isRunning {
            process.terminate()
            let ownedProcess = process
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if ownedProcess.isRunning { kill(ownedProcess.processIdentifier, SIGKILL) }
            }
        }
        opened.removeAll(); snapshots.removeAll()
    }

    func request(_ method: String, _ params: LSPJSON) async throws -> LSPJSON {
        try Task.checkCancellation()
        guard !stopped else { throw LSPError.stopped }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do { try send(.object(["jsonrpc": .string("2.0"), "id": .number(id), "method": .string(method), "params": params])) }
                catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    await self?.expire(id)
                }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func expire(_ id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: LSPError.timeout)
        try? notify("$/cancelRequest", .object(["id": .number(id)]))
    }
    private func cancel(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
        try? notify("$/cancelRequest", .object(["id": .number(id)]))
    }
    func notify(_ method: String, _ params: LSPJSON) throws {
        try send(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }
    private func send(_ message: LSPJSON) throws {
        guard !stopped else { throw LSPError.stopped }
        let data = try LSPFramer.encode(message), handle = input.fileHandleForWriting
        writer.async { [weak self] in
            do { try handle.write(contentsOf: data) }
            catch { Task { await self?.stop() } }
        }
    }
    private func receive(_ bytes: Data) {
        guard !stopped else { return }
        guard !bytes.isEmpty else { stop(); return }
        do {
            for message in try framer.append(bytes) {
                if let method = message["method"].string {
                    if method == "textDocument/publishDiagnostics" {
                        let params = message["params"]
                        lastDiagnosticNotification = params
                        if let key = params["uri"].string, let uri = URL(string: key), let version = params["version"].int,
                           version == opened[key], let snapshot = snapshots[key], let items = params["diagnostics"].array {
                            let batch = LSPDiagnosticBatch(uri: uri, version: version, snapshot: snapshot, items: Array(items.prefix(1000)))
                            diagnosticsByURI[key] = batch; diagnosticsHandler?(batch)
                        }
                        continue
                    }
                    guard message["id"] != .null else { continue }
                    let result: LSPJSON
                    if method == "workspace/configuration" {
                        result = .array((message["params"]["items"].array ?? []).map { item in
                            guard let section = item["section"].string, !section.isEmpty else { return settings }
                            return section.split(separator: ".").reduce(settings) { $0[String($1)] }
                        })
                    } else if method == "workspace/workspaceFolders" {
                        result = .array(workspace.map { [.object(["uri": .string($0.absoluteString), "name": .string($0.lastPathComponent)])] } ?? [])
                    } else if method == "client/registerCapability" || method == "client/unregisterCapability" || method == "window/workDoneProgress/create" {
                        result = .null
                    } else {
                        // Never apply workspace edits, execute commands, or offer project-supplied actions.
                        try send(.object(["jsonrpc": .string("2.0"), "id": message["id"], "error": .object(["code": .number(-32601), "message": .string("Unsupported client request")])]))
                        continue
                    }
                    try send(.object(["jsonrpc": .string("2.0"), "id": message["id"], "result": result]))
                } else if let id = message["id"].int, let continuation = pending.removeValue(forKey: id) {
                    if message["error"] != .null { continuation.resume(throwing: LSPError.server(message["error"]["message"].string ?? "Language server error")) }
                    else { continuation.resume(returning: message["result"]) }
                }
            }
        } catch { stop() }
    }
}
