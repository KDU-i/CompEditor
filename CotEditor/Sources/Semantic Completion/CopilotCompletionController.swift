// SPDX-License-Identifier: Apache-2.0
import AppKit
import CryptoKit
import SwiftUI

enum CopilotConnectionFailure: Error { case authenticationRequired, serverError }

enum CopilotConnectionPhase: Equatable {
    case off, connecting, authenticated, signInRequired, failed, timedOut
    var title: String {
        switch self {
            case .off: "OFF — 接続停止"
            case .connecting: "接続中…"
            case .authenticated: "認証済み — 接続完了"
            case .signInRequired: "GitHub認証が必要"
            case .failed: "接続失敗 — 再試行してください"
            case .timedOut: "接続タイムアウト — 再試行してください"
        }
    }
}

/// Only a checksum-pinned, app-owned arm64 native release is detected automatically.
enum CopilotBundledServer {
    static let sha256 = "fd94d41828e75ff29586a3d3b1029ff203f69fb4d947120a24979e6ac75c5df0"
    static func detect(resources: URL?) -> URL? {
        #if arch(arm64)
        guard let resources else { return nil }
        let directory = resources.appendingPathComponent("CopilotServer", isDirectory: true).standardizedFileURL
        let url = directory.appendingPathComponent("copilot-language-server")
        guard directory.resolvingSymlinksInPath() == directory, url.resolvingSymlinksInPath() == url,
              FileManager.default.isExecutableFile(atPath: url.path),
              ["LICENSE", "zod-LICENSE", "vscode-jsonrpc-License.txt", "vscode-jsonrpc-thirdpartynotices.txt"].allSatisfy({ FileManager.default.isReadableFile(atPath: directory.appendingPathComponent("Notices/" + $0).path) }),
              let stream = InputStream(url: url) else { return nil }
        stream.open(); defer { stream.close() }
        var digest = SHA256(), buffer = [UInt8](repeating: 0, count: 131072)
        while true {
            let length = stream.read(&buffer, maxLength: buffer.count)
            guard length >= 0 else { return nil }
            if length == 0 { break }
            digest.update(data: Data(buffer.prefix(length)))
        }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else { return nil }
        return url
        #else
        return nil
        #endif
    }
}

/// Explicit opt-in; credentials remain opaque to this client and are owned by the official server.
@MainActor final class CopilotCompletionController: NSObject, NSMenuItemValidation {
    static let shared = CopilotCompletionController()
    private let preferences: CopilotSessionPreferences
    private var enabled = true { didSet { refreshConnectionPresentation() } }
    private var consented = false { didSet { refreshConnectionPresentation() } }
    private var connected = false
    private var connectionApproved = false
    private var reconnect: Task<Void, Never>? { didSet { refreshConnectionPresentation() } }
    private var authFinishing = false
    private var latestKind = "Unknown"
    private var executable: URL? { didSet { refreshConnectionPresentation() } }
    private var client: LSPClient?
    private var startup: Task<LSPClient, any Error>?
    private var work: Task<Void, Never>?
    private var auth: Task<Void, Never>? { didSet { refreshConnectionPresentation() } }
    private var epoch = 0
    private var authEpoch = 0
    private var phase = CopilotConnectionPhase.signInRequired { didSet { refreshConnectionPresentation() } }
    private var status = "GitHubにサインインすると接続できます。" { didSet { refreshConnectionPresentation() } }
    private var statusItem: NSMenuItem?
    private var connectionPanel: NSPanel?
    private let connectionUI = CopilotConnectionUIModel()
    private var lastStopReason = "running"
    private var observers: [any NSObjectProtocol] = []
    private weak var view: EditorTextView?
    private struct Candidate {
        let reference: Int; let item: LSPJSON; var local: LSPJSON
        var edit: LSPText.Edit; var plan: CopilotInline.Plan?; let nextEdit: Bool
    }
    private struct Suggestions {
        var candidates: [Candidate]; var index = 0; var snapshot: String; var caret: Int; var revision: Int
        let file: URL?; let uri: URL; let languageId: String; let client: LSPClient
        var shown: Set<Int> = []; var jumped = false
    }
    private var suggestions: Suggestions?
    private var applying = false
    private var automaticSuggestions = true
    private var otherLanguages = false
    private var automaticNextEdits = false
    private var nextEditsUnavailable = false
    private var reference = 0
    private var fingerprint: (UUID, String, Int, String)?
    private var viewportOrigin: NSPoint?

    override convenience init() { self.init(defaults: .standard) }
    init(defaults: UserDefaults, executable: URL? = nil) {
        preferences = CopilotSessionPreferences(defaults: defaults)
        super.init()
        enabled = preferences.enabled
        consented = preferences.remembersContextConsent
        self.executable = executable
        refreshConnectionPresentation()
    }


