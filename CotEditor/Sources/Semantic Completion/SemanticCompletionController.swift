// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import AppKit
import LineEnding

/// App-owned known servers with conservative document workspaces and persistent controls.
@MainActor final class SemanticCompletionController: NSObject, NSMenuItemValidation, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = SemanticCompletionController()
    private let preferences = LSPSemanticPreferences(defaults: .standard)
    private var clientWorkspaces: [LSPLanguage: URL] = [:]
    private var routingCache: [LSPLanguage: (file: URL?, buffer: UUID, route: LSPWorkspaceRoute, server: LSPConfiguration.Server)] = [:]
    private var debouncePolicy = LSPDebouncePolicy()
    private var ghostRow: Int?
    private var lastProblem: [LSPLanguage: String] = [:]
    private var enabled: Set<LSPLanguage> {
        get { Set(LSPLanguage.allCases.filter { preferences.isEnabled($0) }) }
        set { for language in LSPLanguage.allCases { preferences.setEnabled(newValue.contains(language), for: language) } }
    }
    private var clients: [LSPLanguage: LSPClient] = [:]
    private var tasks: [LSPLanguage: Task<LSPClient, any Error>] = [:]
    private let trackedViews = NSHashTable<EditorTextView>.weakObjects()
    private var diagnosticContexts: [UUID: LSPDiagnosticStamp] = [:]
    private var diagnosticTasks: [UUID: Task<Void, Never>] = [:]
    private var assistanceTask: Task<Void, Never>?
    private var signatureTask: Task<Void, Never>?
    private var signaturePanel: SemanticCandidatePanel?
    private weak var signatureView: EditorTextView?
    private var actionChoices: [ActionChoice] = []
    private var jumpChoices: [JumpChoice] = []
    private var navigationBack: [(view: WeakEditor, range: NSRange, file: URL?, snapshot: String)] = []
    private struct WeakEditor { weak var view: EditorTextView? }
    private struct ActionChoice {
        let view: WeakEditor; let snapshot: String; let file: URL?; let selection: NSRange
        let language: LSPLanguage; let generation: Int; let title: String; let edits: [LSPText.Edit]
    }
    private struct JumpChoice { let source: WeakEditor; let snapshot: String; let selection: NSRange; let file: URL?; let generation: Int; let location: LSPAssistance.Location; let root: URL }
    private var generation = 0
    private var hoverTask: Task<Void, Never>?
    private var hoverEpoch = 0
    private var hoverStamp: LSPHoverStamp?
    private weak var hoverView: EditorTextView?
    private var hoverPanel: SemanticCandidatePanel?
    private var completionInFlight = false
    private var completionTask: Task<Void, Never>?
    private var choices: [Choice] = []
    private var automatic: Bool {
        get { preferences.automatic }
        set { preferences.automatic = newValue }
    }
    private var debounce: Task<Void, Never>?
    private var automaticPanel: SemanticCandidatePanel?
    private var candidateTable: NSTableView?
    private var applyingCompletion = false
    private var footerBoundary: NSLayoutConstraint?
    private var detailHeight: CGFloat = 24
    private var detailLabel: NSTextField?
    private weak var targetView: EditorTextView?
    private var observers: [NSObjectProtocol] = []
    private struct Choice {
        let item: LSPJSON
        let ghost: String?
        let client: LSPClient
        let snapshot: String
        let selection: NSRange
        let fallback: NSRange
        let generation: Int
        let fileURL: URL?
        let language: LSPLanguage
    }

    func installMenu() {
        let root = NSMenuItem(title: "Semantic Completion", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: root.title)
        func add(_ title: String, _ action: Selector, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            if !key.isEmpty { item.keyEquivalentModifierMask = [.command, .shift] }
            menu.addItem(item)
        }
        add("Enable Semantic Completion", #selector(toggleGlobal))
        menu.addItem(.separator())
        for language in LSPLanguage.allCases {
            let item = NSMenuItem(title: "Enable \(language.rawValue.capitalized)", action: #selector(toggleLanguage(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = language.rawValue
            menu.addItem(item)
        }
        add("Show Automatically While Typing", #selector(toggleAutomatic))
        add("Turn All Off", #selector(turnOff))
        add("Server Status…", #selector(serverStatus))
        menu.addItem(.separator())
        add("Complete Semantically", #selector(complete), key: " ")
        add("Go to Definition", #selector(goToDefinition))
        add("Go Back", #selector(goBack))
        add("Show Parameter Hints", #selector(showParameterHints))
        add("Quick Fix / Add Import…", #selector(quickFix))
        add("Show Diagnostics…", #selector(showDiagnostics))
        root.submenu = menu
        NSApp.mainMenu?.addItem(root)
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                // Open panels and menu tracking windows also close; only document windows
                // end editor sessions. Canceling setup or dismissing a menu must not cancel requests.
                guard let window = notification.object as? NSWindow,
                      window.windowController?.document != nil else { return }
                self?.reset()
            }
        })
        for name in [NSText.didChangeNotification, NSTextView.didChangeSelectionNotification, NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, !self.applyingCompletion else { return }
                    if let text = notification.object as? EditorTextView {
                        // Editor changes cancel automatic and manual stale work; setup fields do not.
                        if self.targetView === text || self.hoverView === text || self.signatureView === text || self.debounce != nil { self.invalidateAutomatic() }
                    } else if notification.object is NSWindow || name == NSApplication.didResignActiveNotification { self.invalidateAutomatic() }
                }
            })
        }
        for name in [NSView.boundsDidChangeNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let clip = notification.object as? NSClipView, clip.documentView === self.hoverView || clip.documentView === self.signatureView { self.cancelHover(); self.signatureTask?.cancel(); self.signatureTask = nil; self.signaturePanel?.orderOut(nil) }
                    else if let window = notification.object as? NSWindow, window === self.hoverView?.window || window === self.signatureView?.window { self.cancelHover(); self.signatureTask?.cancel(); self.signatureTask = nil; self.signaturePanel?.orderOut(nil) }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        })
    }

    @objc private func toggleGlobal() {
        preferences.globallyEnabled.toggle()
        reset()
        if let view = activeEditor() { track(view) }
    }
    @objc private func serverStatus() {
        let resources = Bundle.main.resourceURL
        let issues = LSPLanguage.allCases.map { language -> String in
            let present = resources.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("SemanticServers/manifest.json").path) } ?? false
            return "\(language.rawValue.capitalized): " + (lastProblem[language] ?? (present ? "bundled; starts when needed" : "bundled resources missing; rebuild with Scripts/build-semantic-editor.sh"))
        }
        showError(LSPError.server(issues.joined(separator: "\n")))
    }

    @objc private func toggleLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = LSPLanguage(rawValue: raw) else { return }
        if enabled.contains(language) { enabled.remove(language) }
        else { enabled.insert(language) }
        // Invalidates in-flight results, and stops all owned processes before lazy restart.
        reset()
        if let view = activeEditor() { track(view) }
    }
    @objc private func toggleAutomatic() {
        automatic.toggle()
        invalidateAutomatic()
    }
    @objc private func turnOff() { preferences.globallyEnabled = false; reset() }
    func shutdown() { reset() }
    private func reset() { invalidateAutomatic(); stopClients() }
    private func stopClients(cancelDiagnostics: Bool = true) {
        if cancelDiagnostics { diagnosticTasks.values.forEach { $0.cancel() }; diagnosticTasks.removeAll() }
        diagnosticContexts.removeAll()
        for view in trackedViews.allObjects { view.semanticDiagnostics = nil }
        LSPProcesses.shared.stopAll()
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        for client in clients.values { Task { await client.stop() } }
        clients.removeAll()
        clientWorkspaces.removeAll()
        routingCache.removeAll()
    }

    private func language(for view: EditorTextView) -> LSPLanguage? {
        let context = view.semanticDocumentContext?()
        if let url = context?.url {
            return LSPLanguage.allCases.first { $0.fileExtension == url.pathExtension.lowercased() }
        }
        return LSPLanguage.allCases.first { $0.rawValue.caseInsensitiveCompare(context?.syntax ?? "") == .orderedSame }
    }

    func cancelHover() {
        hoverEpoch += 1; hoverTask?.cancel(); hoverTask = nil
        hoverStamp = nil; hoverView = nil
        if let hoverPanel { hoverPanel.orderOut(nil); hoverPanel.parent?.removeChildWindow(hoverPanel) }
    }
    private func hoverAllowed(in view: EditorTextView) -> Bool {
        guard preferences.globallyEnabled, let language = language(for: view), enabled.contains(language),
              !view.hasMarkedText(), view.selectedRange().length == 0, view.selectedRanges.count == 1,
              view.insertionLocations.count <= 1, NSEvent.pressedMouseButtons == 0,
              !view.inLiveResize, view.layoutOrientation == .horizontal,
              NSApp.isActive, NSApp.keyWindow === view.window,
              automaticPanel?.isVisible != true, signaturePanel?.isVisible != true, !completionInFlight else { return false }
        return NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == view.window?.windowNumber
    }
    private func hoverIsCurrent(_ stamp: LSPHoverStamp, in view: EditorTextView, language: LSPLanguage) -> Bool {
        guard !Task.isCancelled, hoverAllowed(in: view), hoverView === view, self.language(for: view) == language,
              let window = view.window else { return false }
        let pointer = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return stamp.matches(epoch: hoverEpoch, generation: generation, snapshot: view.string,
                             fileURL: view.semanticDocumentContext?().url, symbol: view.semanticHoverTarget(at: pointer)?.symbol)
    }
    func hoverMoved(in view: EditorTextView, pointInWindow: NSPoint) {
        guard hoverAllowed(in: view), let language = language(for: view), let target = view.semanticHoverTarget(at: pointInWindow) else { cancelHover(); return }
        let snapshot = view.string, fileURL = view.semanticDocumentContext?().url
        if hoverView === view, hoverStamp?.matches(epoch: hoverEpoch, generation: generation, snapshot: snapshot, fileURL: fileURL, symbol: target.symbol) == true { return }
        cancelHover()
        let stamp = LSPHoverStamp(epoch: hoverEpoch, generation: generation, snapshot: snapshot, fileURL: fileURL, symbol: target.symbol)
        hoverStamp = stamp; hoverView = view
        let bufferID = view.semanticBufferID
        hoverTask = Task { [weak self, weak view] in
            guard let self, let view else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard self.hoverIsCurrent(stamp, in: view, language: language) else { return }
                let (client, uri) = try await self.preparedClient(fileURL: fileURL, bufferID: bufferID, language: language, allowCachedRoute: true, token: stamp.generation)
                guard self.hoverIsCurrent(stamp, in: view, language: language) else { return }
                let hover = try await client.hover(uri: uri, language: language, text: snapshot, offset: target.symbol.location)
                guard self.hoverIsCurrent(stamp, in: view, language: language) else { return }
                // Render valid hover immediately; optional signatures must not delay or destroy it.
                let initialText = await Task.detached { LSPHoverPresentation.text(hover: hover) }.value
                guard self.hoverIsCurrent(stamp, in: view, language: language) else { return }
                if let initialText { self.showHover(text: initialText, in: view, rect: target.rect) }
                let call = await Task.detached { LSPHoverPresentation.callOffset(in: snapshot, symbol: target.symbol) }.value
                var signatures: LSPJSON = .null
                if let call {
                    guard self.hoverIsCurrent(stamp, in: view, language: language) else { return }
                    let supplement = try await client.signatureSupplement(uri: uri, language: language, text: snapshot, offset: call)
                    signatures = supplement.value
                    if let problem = supplement.problem, self.hoverIsCurrent(stamp, in: view, language: language) {
                        self.lastProblem[language] = "Optional signature information: " + problem
                    }
                }
                let capturedSignatures = signatures
                let text = await Task.detached { LSPHoverPresentation.text(hover: hover, signatures: capturedSignatures) }.value
                guard self.hoverIsCurrent(stamp, in: view, language: language), let text else { return }
                self.showHover(text: text, in: view, rect: target.rect)
            } catch is CancellationError { }
            catch {
                guard self.hoverIsCurrent(stamp, in: view, language: language) else { return }
                self.lastProblem[language] = error.localizedDescription
                if let client = self.clients.removeValue(forKey: language) { await client.stop() }
                self.tasks.removeValue(forKey: language); self.clientWorkspaces.removeValue(forKey: language)
            }
        }
    }
    private func showHover(text: String, in view: EditorTextView, rect: NSRect) {
        guard let window = view.window else { return }
        let available = (window.screen?.visibleFrame ?? .zero).intersection(window.frame)
        guard available.width >= 200, available.height >= 60 else { return }
        let width = min(CGFloat(440), available.width)
        let surface = SemanticHoverView(text: text, width: width)
        surface.appearance = view.effectiveAppearance
        let height = min(max(surface.fittingSize.height, 36), min(260, available.height))
        let anchor = window.convertToScreen(view.convert(rect, to: nil))
        let x = min(max(anchor.minX, available.minX), available.maxX - width)
        let proposedY = anchor.minY - height - 4 >= available.minY ? anchor.minY - height - 4 : anchor.maxY + 4
        let y = min(max(proposedY, available.minY), available.maxY - height)
        let frame = NSRect(x: x, y: y, width: width, height: height)
        guard !frame.intersects(anchor), !frame.contains(NSEvent.mouseLocation) else { return }
        let panel = hoverPanel ?? SemanticCandidatePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hasShadow = true; panel.isFloatingPanel = true; panel.hidesOnDeactivate = true; panel.isReleasedWhenClosed = false
        panel.contentView = surface; panel.appearance = view.effectiveAppearance
        panel.setFrame(frame, display: true)
        if panel.parent !== window { panel.parent?.removeChildWindow(panel); window.addChildWindow(panel, ordered: .above) }
        hoverPanel = panel; panel.orderFront(nil)
    }

    private func preparedClient(fileURL: URL?, bufferID: UUID, language: LSPLanguage, allowCachedRoute: Bool, token: Int) async throws -> (LSPClient, URL) {
        let resources = Bundle.main.resourceURL
        let cache = URL.cachesDirectory.appendingPathComponent("SemanticEditor/LSP", isDirectory: true)
        let cached = allowCachedRoute ? routingCache[language] : nil
        let routingTask = Task.detached { () -> (LSPWorkspaceRoute, LSPConfiguration.Server) in
            if let cached, cached.file == fileURL, cached.buffer == bufferID { return (cached.route, cached.server) }
            guard let resources else { throw LSPError.server("Bundled server resources are unavailable.") }
            let route = try LSPWorkspaceRouter.route(fileURL: fileURL, bufferID: bufferID, language: language, cache: cache)
            let server = try LSPBundledServers.server(language, resources: resources, storage: route.storage)
            return (route, server)
        }
        let (route, server) = try await withTaskCancellationHandler { try await routingTask.value } onCancel: { routingTask.cancel() }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        if let previous = clientWorkspaces[language], previous != route.workspace { stopClients(cancelDiagnostics: false) }
        routingCache[language] = (fileURL, bufferID, route, server)
        let workspace = route.workspace, uri = route.uri
        let client: LSPClient
        if let existing = clients[language] { client = existing }
        else {
            let new = LSPClient()
            clients[language] = new
            clientWorkspaces[language] = workspace
            let startup = Task {
                await new.setDiagnosticsHandler { [weak self, weak new] batch in
                    Task { @MainActor in if let new { await self?.acceptDiagnostics(batch, language: language, client: new) } }
                }
                do { try await new.start(server, workspace: workspace); return new }
                catch { await new.stop(); throw error }
            }
            tasks[language] = startup
            client = new
        }
        if let startup = tasks[language] {
            do { _ = try await startup.value }
            catch { if clients[language] !== client { throw CancellationError() }; throw error }
            try Task.checkCancellation()
            guard generation == token, clients[language] === client, clientWorkspaces[language] == workspace else { throw CancellationError() }
            tasks.removeValue(forKey: language)
        }
        try Task.checkCancellation()
        guard clients[language] === client, clientWorkspaces[language] == workspace else { throw CancellationError() }
        return (client, uri)
    }

    @objc private func complete() { invalidateAutomatic(); requestCompletion(automatic: false) }

    private func requestCompletion(automatic: Bool, trigger: String? = nil) {
        // Menu accessibility actions may run while the app's main document is not key.
        guard let view = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder as? EditorTextView,
              preferences.globallyEnabled, let language = language(for: view), enabled.contains(language),
              view.isEditable, !view.hasMarkedText(),
              view.selectedRanges.count == 1, view.insertionLocations.count <= 1,
              view.selectedRange().length == 0 else { if !automatic { NSSound.beep() }; return }
        let fileURL = view.semanticDocumentContext?().url
        let snapshot = view.string, selection = view.selectedRange(), fallback = view.rangeForUserCompletion
        let token = generation
        targetView = view
        completionTask?.cancel()
        completionInFlight = true
        let bufferID = view.semanticBufferID
        completionTask = Task { [weak self, weak view] in
            guard let self else { return }
            defer { if self.generation == token { self.completionInFlight = false } }
            guard let view else { return }
            do {
                let (client, uri) = try await self.preparedClient(fileURL: fileURL, bufferID: bufferID, language: language, allowCachedRoute: automatic, token: token)
                let effectiveTrigger: String?
                if automatic {
                    guard let context = LSPAutomaticContext.trigger(text: snapshot, caret: selection.location, characters: await client.triggerCharacters) else { return }
                    effectiveTrigger = context.character
                } else { effectiveTrigger = trigger }
                try Task.checkCancellation()
                guard self.generation == token else { return }
                let items = try await client.complete(uri: uri, language: language, text: snapshot, caret: selection.location, trigger: effectiveTrigger)
                let preparation = Task.detached {
                    LSPPresentation.candidates(items, text: snapshot, fallback: fallback, caret: selection.location)
                }
                let usable = await withTaskCancellationHandler {
                    await preparation.value
                } onCancel: { preparation.cancel() }
                guard !Task.isCancelled, self.generation == token, view.string == snapshot,
                      view.selectedRange() == selection, !view.hasMarkedText(), view.window?.firstResponder === view,
                      (NSApp.keyWindow ?? NSApp.mainWindow) === view.window,
                      self.language(for: view) == language,
                      view.semanticDocumentContext?().url == fileURL else { return }
                self.lastProblem.removeValue(forKey: language)
                self.choices = usable.map { Choice(item: $0.item, ghost: $0.ghost, client: client, snapshot: snapshot, selection: selection, fallback: fallback, generation: token, fileURL: fileURL, language: language) }
                guard !self.choices.isEmpty else { if !automatic { NSSound.beep() }; return }
                self.targetView = view
                self.showAutomaticCandidates(in: view, selection: selection)
                self.updateGhost(in: view)
            } catch is CancellationError { }
            catch {
                guard self.generation == token, !Task.isCancelled else { return }
                if let client = self.clients.removeValue(forKey: language) { await client.stop() }
                self.tasks.removeValue(forKey: language)
                self.clientWorkspaces.removeValue(forKey: language)
                self.lastProblem[language] = error.localizedDescription
                if !automatic { self.showError(error) }
            }
        }
    }

    private func insertChoice(_ sender: NSMenuItem, expectedPreview: String? = nil) {
        guard choices.indices.contains(sender.tag), let view = targetView else { return }
        let choice = choices[sender.tag]
        automaticPanel?.orderOut(nil)
        view.semanticGhost = nil; ghostRow = nil
        completionTask?.cancel()
        completionInFlight = true
        completionTask = Task { [weak self, weak view] in
            guard let self else { return }
            defer { if self.generation == choice.generation { self.completionInFlight = false } }
            guard let view else { return }
            do {
                let item = try await choice.client.resolve(choice.item)
                guard !Task.isCancelled, self.generation == choice.generation,
                      view.string == choice.snapshot, view.selectedRange() == choice.selection,
                      view.window?.firstResponder === view,
                      (NSApp.keyWindow ?? NSApp.mainWindow) === view.window, !view.hasMarkedText(),
                      view.selectedRanges.count == 1, view.insertionLocations.count <= 1,
                      self.language(for: view) == choice.language,
                      view.semanticDocumentContext?().url == choice.fileURL else { return }
                let (checked, resolvedPreview) = try await Task.detached {
                    let checked = try LSPText.edits(item, text: choice.snapshot, fallback: choice.fallback, caret: choice.selection.location)
                    return (checked, expectedPreview == nil ? nil : LSPPresentation.ghost(edits: checked, text: choice.snapshot, caret: choice.selection.location))
                }.value
                // Revalidate after worker computation as well as after the server response.
                guard !Task.isCancelled, self.generation == choice.generation,
                      view.string == choice.snapshot, view.selectedRange() == choice.selection,
                      view.selectedRanges.count == 1, view.insertionLocations.count <= 1,
                      view.window?.firstResponder === view,
                      (NSApp.keyWindow ?? NSApp.mainWindow) === view.window, !view.hasMarkedText(),
                      self.language(for: view) == choice.language,
                      view.semanticDocumentContext?().url == choice.fileURL else { return }
                if let expectedPreview {
                    guard let resolvedPreview,
                          resolvedPreview.utf16.elementsEqual(expectedPreview.utf16) else { self.invalidateAutomatic(); return }
                }
                let edits = checked.map { LSPText.Edit(range: $0.range, text: $0.text.replacingLineEndings(with: view.lineEnding), primary: $0.primary) }
                let primary = edits.first { $0.primary }!
                let shift = edits.filter { $0.range.location < primary.range.location }.reduce(0) { $0 + ($1.text as NSString).length - $1.range.length }
                let selection = NSRange(location: primary.range.location + (primary.text as NSString).length + shift, length: 0)
                self.applyingCompletion = true
                defer { self.applyingCompletion = false }
                view.breakUndoCoalescing()
                _ = view.replace(with: edits.map(\.text), ranges: edits.map(\.range), selectedRanges: [selection], actionName: "Semantic Completion")
                view.breakUndoCoalescing()
            } catch is CancellationError { }
            catch { if !Task.isCancelled, self.generation == choice.generation { self.showError(error) } }
        }
    }

    // No tracking loop and no key window: text input always stays in the editor.
    private func showAutomaticCandidates(in view: EditorTextView, selection: NSRange) {
        let panel = automaticPanel ?? SemanticCandidatePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hasShadow = true; panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true; panel.isReleasedWhenClosed = false
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("candidate"))
        column.width = SemanticSuggestStyle.width - 2; table.addTableColumn(column)
        table.style = .plain; table.usesAutomaticRowHeights = false; table.rowSizeStyle = .custom
        table.headerView = nil; table.rowHeight = SemanticSuggestStyle.rowHeight; table.allowsEmptySelection = true
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear; table.selectionHighlightStyle = .regular
        table.dataSource = self; table.delegate = self; table.target = self
        table.action = #selector(clickCandidate)
        table.setAccessibilityLabel("Semantic Completion Candidates")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false; scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0); scroll.documentView = table
        let surface = SemanticSuggestSurface(); surface.wantsLayer = true
        surface.layer?.cornerRadius = 2; surface.layer?.masksToBounds = true
        let footer = NSTextField(wrappingLabelWithString: "Tab accept preview   ↑ ↓ alternatives   Esc dismiss")
        footer.font = .systemFont(ofSize: 11); footer.textColor = SemanticSuggestStyle.foreground.withAlphaComponent(0.7)
        footer.maximumNumberOfLines = 3
        let separator = NSBox(); separator.boxType = .separator
        for child in [scroll, separator, footer] { child.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(child) }
        let boundary = separator.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -24)
        footerBoundary = boundary; detailHeight = 24
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: surface.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: 0),
            separator.leadingAnchor.constraint(equalTo: surface.leadingAnchor), separator.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            boundary, separator.heightAnchor.constraint(equalToConstant: 1),
            footer.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 10), footer.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -10),
            footer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 5), footer.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -5)
        ])
        panel.contentView = surface; panel.appearance = view.effectiveAppearance
        detailLabel = footer
        var actual = selection
        let caret = view.firstRect(forCharacterRange: selection, actualRange: &actual)
        let screen = (view.window?.screen?.visibleFrame ?? .zero).intersection(view.window?.frame ?? .zero)
        guard screen.width >= 200, screen.height >= 80 else { return }
        let height = min(CGFloat(min(12, choices.count)) * SemanticSuggestStyle.rowHeight + 26, screen.height)
        let width = min(SemanticSuggestStyle.width, screen.width)
        let x = min(max(caret.minX, screen.minX), screen.maxX - width)
        let y = min(max(caret.minY - height >= screen.minY ? caret.minY - height : caret.maxY, screen.minY), screen.maxY - height)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        if panel.parent !== view.window { panel.parent?.removeChildWindow(panel); view.window?.addChildWindow(panel, ordered: .above) }
        automaticPanel = panel; candidateTable = table
        table.reloadData(); table.deselectAll(nil); panel.orderFront(nil)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { choices.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard choices.indices.contains(row) else { return nil }
        return SemanticCandidateCell(item: choices[row].item)
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SemanticCandidateRow() }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = candidateTable, choices.indices.contains(table.selectedRow) else { return }
        if let view = targetView { updateGhost(in: view, selected: table.selectedRow) }
        let item = choices[table.selectedRow].item
        let documentation = item["documentation"].string ?? item["documentation"]["value"].string
        let metadata = documentation ?? item["detail"].string
        detailLabel?.stringValue = String((metadata ?? "Tab accept preview   ↑ ↓ alternatives   Esc dismiss").prefix(300))
        let height: CGFloat = metadata?.isEmpty == false ? 54 : 24
        footerBoundary?.constant = -height
        if let panel = automaticPanel, height != detailHeight {
            let available = (targetView?.window?.screen?.visibleFrame ?? .zero).intersection(targetView?.window?.frame ?? .zero)
            var frame = panel.frame
            let newHeight = min(frame.height + height - detailHeight, available.height)
            frame.origin.y = min(max(frame.maxY - newHeight, available.minY), available.maxY - newHeight)
            frame.size.height = newHeight
            panel.setFrame(frame, display: true)
        }
        detailHeight = height
    }
    @objc private func clickCandidate() { acceptAutomaticCandidate(candidateTable?.clickedRow ?? -1) }
    private func acceptAutomaticCandidate(_ row: Int, preview: Bool = false) {
        guard choices.indices.contains(row) else { return }
        let item = NSMenuItem(); item.tag = row; insertChoice(item, expectedPreview: preview ? choices[row].ghost : nil)
    }
    private func updateGhost(in view: EditorTextView, selected: Int? = nil) {
        let row = selected ?? choices.indices.first(where: { choices[$0].ghost != nil })
        ghostRow = row
        guard let row, choices.indices.contains(row), let suffix = choices[row].ghost else { view.semanticGhost = nil; ghostRow = nil; return }
        let choice = choices[row]
        view.semanticGhost = SemanticGhostPreview(text: suffix, snapshot: choice.snapshot, caret: choice.selection.location, fileURL: choice.fileURL, language: choice.language)
    }
    private func invalidateAutomatic() {
        cancelHover(); completionInFlight = false
        assistanceTask?.cancel(); assistanceTask = nil
        signatureTask?.cancel(); signatureTask = nil
        signaturePanel?.orderOut(nil); if let signaturePanel { signaturePanel.parent?.removeChildWindow(signaturePanel) }; signatureView = nil
        actionChoices.removeAll(); jumpChoices.removeAll()
        targetView?.semanticGhost = nil; ghostRow = nil
        generation += 1; debounce?.cancel(); debounce = nil
        completionTask?.cancel(); completionTask = nil
        automaticPanel?.orderOut(nil); choices.removeAll()
    }
    /// Called before native key handling; never consumes composition or normal typing.
    func handleAutomaticKey(_ event: NSEvent, in view: EditorTextView) -> Bool {
        if view.hasMarkedText() { invalidateAutomatic(); return false }
        guard targetView === view, automaticPanel?.isVisible == true else {
            if event.keyCode == 53 { invalidateAutomatic() }
            return false
        }
        guard let choice = choices.first, view.string == choice.snapshot, view.selectedRange() == choice.selection,
              preferences.globallyEnabled, enabled.contains(choice.language), language(for: view) == choice.language,
              view.semanticDocumentContext?().url == choice.fileURL, view.window?.firstResponder === view else { invalidateAutomatic(); return false }
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { invalidateAutomatic(); return false }
        switch event.keyCode {
            case 53: invalidateAutomatic(); return true
            case 125, 126:
                guard let table = candidateTable, !choices.isEmpty else { return false }
                let current = table.selectedRow
                let row = event.keyCode == 125 ? min(current + 1, choices.count - 1) : max(current - 1, 0)
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
                return true
            case 48:
                if let row = candidateTable?.selectedRow, row >= 0 { acceptAutomaticCandidate(row); return true }
                if view.semanticGhostIsCurrent, let row = ghostRow { acceptAutomaticCandidate(row, preview: true); return true }
                invalidateAutomatic(); return false
            case 36:
                if let row = candidateTable?.selectedRow, row >= 0 { acceptAutomaticCandidate(row); return true }
                invalidateAutomatic(); return false
            default: invalidateAutomatic(); return false
        }
    }
    func typed(_ event: NSEvent, in view: EditorTextView, previousText: String) {
        defer { if automatic && view.string != previousText && event.modifierFlags.intersection([.command, .control]).isEmpty { scheduleSignature(in: view, delay: 180) } }
        if targetView !== view { invalidateAutomatic(); targetView = view }
        guard preferences.globallyEnabled, automatic, !applyingCompletion, view.string != previousText,
              event.modifierFlags.intersection([.command, .control]).isEmpty,
              !view.hasMarkedText(), let language = language(for: view), enabled.contains(language),
              view.selectedRange().length == 0, view.selectedRanges.count == 1,
              (NSApp.keyWindow ?? NSApp.mainWindow) === view.window else { return }
        let text = view.string, caret = view.selectedRange().location, token = generation
        let client = clients[language]
        let delay = debouncePolicy.delay(now: ProcessInfo.processInfo.systemUptime, warm: client != nil && tasks[language] == nil)
        debounce?.cancel()
        debounce = Task { [weak self, weak view] in
            do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
            guard let self, let view, !Task.isCancelled, self.generation == token,
                  view.string == text, view.selectedRange().location == caret, !view.hasMarkedText() else { return }
            let triggers = await client?.triggerCharacters ?? ["."]
            guard !Task.isCancelled, self.generation == token, view.string == text,
                  view.selectedRange() == NSRange(location: caret, length: 0), !view.hasMarkedText(),
                  view.window?.firstResponder === view,
                  (NSApp.keyWindow ?? NSApp.mainWindow) === view.window,
                  self.language(for: view) == language else { return }
            guard let context = LSPAutomaticContext.trigger(text: text, caret: caret, characters: triggers) else { return }
            self.requestCompletion(automatic: true, trigger: context.character)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let raw = item.representedObject as? String, let language = LSPLanguage(rawValue: raw) {
            item.state = enabled.contains(language) ? .on : .off
            return true
        }
        if item.action == #selector(toggleGlobal) { item.state = preferences.globallyEnabled ? .on : .off; return true }
        if item.action == #selector(toggleAutomatic) { item.state = automatic ? .on : .off; return true }
        if item.action == #selector(complete) { return preferences.globallyEnabled && !enabled.isEmpty }
        return true
    }
    private func showError(_ error: any Error) {
        let alert = NSAlert()
        alert.messageText = "Semantic Completion"
        alert.informativeText = error.localizedDescription
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}

private extension SemanticCompletionController {
    func activeEditor() -> EditorTextView? {
        guard preferences.globallyEnabled, let view = NSApp.keyWindow?.firstResponder as? EditorTextView,
              let language = language(for: view), enabled.contains(language), !view.hasMarkedText(),
              view.selectedRanges.count == 1, view.insertionLocations.count <= 1 else { return nil }
        return view
    }
    func acceptDiagnostics(_ batch: LSPDiagnosticBatch, language: LSPLanguage, client: LSPClient) async {
        guard preferences.globallyEnabled, enabled.contains(language), clients[language] === client else { return }
        let items = await Task.detached { LSPAssistance.diagnostics(batch) }.value
        guard preferences.globallyEnabled, enabled.contains(language), clients[language] === client else { return }
        for view in trackedViews.allObjects where self.language(for: view) == language && view.string == batch.snapshot {
            guard let context = diagnosticContexts[view.semanticBufferID], context.matches(batch: batch, revision: view.semanticRevision) else { continue }
            let key = routingCache[language]
            if (key?.file == view.semanticDocumentContext?().url && key?.buffer == view.semanticBufferID && key?.route.uri == batch.uri) || view.semanticDocumentContext?().url == batch.uri {
                view.semanticDiagnostics = SemanticDiagnostics(snapshot: batch.snapshot, fileURL: view.semanticDocumentContext?().url, items: items)
            }
        }
    }
    func current(_ view: EditorTextView, snapshot: String, selection: NSRange, file: URL?, token: Int, language: LSPLanguage) -> Bool {
        !Task.isCancelled && generation == token && activeEditor() === view && view.string == snapshot && view.selectedRange() == selection && view.semanticDocumentContext?().url == file && self.language(for: view) == language
    }
    @objc func showDiagnostics() {
        guard let view = activeEditor() else { return }
        let items = view.semanticDiagnostics?.snapshot == view.string ? view.semanticDiagnostics?.items ?? [] : []
        let alert = NSAlert(); alert.messageText = "Diagnostics"
        alert.informativeText = items.isEmpty ? "No current versioned diagnostics. Analysis may still be running." : items.prefix(30).map { "\($0.severity == 1 ? "Error" : $0.severity == 2 ? "Warning" : "Info"): \($0.message)" }.joined(separator: "\n")
        if let window = view.window { alert.beginSheetModal(for: window) }
    }
    @objc func showParameterHints() { if let view = activeEditor() { scheduleSignature(in: view, delay: 0) } }
    func scheduleSignature(in view: EditorTextView, delay: Int) {
        signatureTask?.cancel(); signaturePanel?.orderOut(nil)
        guard activeEditor() === view, let language = language(for: view), view.selectedRange().length == 0,
              LSPAssistance.isInCall(view.string, caret: view.selectedRange().location) else { return }
        let snapshot = view.string, selection = view.selectedRange(), file = view.semanticDocumentContext?().url, token = generation, buffer = view.semanticBufferID
        signatureView = view
        signatureTask = Task { [weak self, weak view] in
            guard let self, let view else { return }
            do {
                try await Task.sleep(for: .milliseconds(delay))
                guard self.current(view, snapshot: snapshot, selection: selection, file: file, token: token, language: language) else { return }
                let (client, uri) = try await self.preparedClient(fileURL: file, bufferID: buffer, language: language, allowCachedRoute: true, token: token)
                let value = try await client.signatures(uri: uri, language: language, text: snapshot, offset: selection.location)
                guard self.current(view, snapshot: snapshot, selection: selection, file: file, token: token, language: language), let signature = LSPAssistance.signature(value) else { return }
                self.cancelHover()
                let panel = self.signaturePanel ?? SemanticCandidatePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                let available = (view.window?.screen?.visibleFrame ?? .zero).intersection(view.window?.frame ?? .zero)
                guard available.width >= 200, available.height >= 50 else { return }
                let surface = SemanticSignatureView(signature: signature, width: min(440, available.width)); surface.appearance = view.effectiveAppearance
                let height = min(max(surface.fittingSize.height, 36), min(120, available.height))
                var actual = selection; let caret = view.firstRect(forCharacterRange: selection, actualRange: &actual)
                // Above the caret, while completion alternatives occupy space below it.
                let y = min(max(caret.maxY + 4, available.minY), available.maxY - height)
                panel.contentView = surface; panel.appearance = view.effectiveAppearance
                panel.hasShadow = true; panel.hidesOnDeactivate = true; panel.isReleasedWhenClosed = false
                let frame = NSRect(x: min(max(caret.minX, available.minX), available.maxX - min(440, available.width)), y: y, width: min(440, available.width), height: height)
                guard available.intersects(caret), !frame.intersects(caret) else { return }
                panel.setFrame(frame, display: true)
                if panel.parent !== view.window { panel.parent?.removeChildWindow(panel); view.window?.addChildWindow(panel, ordered: .above) }
                self.signaturePanel = panel; panel.orderFront(nil)
            } catch { if !Task.isCancelled, self.generation == token { self.lastProblem[language] = error.localizedDescription } }
        }
    }
    @objc func goToDefinition() {
        invalidateAutomatic()
        guard let view = activeEditor(), let language = language(for: view) else { return }
        let snapshot = view.string, selection = view.selectedRange(), file = view.semanticDocumentContext?().url, token = generation, buffer = view.semanticBufferID
        assistanceTask = Task { [weak self, weak view] in
            guard let self, let view else { return }
            do {
                let (client, uri) = try await self.preparedClient(fileURL: file, bufferID: buffer, language: language, allowCachedRoute: true, token: token)
                let result = try await client.definition(uri: uri, language: language, text: snapshot, offset: selection.location)
                guard self.current(view, snapshot: snapshot, selection: selection, file: file, token: token, language: language), let root = self.clientWorkspaces[language] else { return }
                let locations = LSPAssistance.locations(result)
                self.jumpChoices = locations.map { JumpChoice(source: WeakEditor(view: view), snapshot: snapshot, selection: selection, file: file, generation: token, location: $0, root: root) }
                guard !self.jumpChoices.isEmpty else { self.showError(LSPError.server("No supported local source definition. Server library/decompiled URI targets are not opened.")); return }
                if locations.count == 1 { self.navigate(self.jumpChoices[0]); return }
                let menu = NSMenu()
                for (index, location) in locations.enumerated() { let item = NSMenuItem(title: "\(location.uri.lastPathComponent):\((location.range["start"]["line"].int ?? 0) + 1)", action: #selector(self.chooseDefinition(_:)), keyEquivalent: ""); item.target = self; item.tag = index; menu.addItem(item) }
                menu.popUp(positioning: nil, at: view.convert(view.window!.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil), in: view)
            } catch { if !Task.isCancelled, self.generation == token { self.showError(error) } }
        }
    }
    @objc func chooseDefinition(_ sender: NSMenuItem) { if jumpChoices.indices.contains(sender.tag) { navigate(jumpChoices[sender.tag]) } }
    private func navigate(_ choice: JumpChoice) {
        guard let source = choice.source.view, let language = language(for: source), current(source, snapshot: choice.snapshot, selection: choice.selection, file: choice.file, token: choice.generation, language: language) else { return }
        let url = choice.location.uri.standardizedFileURL
        if choice.location.uri == routingCache[language]?.route.uri {
            guard let range = try? LSPText.range(choice.location.range, in: source.string) else { return }
            navigationBack.append((WeakEditor(view: source), choice.selection, choice.file, choice.snapshot)); source.setSelectedRange(range); source.scrollRangeToVisible(range); return
        }
        assistanceTask = Task { [weak self, weak source] in
            guard let self, let source else { return }
            do {
                let safeURL = await Task.detached { LSPAssistance.safeDefinitionFile(url, workspace: choice.root) }.value
                guard self.current(source, snapshot: choice.snapshot, selection: choice.selection, file: choice.file, token: choice.generation, language: language) else { return }
                guard let url = safeURL else { throw LSPError.server("Definition target is outside the current safe workspace, hidden, symlinked or too large. It was not opened.") }
                // Reuse an open document and its unsaved buffer; never reload its disk contents.
                let document: Document
                if let existing = NSDocumentController.shared.document(for: url) as? Document { document = existing }
                else { guard let opened = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: false).0 as? Document else { throw LSPError.unsupportedEdit }; document = opened }
                guard self.current(source, snapshot: choice.snapshot, selection: choice.selection, file: choice.file, token: choice.generation, language: language) else { return }
                if document.windowControllers.isEmpty { document.makeWindowControllers() }
                guard let target = document.textView as? EditorTextView, let range = try? LSPText.range(choice.location.range, in: target.string) else { throw LSPError.unsupportedEdit }
                // An already edited target may differ from what the server analyzed. Refuse stale ranges.
                guard !document.isDocumentEdited || target === source else { throw LSPError.server("Definition target has unsaved changes; navigation was refused to avoid a stale range.") }
                self.navigationBack.append((WeakEditor(view: source), choice.selection, choice.file, choice.snapshot)); self.navigationBack = Array(self.navigationBack.suffix(30))
                document.showWindows(); target.window?.makeFirstResponder(target); target.setSelectedRange(range); target.scrollRangeToVisible(range)
            } catch { if !Task.isCancelled { self.showError(error) } }
        }
    }
    @objc func goBack() {
        invalidateAutomatic()
        while let previous = navigationBack.popLast() {
            guard let view = previous.view.view, view.semanticDocumentContext?().url == previous.file, view.string == previous.snapshot, NSMaxRange(previous.range) <= (view.string as NSString).length, let window = view.window else { continue }
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view); view.setSelectedRange(previous.range); view.scrollRangeToVisible(previous.range); break
        }
    }
    @objc func quickFix() {
        invalidateAutomatic()
        guard let view = activeEditor(), view.isEditable, let language = language(for: view) else { return }
        let snapshot = view.string, selection = view.selectedRange(), file = view.semanticDocumentContext?().url, token = generation, buffer = view.semanticBufferID
        assistanceTask = Task { [weak self, weak view] in
            guard let self, let view else { return }
            do {
                let (client, uri) = try await self.preparedClient(fileURL: file, bufferID: buffer, language: language, allowCachedRoute: true, token: token)
                var offered: [(String, [LSPText.Edit])] = []
                let actions = try await client.codeActions(uri: uri, language: language, text: snapshot, range: selection)
                for action in actions.prefix(30) {
                    try Task.checkCancellation()
                    let resolved = try await client.resolveAction(action)
                    if let edits = try? LSPAssistance.actionEdits(resolved, uri: uri, version: await client.version(of: uri), text: snapshot), let title = resolved["title"].string { offered.append((String(title.prefix(200)), edits)) }
                }
                // Pyright OSS primarily supplies imports as completion additionalTextEdits.
                // Use only actual resolved server edits for the existing identifier, never generate imports.
                if selection.length == 0, selection.location > 0, let symbol = LSPHoverPresentation.symbol(in: snapshot, at: selection.location - 1), NSMaxRange(symbol) == selection.location {
                    let name = (snapshot as NSString).substring(with: symbol)
                    let completions = try await client.complete(uri: uri, language: language, text: snapshot, caret: selection.location)
                    for item in completions.filter({ ($0["filterText"].string ?? $0["label"].string) == name }).prefix(10) {
                        let resolved = try await client.resolve(item)
                        if let edits = try? LSPAssistance.importEdits(resolved, uri: uri, version: await client.version(of: uri), text: snapshot, symbol: symbol, caret: selection.location) {
                            offered.append(("Import \(name) — \(String((resolved["labelDetails"]["description"].string ?? resolved["detail"].string ?? "server suggestion").prefix(100)))", edits))
                        }
                    }
                }
                guard self.current(view, snapshot: snapshot, selection: selection, file: file, token: token, language: language) else { return }
                self.actionChoices = offered.prefix(40).map { ActionChoice(view: WeakEditor(view: view), snapshot: snapshot, file: file, selection: selection, language: language, generation: token, title: $0.0, edits: $0.1) }
                guard !self.actionChoices.isEmpty else { self.showError(LSPError.server("No safe current-document fix/import is available here. Command-only, resource operations and multi-document actions are unsupported.")); return }
                let menu = NSMenu()
                for (index, choice) in self.actionChoices.enumerated() { let item = NSMenuItem(title: choice.title, action: #selector(self.chooseAction(_:)), keyEquivalent: ""); item.target = self; item.tag = index; menu.addItem(item) }
                var actual = selection; let anchor = view.firstRect(forCharacterRange: selection, actualRange: &actual)
                menu.popUp(positioning: nil, at: view.convert(view.window!.convertPoint(fromScreen: NSPoint(x: anchor.minX, y: anchor.minY)), from: nil), in: view)
            } catch { if !Task.isCancelled, self.generation == token { self.showError(error) } }
        }
    }
    @objc func chooseAction(_ sender: NSMenuItem) {
        guard actionChoices.indices.contains(sender.tag) else { return }
        let choice = actionChoices[sender.tag]
        guard let view = choice.view.view, view.isEditable, current(view, snapshot: choice.snapshot, selection: choice.selection, file: choice.file, token: choice.generation, language: choice.language) else { return }
        applyingCompletion = true; defer { applyingCompletion = false; invalidateAutomatic(); track(view) }
        _ = SemanticActionApplication.apply(choice.edits, title: choice.title, to: view)
    }
}

extension SemanticCompletionController {
    /// Called on focus/edit, including Undo/paste; diagnostics do not depend on typing auto-completion.
    func track(_ view: EditorTextView) {
        trackedViews.add(view); view.semanticDiagnostics = nil
        diagnosticContexts.removeValue(forKey: view.semanticBufferID)
        diagnosticTasks.removeValue(forKey: view.semanticBufferID)?.cancel()
        guard preferences.globallyEnabled, let language = language(for: view), enabled.contains(language), view.window != nil, !view.hasMarkedText() else { return }
        let snapshot = view.string, file = view.semanticDocumentContext?().url, buffer = view.semanticBufferID, token = generation, revision = view.semanticRevision
        diagnosticTasks[buffer] = Task { [weak self, weak view] in
            guard let self, let view else { return }
            do {
                try await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, self.preferences.globallyEnabled, self.enabled.contains(language), view.string == snapshot, view.semanticDocumentContext?().url == file, view.window != nil, NSApp.keyWindow === view.window, view.window?.firstResponder === view, self.language(for: view) == language else { return }
                // Focus/selection generations can change while diagnostics debounce. Use the current
                // generation at preparation, then check snapshot/identity again before synchronization.
                let (client, uri) = try await self.preparedClient(fileURL: file, bufferID: buffer, language: language, allowCachedRoute: true, token: self.generation)
                guard !Task.isCancelled, view.string == snapshot, view.semanticDocumentContext?().url == file, self.preferences.globallyEnabled, self.enabled.contains(language) else { return }
                try await client.synchronizeDocument(uri: uri, language: language, text: snapshot)
                guard !Task.isCancelled, view.semanticRevision == revision, view.string == snapshot,
                      view.semanticDocumentContext?().url == file, let version = await client.version(of: uri) else { return }
                self.diagnosticContexts[buffer] = LSPDiagnosticStamp(uri: uri, revision: revision, version: version)
                if let batch = await client.diagnostics(for: uri), batch.snapshot == snapshot { await self.acceptDiagnostics(batch, language: language, client: client) }
            } catch { if !Task.isCancelled, self.generation == token { self.lastProblem[language] = error.localizedDescription } }
        }
    }
}