    func installMenu() {
        executable = executable ?? CopilotBundledServer.detect(resources: Bundle.main.resourceURL)
        status = executable == nil ? "同梱の言語サーバーが見つかりません。公式サーバーを選択してください。" : "言語サーバーは準備済みです。GitHubの認証を確認できます。"
        let root = NSMenuItem(title: "GitHub Copilot", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: root.title)
        let stateItem = NSMenuItem(title: phase.title, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false; menu.addItem(stateItem); menu.addItem(.separator()); statusItem = stateItem
        for (title, selector) in [("公式言語サーバーを選択…", #selector(chooseServer)), ("AI補完を有効にする", #selector(toggle)), ("接続を確認", #selector(reconnectAuthentication)), ("GitHubにサインイン…", #selector(signIn)), ("サインインをキャンセル", #selector(cancelSignIn)), ("GitHubからサインアウト", #selector(signOut)), ("接続状況…", #selector(showStatus))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        func action(_ title: String, _ selector: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = []) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self; item.keyEquivalentModifierMask = modifiers; menu.addItem(item)
        }
        action("Automatic Suggestions", #selector(toggleAutomaticSuggestions))
        action("Trigger Inline Suggestion", #selector(triggerInline), key: "\\", modifiers: .option)
        action("Next Inline Suggestion", #selector(nextSuggestion), key: "]", modifiers: .option)
        action("Previous Inline Suggestion", #selector(previousSuggestion), key: "[", modifiers: .option)
        action("Accept Inline Suggestion", #selector(acceptSuggestion))
        action("Accept Next Word", #selector(acceptWord), key: String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: .command)
        action("Accept Next Line", #selector(acceptLine))
        action("Dismiss Suggestion", #selector(dismissSuggestion))
        menu.addItem(.separator())
        action("Enable Other Languages…", #selector(toggleOtherLanguages))
        action("Automatic Next Edit Suggestions (Experimental)", #selector(toggleNextEdits))
        action("Trigger Next Edit Suggestion", #selector(triggerNextEdit))
        root.submenu = menu; NSApp.mainMenu?.addItem(root)
        for name in [NSText.didChangeNotification, NSTextView.didChangeSelectionNotification, NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification, NSView.boundsDidChangeNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let editor = note.object as? EditorTextView
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard !self.applying else { return }
                    if note.name == NSText.didChangeNotification {
                        guard let editor else { return }
                        if editor === self.view { self.invalidate() }
                        if self.automaticSuggestions {
                            Task { @MainActor [weak self, weak editor] in
                                await Task.yield()
                                guard let self, let editor else { return }
                                self.requestSuggestions(in: editor, explicit: false)
                            }
                        }
                        return
                    }
                    if note.name == NSTextView.didChangeSelectionNotification {
                        guard let editor, editor === self.view else { return }
                    } else if note.name == NSView.boundsDidChangeNotification {
                        guard let clip = note.object as? NSClipView, clip === self.view?.enclosingScrollView?.contentView else { return }
                        guard self.viewportOrigin != clip.bounds.origin else { return }
                    } else if note.object is NSWindow {
                        guard (note.object as? NSWindow) === self.view?.window else { return }
                    }
                    self.invalidate()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { self.shutdownForApplicationExit() } })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { if let window, window === self?.view?.window { self?.invalidate() } }
        })
        if enabled, executable != nil { restoreAuthentication() }
        else if !enabled { phase = .off; status = "OFF。保存済みのGitHub認証は削除していません。" }
    }
    private func alert(_ title: String, _ text: String) { let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal() }
    private func refreshConnectionPresentation() {
        statusItem?.title = phase.title
        // Keep transport diagnostics out of the user-facing connection description.
        let detail = status.components(separatedBy: "\n停止分類:").first ?? status
        connectionUI.presentation = CopilotConnectionPresentation(phase: phase, detail: detail,
            enabled: enabled, consented: consented, remembersConsent: preferences.remembersContextConsent,
            serverAvailable: executable != nil, authenticating: auth != nil, reconnecting: reconnect != nil)
        guard let panel = connectionPanel else { return }
        Task { @MainActor [weak panel] in
            await Task.yield()
            guard let panel, let content = panel.contentView else { return }
            content.layoutSubtreeIfNeeded()
            let size = content.fittingSize
            guard size.width > 0, size.height > 0 else { return }
            let top = panel.frame.maxY
            panel.setContentSize(size)
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
        }
    }
    var connectionPresentation: CopilotConnectionPresentation { connectionUI.presentation }

    private func presentConnection() {
        if connectionPanel == nil {
            let panel = CopilotConnectionPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "GitHub Copilot"; panel.isReleasedWhenClosed = false
            let content = NSHostingView(rootView: CopilotConnectionView(model: connectionUI,
                toggle: { [weak self] in self?.toggle() }, check: { [weak self] in self?.reconnectAuthentication() },
                signIn: { [weak self] in self?.signIn() }, signOut: { [weak self] in self?.signOut() },
                cancel: { [weak self] in self?.cancelSignIn() }, chooseServer: { [weak self] in self?.chooseServer() },
                close: { [weak panel] in panel?.performClose(nil) }))
            panel.contentView = content
            panel.setContentSize(content.fittingSize)
            connectionPanel = panel; panel.center()
        }
        refreshConnectionPresentation(); connectionPanel?.makeKeyAndOrderFront(nil)
    }
    private func waitUntilReady(ticket: Int, owner: LSPClient) async throws {
        for _ in 0..<150 {
            try Task.checkCancellation()
            guard enabled, authEpoch == ticket, client === owner else { throw CancellationError() }
            if latestKind == "Normal", await owner.isRunning() {
                guard enabled, authEpoch == ticket, client === owner else { throw CancellationError() }
                connected = true; connectionApproved = true; phase = .authenticated; status = "GitHub認証済み。Java/Pythonで入力すると候補が出ます。既存認証は再利用されるためブラウザが開かない場合があります。"; return }
            try await Task.sleep(for: .milliseconds(100))
        }
        if latestKind == "Error" { throw CopilotConnectionFailure.serverError }
        throw LSPError.timeout
    }
    @objc private func chooseServer() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "GitHub公式のmacOS用copilot-language-serverを選択してください。ライセンスと第三者の帰属表示も一緒に保持してください。"
        guard panel.runModal() == .OK, let url = panel.url,
              url.lastPathComponent == "copilot-language-server", FileManager.default.isExecutableFile(atPath: url.path) else { return }
        useServer(url)
    }
    func useServer(_ url: URL) {
        let wasEnabled = enabled
        disable(resetConnection: true); executable = url; enabled = wasEnabled
        if enabled { phase = .signInRequired; status = "サーバー選択済み。GitHubにサインイン…を選んでください。" }
    }
    @objc private func toggle() {
        if enabled, consented { preferences.enabled = false; disable(); return }
        enabled = true
        guard confirmContextSharing() else { preferences.enabled = false; disable(); return }
        preferences.enabled = true
        if connected { phase = .authenticated; status = "既存認証を再利用しています。AI補完を有効にしました。"; return }
        restoreAuthentication(showPanel: true)
    }
    private func restoreAuthentication(showPanel: Bool = false) {
        guard enabled, executable != nil, auth == nil, reconnect == nil else { return }
        authFinishing = true; phase = .connecting; status = "GitHub Copilotに再接続しています。"
        if showPanel { presentConnection() }
        let token = authEpoch
        reconnect = Task { [weak self] in
            guard let self else { return }
            defer { if self.authEpoch == token { self.reconnect = nil } }
            do {
                let owner = try await self.prepared()
                guard self.enabled, self.authEpoch == token, !Task.isCancelled else { return }
                let result: LSPJSON
                do { result = try await owner.request("checkStatus", .object([:])) }
                catch LSPError.methodNotFound {
                    // Public signIn is the compatibility fallback. Never execute a
                    // new device-flow command from an automatic reconnect.
                    result = try await owner.request("signIn", .object([:]))
                    if result["userCode"].string != nil { throw CopilotConnectionFailure.authenticationRequired }
                }
                guard self.enabled, self.authEpoch == token, self.client === owner else { return }
                switch CopilotAccountState(result) {
                    case .authenticated:
                        self.connected = true; self.connectionApproved = true; self.phase = .authenticated
                        self.status = self.consented ? "保存済みのGitHub認証を再利用しています。" : "保存済みのGitHub認証を再利用しています。AI補完を有効にすると、文書送信への同意を確認します。"
                    case .notSignedIn: throw CopilotConnectionFailure.authenticationRequired
                    case .notAuthorized:
                        self.connected = false; self.phase = .failed; self.status = "Copilotの利用権限を確認できません。保存済み認証は変更していません。アカウントの利用条件を確認してください。"
                    case .unknown: try await self.waitUntilReady(ticket: token, owner: owner)
                }
                self.authFinishing = false
            } catch is CancellationError { }
            catch { await self.connectionFailed(error, ticket: token) }
        }
    }
    @objc private func reconnectAuthentication() { restoreAuthentication(showPanel: true) }
    private func confirmContextSharing() -> Bool {
        if consented { return true }
        let a = NSAlert(); a.messageText = "AI補完を有効にしますか？"
        a.informativeText = "入力中のJava/Python文書と周辺コードをGitHub Copilotへ送信します。ほかの言語は別途有効にする必要があります。\n\n送信が認められたコードで使用してください。オフにすると文書の同期が停止します。GitHubの認証は別に保持されます。\n\n同意を記憶すると、次回起動時もAI補完が有効になります。"
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "このMacで送信への同意を記憶する"
        a.suppressionButton?.state = .off
        a.addButton(withTitle: "有効にして送信"); a.addButton(withTitle: "キャンセル")
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        acceptContextConsent(remember: a.suppressionButton?.state == .on)
        return true
    }
    func acceptContextConsent(remember: Bool) {
        consented = true
        preferences.remembersContextConsent = remember
        preferences.enabled = true
        refreshConnectionPresentation()
    }
    private func shutdownForApplicationExit() {
        enabled = false; connected = false; authFinishing = false; invalidate(); authEpoch += 1
        auth?.cancel(); startup?.cancel(); reconnect?.cancel()
        auth = nil; startup = nil; reconnect = nil
        let old = client; client = nil
        guard let old else { LSPProcesses.copilot.stopAll(); return }
        // AppKit's termination notification is synchronous. The LSP actor and its
        // pipe reader run independently; give graceful shutdown a bounded window.
        let finished = DispatchSemaphore(value: 0)
        Task.detached { await old.shutdownAndStop(); finished.signal() }
        _ = finished.wait(timeout: .now() + 2)
        LSPProcesses.copilot.stopAll()
    }
    private func invalidate() { epoch += 1; work?.cancel(); work = nil; if view?.semanticGhost?.copilot == true { view?.semanticGhost = nil }; suggestions = nil; fingerprint = nil }
    private func disable(resetConnection: Bool = false) {
        enabled = false; connected = false; authFinishing = false; latestKind = "Unknown"; invalidate(); authEpoch += 1; auth?.cancel(); auth = nil; startup?.cancel(); startup = nil; reconnect?.cancel(); reconnect = nil
        if resetConnection { consented = false; connectionApproved = false; otherLanguages = false; automaticNextEdits = false; nextEditsUnavailable = false }
        LSPProcesses.copilot.stopAll()
        let old = client; client = nil; phase = .off; status = "コード送信とサーバーを停止しました。"; Task { await old?.stop() }
    }
    private func prepared() async throws -> LSPClient {
        guard enabled, let executable else { throw LSPError.stopped }
        if let startup { return try await startup.value }
        if let client { return client }
        let new = LSPClient(processes: .copilot); client = new
        let ticket = authEpoch
        let startup = Task { [weak self] in
            await new.setMessageHandler { [weak self, weak new] method, params in
                guard let new else { return .null }
                return await self?.message(method, params: params, owner: new, ticket: ticket) ?? .null
            }
            // No project root is advertised; only the focused document is synchronized.
            try await new.start(.init(language: .python, executable: executable.path, arguments: ["--stdio"]), workspace: URL.temporaryDirectory, copilot: true)
            return new
        }
        self.startup = startup
        do { let result = try await startup.value; try Task.checkCancellation(); guard enabled, client === new else { throw CancellationError() }; self.startup = nil; return result }
        catch { lastStopReason = await new.stopReason; await new.stop(); if client === new { client = nil; self.startup = nil }; throw error }
    }
    private func message(_ method: String, params: LSPJSON, owner: LSPClient, ticket: Int) -> LSPJSON {
        guard enabled, authEpoch == ticket, client === owner else { return .null }
        if method == "didChangeStatus" {
            let kind = params["kind"].string ?? "Unknown"
            latestKind = kind
            if kind == "Normal", (authFinishing || connected) { connected = true; connectionApproved = true; phase = .authenticated; status = "GitHub認証済み。接続完了しました。文書同期は送信同意後に有効になります。" }
            else if kind == "Error" { connected = false; phase = .failed; status = "Copilotサーバーでエラーが発生しました。保存済み認証は変更していません。接続を確認で状態を確認してください。"; invalidate() }
            else if kind == "Warning" { phase = .failed; status = "一時的な通信エラーです。ネットワークを確認して再試行してください。"; invalidate() }
            else if kind == "Inactive" { status = "現在の文書ではCopilot候補が利用できません。"; invalidate() }
            return .null
        }
        let a = NSAlert(); a.messageText = "GitHub Copilot"
        // Official account/billing messages may require an explicit action. Do not execute arbitrary commands.
        a.informativeText = String((params["message"].string ?? "Account notification").prefix(2000))
        let actions = Array((params["actions"].array ?? []).prefix(5))
        actions.forEach { a.addButton(withTitle: $0["title"].string ?? "Continue") }; a.addButton(withTitle: "Dismiss")
        let index = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return actions.indices.contains(index) ? actions[index] : .null
    }
    @objc private func signIn() {
        guard enabled, auth == nil else { return }
        guard executable != nil else { phase = .failed; status = "同梱サーバーが見つかりません。公式言語サーバーを選択…で公式実行ファイルを選んでください。"; presentConnection(); return }
        guard confirmContextSharing() else { phase = .signInRequired; status = "コード送信への同意をキャンセルしました。"; return }
        invalidate(); connected = false; authFinishing = false; latestKind = "Unknown"
        phase = .connecting; status = "公式サーバーを起動し、GitHub認証状態を確認しています…"; presentConnection()
        let token = authEpoch
        auth = Task { [weak self] in
            guard let self else { return }
            defer { if self.authEpoch == token { self.auth = nil } }
            do {
                let client = try await self.prepared()
                let result = try await client.request("signIn", .object([:]))
                try Task.checkCancellation(); guard self.enabled, self.authEpoch == token else { return }
                if let code = result["userCode"].string {
                    self.phase = .signInRequired; self.status = "ブラウザでのGitHub認可が必要です。表示されたコードを本人が入力してください。"
                    guard let command = CopilotInline.command(result["command"], name: "github.copilot.finishDeviceFlow") else { throw LSPError.unsupportedEdit }
                    let a = NSAlert(); a.messageText = "GitHubにサインイン"
                    a.informativeText = "ブラウザのGitHub画面で、次の一時コードを本人が入力してください。\n\n\(code)\n\n「ブラウザで続ける」を押すと、認可のためのブラウザを開きます。"
                    a.addButton(withTitle: "ブラウザで続ける"); a.addButton(withTitle: "キャンセル")
                    guard a.runModal() == .alertFirstButtonReturn else { self.phase = .signInRequired; self.status = "GitHub認証をキャンセルしました。"; self.authFinishing = false; return }
                    self.authFinishing = true
                    self.phase = .connecting; self.status = "ブラウザで本人がGitHub認可を完了するのを待っています（最大5分）。"
                    _ = try await client.request("workspace/executeCommand", command, timeout: 300)
                } else {
                    self.authFinishing = true
                    self.status = "既存のGitHub認証を確認しています。ブラウザが開かなくても正常です。"
                }
                try await self.waitUntilReady(ticket: token, owner: client)
                self.authFinishing = false
            } catch is CancellationError { if self.enabled, self.authEpoch == token { self.connected = false; self.authFinishing = false; self.phase = .signInRequired; self.status = "GitHub認証をキャンセルしました。" } }
            catch { await self.connectionFailed(error, ticket: token) }
        }
    }
    private func connectionFailed(_ error: any Error, ticket: Int) async {
        guard enabled, authEpoch == ticket else { return }
        let old = client
        let reason = await old?.stopReason ?? lastStopReason
        guard enabled, authEpoch == ticket, client === old else { return }
        connected = false; authFinishing = false; latestKind = "Unknown"
        if case CopilotConnectionFailure.authenticationRequired = error { phase = .signInRequired; status = "GitHub認証が必要です。GitHubにサインイン…で再試行してください。" }
        else if case LSPError.timeout = error { phase = .timedOut; status = "応答が時間内に届きませんでした。保存済み認証は変更していません。接続を確認で再試行できます。" }
        else { phase = .failed; status = "公式サーバーへの接続に失敗しました。保存済み認証は変更していません。接続を確認で再試行してください。\n停止分類: " + reason }
        client = nil; LSPProcesses.copilot.stopAll(); Task { await old?.stop() }
    }
    @objc private func cancelSignIn() {
        invalidate(); authEpoch += 1; auth?.cancel(); auth = nil; startup?.cancel(); startup = nil
        reconnect?.cancel(); reconnect = nil; connected = false; authFinishing = false; latestKind = "Unknown"
        let old = client; client = nil; LSPProcesses.copilot.stopAll(); Task { await old?.stop() }
        phase = .signInRequired; status = "GitHub認証をキャンセルしました。再試行できます。"
    }
    @objc private func signOut() {
        connected = false; connectionApproved = false; authFinishing = false; invalidate(); authEpoch += 1; auth?.cancel(); auth = nil
        phase = .signInRequired
        status = "GitHub認証が必要です。"
        guard let old = client else { return }
        let ticket = authEpoch
        phase = .connecting; status = "GitHubからサインアウトしています…"; presentConnection()
        auth = Task { [weak self] in
            guard let self else { return }
            defer { if self.authEpoch == ticket { self.auth = nil } }
            do {
                _ = try await old.request("signOut", .object([:]))
                guard self.enabled, self.authEpoch == ticket, self.client === old else { return }
                self.client = nil; self.latestKind = "Unknown"; await old.stop()
                guard self.enabled, self.authEpoch == ticket, self.client == nil else { return }
                self.phase = .signInRequired; self.status = "GitHubからサインアウトしました。"
            } catch is CancellationError { }
            catch { await self.connectionFailed(error, ticket: ticket) }
        }
    }
    @objc private func showStatus() {
        presentConnection()
    }
    private func activeEditor() -> EditorTextView? {
        (NSApp.keyWindow?.firstResponder as? EditorTextView) ?? (NSApp.mainWindow?.firstResponder as? EditorTextView)
    }
    private func eligible(_ editor: EditorTextView) -> String? {
        guard enabled, consented, connected, editor.isEditable, !editor.hasMarkedText(),
              editor.selectedRange().length == 0, editor.selectedRanges.count == 1, editor.insertionLocations.count <= 1,
              editor.window?.firstResponder === editor, (NSApp.keyWindow ?? NSApp.mainWindow) === editor.window,
              NSApp.isActive, let context = editor.semanticDocumentContext?() else { return nil }
        let language = CopilotLanguage.resolve(url: context.url, syntax: context.syntax)
        return otherLanguages || language == "java" || language == "python" ? language : nil
    }
    private func current(in editor: EditorTextView) -> Bool {
        guard let state = suggestions, self.view === editor, editor.string == state.snapshot,
              editor.selectedRange() == NSRange(location: state.caret, length: 0), editor.semanticRevision == state.revision,
              editor.semanticDocumentContext?().url == state.file, eligible(editor) == state.languageId else { return false }
        return true
    }
    @objc private func toggleAutomaticSuggestions() { automaticSuggestions.toggle(); invalidate() }
    @objc private func triggerInline() { if let editor = activeEditor() { requestSuggestions(in: editor, explicit: true) } }
    @objc private func triggerNextEdit() { if let editor = activeEditor() { requestSuggestions(in: editor, explicit: true, nextEdit: true) } }
    @objc private func nextSuggestion() { if let editor = activeEditor() { cycle(1, in: editor) } }
    @objc private func previousSuggestion() { if let editor = activeEditor() { cycle(-1, in: editor) } }
    @objc private func acceptSuggestion() { if let editor = activeEditor() { _ = accept(in: editor) } }
    @objc private func acceptWord() { if let editor = activeEditor() { _ = acceptPartial(in: editor, line: false) } }
    @objc private func acceptLine() { if let editor = activeEditor() { _ = acceptPartial(in: editor, line: true) } }
    @objc private func dismissSuggestion() { invalidate() }
    @objc private func toggleOtherLanguages() {
        if !otherLanguages {
            let dialog = NSAlert(); dialog.messageText = "Java/Python以外のAI補完を有効にしますか？"
            dialog.informativeText = "ONにすると、他の言語モードでも入力・貼り付け・削除・手動要求した文書がGitHub Copilotへ送信されます。無関係な文書やworkspace全体は同期しません。この許可は今回の起動中だけです。"
            dialog.addButton(withTitle: "Enable Other Languages"); dialog.addButton(withTitle: "Cancel")
            guard dialog.runModal() == .alertFirstButtonReturn else { return }
        }
        otherLanguages.toggle(); invalidate()
        let old = client; Task { if let uri = await old?.openCopilotDocument() { await old?.close(uri) } }
    }
    @objc private func toggleNextEdits() {
        automaticNextEdits.toggle(); invalidate()
        status = automaticNextEdits ? "inline候補がない場合、同じ文書のNext Edit Suggestionsを要求します。別の差分プレビューでTab移動→Tab採用します。" : "自動Next Edit Suggestionsを停止しました。"
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggle) { item.state = enabled && consented ? .on : .off; return true }
        if item.action == #selector(reconnectAuthentication) { return enabled && auth == nil && reconnect == nil }
        if item.action == #selector(signIn) || item.action == #selector(signOut) { return enabled && auth == nil && reconnect == nil }
        if item.action == #selector(cancelSignIn) { return auth != nil }
        if item.action == #selector(toggleAutomaticSuggestions) { item.state = automaticSuggestions ? .on : .off; return true }
        if item.action == #selector(toggleOtherLanguages) { item.state = otherLanguages ? .on : .off; return true }
        if item.action == #selector(toggleNextEdits) { item.state = automaticNextEdits ? .on : .off; return !nextEditsUnavailable }
        if item.action == #selector(triggerInline) || item.action == #selector(triggerNextEdit) {
            return activeEditor().flatMap(eligible) != nil && (item.action != #selector(triggerNextEdit) || !nextEditsUnavailable)
        }
        if let action = item.action, [#selector(nextSuggestion), #selector(previousSuggestion), #selector(acceptSuggestion), #selector(acceptWord), #selector(acceptLine), #selector(dismissSuggestion)].contains(action) {
            guard let editor = activeEditor(), current(in: editor), let state = suggestions, editor.semanticGhost?.copilot == true, editor.semanticGhostIsCurrent else { return false }
            if item.action == #selector(acceptWord) || item.action == #selector(acceptLine) { return !state.candidates[state.index].nextEdit }
            return true
        }
        return true
    }
    func typed(in editor: EditorTextView, previous: String) {
        guard editor.string != previous, automaticSuggestions, !applying else { return }
        requestSuggestions(in: editor, explicit: false)
    }
    func documentEdited(in editor: EditorTextView) { if automaticSuggestions, !applying { requestSuggestions(in: editor, explicit: false) } }
    private func requestSuggestions(in editor: EditorTextView, explicit: Bool, nextEdit: Bool = false, cycleOffset: Int = 0) {
        guard let languageId = eligible(editor) else { return }
        // Deferred typing notifications can arrive after a partial acceptance.
        // Keep its current remaining preview until another edit or explicit request.
        if !explicit, hasVisibleSuggestion(in: editor) { return }
        let snapshot = editor.string, caret = editor.selectedRange().location, file = editor.semanticDocumentContext?().url, revision = editor.semanticRevision
        if !explicit, work != nil, let queued = fingerprint,
           queued.0 == editor.semanticBufferID, queued.1 == snapshot, queued.2 == caret, queued.3 == languageId { return }
        invalidate(); self.view = editor; viewportOrigin = editor.enclosingScrollView?.contentView.bounds.origin
        fingerprint = (editor.semanticBufferID, snapshot, caret, languageId)
        let token = epoch
        let tabSize = editor.tabWidth, insertSpaces = editor.isAutomaticTabExpansionEnabled
        let uri = file ?? URL.temporaryDirectory.appendingPathComponent("compeditor-\(editor.semanticBufferID).\(languageId)")
        let selected = SemanticCompletionController.shared.selectedSuggestion(in: editor)
        let selectedContext = selected.flatMap { edit in try? LSPJSON.object(["range": CopilotInline.rangeJSON(edit.range, in: snapshot), "text": .string(edit.text)]) }
        status = explicit ? "AI候補を手動で取得しています…" : "AI候補を取得しています…"
        work = Task { [weak self, weak editor] in
            guard let self, let editor else { return }
            defer { if self.epoch == token { self.work = nil; self.fingerprint = nil } }
            do {
                if !explicit { try await Task.sleep(for: .milliseconds(50)) }
                let client = try await self.prepared()
                try Task.checkCancellation(); guard self.epoch == token, self.eligible(editor) == languageId else { return }
                var isNextEdit = nextEdit
                let result: LSPJSON
                if nextEdit { result = try await client.nextEdit(uri: uri, languageId: languageId, text: snapshot, caret: caret, tabSize: tabSize, insertSpaces: insertSpaces) }
                else { result = try await client.inlineCompletion(uri: uri, languageId: languageId, text: snapshot, caret: caret, triggerKind: explicit ? 1 : 2, selectedCompletion: selectedContext, tabSize: tabSize, insertSpaces: insertSpaces) }
                var items = result[nextEdit ? "edits" : "items"].array ?? []
                if !nextEdit, items.isEmpty, self.automaticNextEdits, !self.nextEditsUnavailable {
                    let edits = try await client.nextEdit(uri: uri, languageId: languageId, text: snapshot, caret: caret, tabSize: tabSize, insertSpaces: insertSpaces)
                    items = edits["edits"].array ?? []; isNextEdit = true
                }
                guard !Task.isCancelled, self.epoch == token, editor.string == snapshot,
                      editor.selectedRange() == NSRange(location: caret, length: 0), editor.semanticRevision == revision, editor.semanticDocumentContext?().url == file,
                      self.eligible(editor) == languageId else { return }
                var candidates: [Candidate] = []
                for item in items.prefix(20) {
                    let plan = isNextEdit ? nil : try? CopilotInline.plan(item, text: snapshot, caret: caret)
                    guard let edit = isNextEdit ? try? CopilotInline.nextEdit(item, text: snapshot) : plan?.edit else { continue }
                    if !isNextEdit, plan?.parts.isEmpty != false { continue }
                    if candidates.contains(where: { $0.edit.range == edit.range && $0.edit.text == edit.text }) { continue }
                    self.reference += 1; candidates.append(Candidate(reference: self.reference, item: item, local: item, edit: edit, plan: plan, nextEdit: isNextEdit))
                }
                guard !candidates.isEmpty else { self.status = "この位置では表示できるAI候補がありません。"; return }
                let index = (cycleOffset % candidates.count + candidates.count) % candidates.count
                self.suggestions = Suggestions(candidates: candidates, index: index, snapshot: snapshot, caret: caret, revision: revision, file: file, uri: uri, languageId: languageId, client: client)
                self.present(in: editor)
            } catch is CancellationError { }
            catch {
                guard self.epoch == token, self.enabled else { return }
                if case LSPError.methodNotFound = error { self.nextEditsUnavailable = true; self.status = "このサーバーは公開Next Edit APIに対応していません。inline completionは利用できます。" }
                else if case LSPError.stopped = error { self.connected = false; self.phase = .failed; self.status = "公式サーバーが停止しました。GitHubにサインイン…で再接続してください。"; self.client = nil }
                else if case LSPError.timeout = error { self.status = "AI候補の取得がタイムアウトしました。手動要求または入力で再試行できます。" }
                else { self.status = "AI候補の要求に失敗しました。再試行してください。" }
            }
        }
    }
    func dismissForInteraction(in editor: EditorTextView) { if view === editor { invalidate() } }
    func hasSuggestions(in editor: EditorTextView) -> Bool { current(in: editor) }
    func hasVisibleSuggestion(in editor: EditorTextView) -> Bool {
        current(in: editor) && editor.semanticGhost?.copilot == true && editor.semanticGhostIsCurrent
    }
    func ordinarySuggestionChanged(in editor: EditorTextView) { if current(in: editor) { present(in: editor) } }
    private func present(in editor: EditorTextView) {
        guard current(in: editor), var state = suggestions else { return }
        let candidate = state.candidates[state.index]
        let language = LSPLanguage(rawValue: state.languageId) ?? .python
        let old = candidate.nextEdit ? (state.snapshot as NSString).substring(with: candidate.edit.range) : nil
        applying = true
        editor.semanticGhost = SemanticGhostPreview(text: candidate.plan?.text ?? candidate.edit.text, snapshot: state.snapshot, caret: state.caret, fileURL: state.file, language: language, copilot: true, languageId: state.languageId, parts: candidate.plan?.parts ?? [], nextEdit: candidate.nextEdit, replacementRange: candidate.edit.range, replacedText: old, revision: state.revision)
        applying = false
        guard editor.semanticGhostIsCurrent else { editor.semanticGhost = nil; return }
        // Owner-requested single suggestion UI: dismiss timers, pending requests and
        // selection before Tab can be routed to an ordinary candidate. Loading alone
        // never suppresses ordinary completion.
        applying = true
        SemanticCompletionController.shared.dismissSuggestionsForCopilot(in: editor)
        editor.suppressWordCompletionForCopilot()
        applying = false
        guard current(in: editor), editor.semanticGhost?.copilot == true, editor.semanticGhostIsCurrent else { invalidate(); return }
        editor.displayIfNeeded()
        if state.shown.insert(candidate.reference).inserted {
            let owner = state.client, item = candidate.item, method = candidate.nextEdit ? "textDocument/didShowInlineEdit" : "textDocument/didShowCompletion"
            Task { try? await owner.notify(method, .object(["item": item])) }
        }
        suggestions = state; viewportOrigin = editor.enclosingScrollView?.contentView.bounds.origin
        status = candidate.nextEdit ? "次の編集の差分を表示しています。Tabで位置へ移動し、もう一度Tabで採用します。" : "AI候補 \(state.index + 1)/\(state.candidates.count) — Tab採用、⌘→部分採用、⌥[ / ⌥]切替。"
    }
    private func cycle(_ delta: Int, in editor: EditorTextView) {
        guard current(in: editor), var state = suggestions else { return }
        if state.candidates.count == 1 { requestSuggestions(in: editor, explicit: true, nextEdit: state.candidates[0].nextEdit, cycleOffset: delta); return }
        state.index = (state.index + delta + state.candidates.count) % state.candidates.count; suggestions = state; present(in: editor)
    }
    private func accept(in editor: EditorTextView) -> Bool {
        guard current(in: editor), var state = suggestions, editor.semanticGhost?.copilot == true, editor.semanticGhostIsCurrent else { return false }
        let candidate = state.candidates[state.index]
        if candidate.nextEdit, state.caret != candidate.edit.range.location, !state.jumped {
            applying = true; editor.selectedRange = NSRange(location: candidate.edit.range.location, length: 0)
            editor.scrollRangeToVisible(editor.selectedRange()); applying = false
            state.caret = editor.selectedRange().location; state.jumped = true; suggestions = state; present(in: editor); return true
        }
        invalidate(); applying = true
        let accepted = SemanticActionApplication.apply([candidate.edit], title: candidate.nextEdit ? "Accept Copilot Next Edit" : "Accept Copilot Suggestion", to: editor)
        applying = false
        if accepted {
            ForkUsageMetrics.shared.record(.copilotCompletionAccepted)
            if let command = CopilotInline.command(candidate.item["command"], name: "github.copilot.didAcceptCompletionItem") { Task { _ = try? await state.client.request("workspace/executeCommand", command) } }
            documentEdited(in: editor)
        }
        return accepted
    }
    private func acceptPartial(in editor: EditorTextView, line: Bool) -> Bool {
        guard current(in: editor), var state = suggestions, editor.semanticGhost?.copilot == true, editor.semanticGhostIsCurrent else { return false }
        let candidate = state.candidates[state.index]
        guard !candidate.nextEdit, let plan = candidate.plan, let part = plan.parts.first else { return false }
        let count = min(part.text.utf16.count, CopilotInline.partialLength(part.text, line: line))
        if count == part.text.utf16.count, plan.parts.count == 1 { return accept(in: editor) }
        let text = (state.snapshot as NSString).substring(with: NSRange(location: state.caret, length: part.offset - state.caret)) + (part.text as NSString).substring(to: count)
        let edit = LSPText.Edit(range: NSRange(location: state.caret, length: part.offset - state.caret), text: text, primary: true)
        applying = true
        let applied = SemanticActionApplication.apply([edit], title: line ? "Accept Copilot Line" : "Accept Copilot Word", to: editor)
        applying = false; guard applied else { return false }
        ForkUsageMetrics.shared.record(.copilotCompletionAccepted)
        let updated = editor.string, caret = editor.selectedRange().location
        let delta = updated.utf16.count - state.snapshot.utf16.count
        var remaining: [Candidate] = []
        for var cached in state.candidates {
            let range = NSRange(location: cached.edit.range.location, length: cached.edit.range.length + delta)
            guard var value = cached.local.object, let json = try? CopilotInline.rangeJSON(range, in: updated) else { continue }
            value["range"] = json; cached.local = .object(value)
            guard let plan = try? CopilotInline.plan(cached.local, text: updated, caret: caret), !plan.parts.isEmpty else { continue }
            cached.plan = plan; cached.edit = plan.edit; remaining.append(cached)
        }
        let owner = state.client, uri = state.uri, language = state.languageId, item = candidate.item
        let length = CopilotInline.acceptedLength(raw: item["insertText"].string ?? "", normalizedPrefixLength: caret - candidate.edit.range.location, snapshot: updated)
        Task { [weak self, weak editor] in
            guard let self, self.enabled, self.consented, self.connected, self.client === owner else { return }
            if let editor, self.view === editor, editor.string == updated, self.eligible(editor) == language { try? await owner.synchronizeDocument(uri: uri, languageId: language, text: updated) }
            guard self.enabled, self.client === owner else { return }
            if let length { try? await owner.notify("textDocument/didPartiallyAcceptCompletion", .object(["item": item, "acceptedLength": .number(length)])) }
        }
        state.candidates = remaining; state.index = remaining.firstIndex(where: { $0.reference == candidate.reference }) ?? 0
        state.snapshot = updated; state.caret = caret; state.revision = editor.semanticRevision; suggestions = remaining.isEmpty ? nil : state
        if remaining.isEmpty { editor.semanticGhost = nil; documentEdited(in: editor) } else { present(in: editor) }
        return true
    }
    func handleKey(_ event: NSEvent, in editor: EditorTextView) -> Bool {
        guard !editor.hasMarkedText() else { if view === editor { invalidate() }; return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if enabled, flags == .option, event.keyCode == 42 { requestSuggestions(in: editor, explicit: true); return true }
        if current(in: editor), flags == .option, event.keyCode == 30 { cycle(1, in: editor); return true }
        if current(in: editor), flags == .option, event.keyCode == 33 { cycle(-1, in: editor); return true }
        if flags.isEmpty, event.keyCode == 53 {
            let visible = hasVisibleSuggestion(in: editor)
            if view === editor { invalidate() }
            return visible
        }
        if flags == .command, event.keyCode == 124 { return acceptPartial(in: editor, line: false) }
        guard flags.isEmpty, event.keyCode == 48, current(in: editor), editor.semanticGhost?.copilot == true, editor.semanticGhostIsCurrent else { return false }
        SemanticCompletionController.shared.dismissSuggestionsForCopilot(in: editor)
        return accept(in: editor)
    }
}
