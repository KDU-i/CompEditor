// SPDX-License-Identifier: Apache-2.0
import AppKit
import LineEnding
import Testing
@testable import CotEditor

@MainActor @Suite(.serialized) struct CopilotNESAcceptanceTests {
    @Test func semanticBuffersUseStorageIdentityAcrossEdits() throws {
        let document = Document(), otherDocument = Document()
        let first = EditorTextView(textStorage: document.textStorage, lineEndingScanner: document.lineEndingScanner)
        let second = EditorTextView(textStorage: otherDocument.textStorage, lineEndingScanner: otherDocument.lineEndingScanner)
        first.string = "same content"; second.string = "same content"
        let storage = try #require(first.textStorage)
        let id = first.semanticBufferID
        #expect(second.semanticBufferID != id, "Equal text in distinct buffers must not share identity.")
        first.semanticRevision = 10
        let sibling = EditorTextView(textStorage: storage, lineEndingScanner: document.lineEndingScanner)
        #expect(sibling.semanticBufferID == id && sibling.semanticRevision == 10)
        for (index, text) in [String(repeating: "changed", count: 100), "same content", "different"].enumerated() {
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
            #expect(first.textStorage === storage && sibling.textStorage === storage)
            #expect(first.semanticBufferID == id && sibling.semanticBufferID == id)
            #expect(first.semanticRevision == 10 + index)
            first.semanticRevision += 1
            #expect(sibling.semanticRevision == 11 + index)
        }
        #expect(second.semanticBufferID != id && second.semanticRevision == 0)
        print("NES_BUFFER_IDENTITY_PASS equalTextDistinctBuffers=true editStableIdentity=true revisionContinuity=true sharedStorage=true")
    }

    @Test func unsupportedServerStopsAutomaticRPCAndAllowsTurningNESOff() async throws {
        try await CopilotProcessTestLease.acquire()
        defer { CopilotProcessTestLease.release() }
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = directory.appendingPathComponent("synthetic-session.json")
        let executable = directory.appendingPathComponent("copilot-language-server")
        let mock = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SemanticTests/copilot_mock.py")
        func literal(_ value: String) throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
            return String(data: try encoder.encode(value), encoding: .utf8)!
        }
        let script = "#!/usr/bin/python3\nimport sys\nsys.argv=[\(try literal(mock.path)), '--preauthenticated', '--no-nes', '--session-state', \(try literal(state.path))]\nexec(compile(open(sys.argv[0]).read(), sys.argv[0], 'exec'))\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let suite = "CopilotNESUnsupported-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "CompEditor.Copilot.rememberContextConsent.v1")
        defaults.set(false, forKey: "CompEditor.Copilot.automaticSuggestions.v1")
        defaults.set(true, forKey: "CompEditor.Copilot.automaticNextEdits.v1")
        let copilot = CopilotCompletionController(defaults: defaults, executable: executable)
        let document = Document()
        document.makeWindowControllers()
        let window = try #require(document.windowControllers.first?.window)
        let view = try #require(document.textViews.first as? EditorTextView)
        view.copilotController = copilot
        view.string = "NO_NES"
        view.semanticDocumentContext = { (nil, "Python") }
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 600, height: 300))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        _ = NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate()
        copilot.installMenu()
        let installedMenu = NSApp.mainMenu?.items.last
        defer {
            _ = copilot.perform(NSSelectorFromString("toggle"))
            if let installedMenu { NSApp.mainMenu?.removeItem(installedMenu) }
            window.orderOut(nil)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        func waitUntil(_ checkpoint: String, limit: Int = 150, _ condition: () -> Bool) async throws {
            for _ in 0..<limit {
                if condition() { return }
                if checkpoint == "authentication", copilot.connectionPresentation.phase == .failed { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("Synthetic checkpoint failed: \(checkpoint); phase=\(copilot.connectionPresentation.phase); detail=\(copilot.connectionPresentation.detail); initialize=\(rpcCount("initialize")); checkStatus=\(rpcCount("checkStatus")); RPC count=\(rpcCount()); active=\(NSApp.isActive); key=\(NSApp.keyWindow === window); responder=\(window.firstResponder === view); visible=\(window.isVisible); canKey=\(window.canBecomeKey); python=\(view.semanticDocumentContext?().syntax == "Python")")
            throw CancellationError()
        }
        func rpcCount(_ method: String = "textDocument/copilotInlineEdit") -> Int {
            guard let data = try? Data(contentsOf: state),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let methods = json["methods"] as? [String: Int] else { return 0 }
            return methods[method] ?? 0
        }
        // Cold interpreter/process startup is allowed within the product's
        // 15-second per-RPC handshake budget; this is not a 3s startup SLA.
        try await waitUntil("authentication", limit: 1500) { copilot.connectionPresentation.phase == .authenticated }
        _ = NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        try await waitUntil("focused editor", limit: 750) {
            // The test host can finish opening its initial empty window after auth.
            _ = NSApp.setActivationPolicy(.regular)
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.makeKey()
            window.makeMain()
            window.makeFirstResponder(view)
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            return NSApp.isActive && NSApp.keyWindow === window && window.firstResponder === view
        }
        view.string = "NO_NES"
        view.semanticDocumentContext = { (nil, "Python") }
        view.selectedRange = NSRange(location: 1, length: 0)
        copilot.typed(in: view, previous: "before")
        try await waitUntil("unsupported") { copilot.connectionPresentation.detail.contains("公開Next Edit API") }
        #expect(rpcCount() == 1)
        for index in 0..<3 {
            let previous = view.string
            view.string += "x"
            copilot.typed(in: view, previous: previous)
            NotificationCenter.default.post(name: NSText.didChangeNotification, object: view)
            view.selectedRange = NSRange(location: index + 1, length: 0)
            NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: view)
        }
        _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
        try await Task.sleep(for: .milliseconds(650))
        #expect(rpcCount() == 1)
        // A deliberate move after the typing grace period must also stay silent.
        view.selectedRange = NSRange(location: 0, length: 0)
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: view)
        try await Task.sleep(for: .milliseconds(450))
        #expect(rpcCount() == 1)
        let manual = NSMenuItem(title: "NES request", action: NSSelectorFromString("triggerNextEdit"), keyEquivalent: "")
        #expect(!copilot.validateMenuItem(manual))
        let option = NSMenuItem(title: "NES", action: NSSelectorFromString("toggleNextEdits"), keyEquivalent: "")
        #expect(copilot.validateMenuItem(option))
        #expect(option.state == .on)
        _ = copilot.perform(option.action!)
        #expect(!defaults.bool(forKey: "CompEditor.Copilot.automaticNextEdits.v1"))
        #expect(!copilot.validateMenuItem(option))
        #expect(option.state == .off)
        _ = copilot.perform(NSSelectorFromString("reconnectAuthentication"))
        try await waitUntil("reconnection") { !copilot.connectionPresentation.reconnecting }
        #expect(copilot.validateMenuItem(option))
        for panel in NSApp.windows.compactMap({ $0 as? NSPanel }) where panel.title == "GitHub Copilot" { panel.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        _ = copilot.perform(option.action!)
        copilot.typed(in: view, previous: "before recovery")
        try await waitUntil("second probe") { rpcCount() == 2 }
        try await Task.sleep(for: .milliseconds(350))
        copilot.typed(in: view, previous: "after recovery")
        try await Task.sleep(for: .milliseconds(350))
        #expect(rpcCount() == 2)
    }

    @Test func syntheticPayloadsUseRealControllerKeysAndViewport() async throws {
        try await CopilotProcessTestLease.acquire()
        defer { CopilotProcessTestLease.release() }
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = directory.appendingPathComponent("fixture.json")
        let sessionState = directory.appendingPathComponent("rpc-counts.json")
        let executable = directory.appendingPathComponent("copilot-language-server")
        let mock = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SemanticTests/copilot_mock.py")
        func literal(_ value: String) throws -> String { let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes; return String(data: try encoder.encode(value), encoding: .utf8)! }
        let script = "#!/usr/bin/python3\nimport sys\nsys.argv=[\(try literal(mock.path)), '--preauthenticated', '--nes-fixture', \(try literal(fixture.path)), '--session-state', \(try literal(sessionState.path))]\nexec(compile(open(sys.argv[0]).read(), sys.argv[0], 'exec'))\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let suite = "NES031-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "CompEditor.Copilot.rememberContextConsent.v1")
        defaults.set(false, forKey: "CompEditor.Copilot.automaticSuggestions.v1")
        defaults.set(false, forKey: "CompEditor.Copilot.automaticNextEdits.v1")
        let copilot = CopilotCompletionController(defaults: defaults, executable: executable)
        let document = Document()
        document.makeWindowControllers()
        let window = try #require(document.windowControllers.first?.window)
        let view = try #require(document.textViews.first as? EditorTextView)
        view.copilotController = copilot
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 800, height: 400))
        if let scroll = view.enclosingScrollView {
            scroll.hasVerticalRuler = true
            scroll.hasHorizontalRuler = false
            scroll.horizontalRulerView?.isHidden = true
            scroll.verticalRulerView = LineNumberView(textView: view, scrollView: scroll, orientation: .verticalRuler)
            scroll.verticalRulerView?.isHidden = false
            scroll.rulersVisible = true
            scroll.tile()
        }
        func focusWindow(_ window: NSWindow, editor view: EditorTextView) {
            if !NSApp.isActive {
                _ = NSApp.setActivationPolicy(.regular)
                NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                NSApp.activate()
            }
            if !window.isVisible || NSApp.keyWindow !== window { window.makeKeyAndOrderFront(nil) }
            if NSApp.mainWindow !== window { window.makeMain() }
            if window.firstResponder !== view { window.makeFirstResponder(view) }
        }
        func focus() {
            focusWindow(window, editor: view)
            for _ in 0..<50 { guard let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) else { break }; NSApp.sendEvent(event) }
        }
        func settleEditorWindow(_ targetWindow: NSWindow, editor targetView: EditorTextView, awaiting timestamp: TimeInterval? = nil) throws {
            focusWindow(targetWindow, editor: targetView)
            targetView.layoutSubtreeIfNeeded(); targetWindow.displayIfNeeded(); NSApp.updateWindows()
            let deadline = Date().addingTimeInterval(2)
            var lastGeometry = ProcessInfo.processInfo.systemUptime
            var frame = targetWindow.frame
            var viewport = targetView.visibleRect
            var sawStagedMove = timestamp == nil
            var geometryEvents = 0
            while Date() < deadline {
                // Unlike until:Date(), a future deadline lets WindowServer's
                // in-flight messages arrive through the real event loop.
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                    if event.type == .appKitDefined {
                        geometryEvents += 1
                        lastGeometry = ProcessInfo.processInfo.systemUptime
                        if event.subtype == .windowMoved, timestamp.map({ abs(event.timestamp - $0) < 0.000001 }) == true { sawStagedMove = true }
                    }
                    NSApp.sendEvent(event)
                }
                if frame != targetWindow.frame || viewport != targetView.visibleRect {
                    frame = targetWindow.frame; viewport = targetView.visibleRect
                    lastGeometry = ProcessInfo.processInfo.systemUptime
                }
                if !NSApp.isActive || NSApp.keyWindow !== targetWindow || targetWindow.firstResponder !== targetView {
                    focusWindow(targetWindow, editor: targetView)
                    lastGeometry = ProcessInfo.processInfo.systemUptime
                }
                if sawStagedMove, targetView.window === targetWindow, ProcessInfo.processInfo.systemUptime - lastGeometry >= 0.2 {
                    print("NES_IDLE awaitedMove=\(timestamp != nil) moveRequirementMet=\(sawStagedMove) geometryQuiet=0.2 events=\(geometryEvents) window=\(targetWindow.windowNumber) active=\(NSApp.isActive) key=\(NSApp.keyWindow === targetWindow) viewport=\(targetView.visibleRect.origin)")
                    return
                }
            }
            Issue.record("Native window preparation did not settle before command")
            throw CancellationError()
        }
        func waitFor(_ label: String, _ condition: () -> Bool) async throws {
            for _ in 0..<1000 { focus(); if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
            Issue.record("NES031 checkpoint: \(label); active=\(NSApp.isActive); key=\(NSApp.keyWindow === window); running=\(NSApp.isRunning); pid=\(ProcessInfo.processInfo.processIdentifier); front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"); responder=\(window.firstResponder === view); attached=\(view.window === window); selected=\(view.selectedRange()); revision=\(view.semanticRevision); ghostCaret=\(view.semanticGhost?.caret ?? -1); ghostRevision=\(view.semanticGhost?.revision ?? -1); ghostExists=\(view.semanticGhost != nil); ghostCopilot=\(view.semanticGhost?.copilot == true); ghostCurrent=\(view.semanticGhostIsCurrent); snapshotSame=\(view.semanticGhost.map { LSPText.sameText($0.snapshot, view.string) } ?? false); context=\(view.semanticDocumentContext?().syntax ?? "nil"); phase=\(copilot.connectionPresentation.phase); status=\(copilot.connectionPresentation.detail)"); throw CancellationError()
        }
        func capture(_ target: NSView, name: String) throws {
            let output = URL.temporaryDirectory.appendingPathComponent("compeditor-nes031-evidence")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            target.layoutSubtreeIfNeeded()
            target.displayIfNeeded()
            if let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) {
                target.cacheDisplay(in: target.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: output.appendingPathComponent(name + ".png")) }
            }
        }
        func captureEditorWithPanel(name: String) throws {
            let target = view.enclosingScrollView ?? view
            target.layoutSubtreeIfNeeded(); target.displayIfNeeded()
            guard let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
            target.cacheDisplay(in: target.bounds, to: bitmap)
            let source = NSImage(size: target.bounds.size); source.addRepresentation(bitmap)
            var overlay: NSImage?, overlayRect = NSRect.zero
            if let panel = view.semanticGhostPanel, let content = panel.contentView,
               let preview = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: preview)
                let image = NSImage(size: content.bounds.size); image.addRepresentation(preview); overlay = image
                overlayRect = target.convert(window.convertFromScreen(panel.frame), from: nil)
            }
            // AppKit cacheDisplay excludes child windows. Composite their actual
            // rendered pixels at the real screen-to-view frame, without restyling.
            let image = NSImage(size: target.bounds.size, flipped: target.isFlipped) { rect in
                source.draw(in: rect)
                overlay?.draw(in: overlayRect)
                return true
            }
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                let output = URL.temporaryDirectory.appendingPathComponent("compeditor-nes031-evidence")
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try png.write(to: output.appendingPathComponent(name + ".png"))
            }
        }
        func key(_ code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: code == 48 ? "\t" : "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        #if DEBUG
        view.nativeCompletionTrace = { print("NES_SETUP " + $0) }
        defer { view.nativeCompletionTrace = nil }
        #endif
        focus(); copilot.installMenu()
        let menu = NSApp.mainMenu?.items.last
        defer {
            _ = copilot.perform(NSSelectorFromString("toggle"))
            if let menu { NSApp.mainMenu?.removeItem(menu) }
            window.orderOut(nil); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try await waitFor("authenticated") { copilot.connectionPresentation.phase == .authenticated }
        try settleEditorWindow(window, editor: view)
        for language in ["Python", "Java"] {
            for newline in ["\n", "\r\n"] {
                for (replacement, insertion) in [("Goodbye😀", false), ("", false), ("one\n\ttwo", false), (" + added😀", true)] {
                    let source = (["# 😀", "first()", "second()", "third()", "value = Hello"] + (0..<30).map { "tail\($0)()" }).joined(separator: newline)
                    view.lineEnding = newline == "\r\n" ? .crlf : .lf
                    view.string = source; view.semanticDocumentContext = { (nil, language) }
                    view.selectedRange = NSRange(location: 2, length: 0)
                    try settleEditorWindow(window, editor: view)
                    try #require(LSPText.sameText(view.string, source) && view.selectedRange() == NSRange(location: 2, length: 0))
                    try #require(view.semanticDocumentContext?().syntax == language && view.window === window)
                    let wordRange = (source as NSString).range(of: "Hello")
                    let range = NSRange(location: wordRange.location, length: insertion ? 0 : wordRange.length)
                    let item: LSPJSON = .object(["text": .string(replacement), "range": try CopilotInline.rangeJSON(range, in: source)])
                    let payload: LSPJSON = .object(["source": .string(source), "edit": item])
                    try JSONEncoder().encode(payload).write(to: fixture)
                    _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
                    try await waitFor("display \(language) \(replacement)") { view.semanticGhost?.nextEdit == true && copilot.hasVisibleSuggestion(in: view) }
                    #expect(view.string == source)
                    let imageName = "\(language)-\(newline.utf16.count)-\(insertion)-\(replacement.utf16.count)"
                    try capture(view.enclosingScrollView ?? view, name: imageName + "-editor")
                    if let preview = view.semanticGhostPanel?.contentView { try capture(preview, name: imageName + "-preview-wide") }
                    let undoBefore = view.undoManager?.canUndo
                    window.setContentSize(NSSize(width: 360, height: 300))
                    NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
                    view.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 500))
                    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: view.enclosingScrollView!.contentView)
                    #expect(copilot.hasSuggestions(in: view))
                    if let preview = view.semanticGhostPanel?.contentView { try capture(preview, name: imageName + "-preview-narrow") }
                    #expect(view.undoManager?.canUndo == undoBefore)
                    window.sendEvent(try key(48))
                    #expect(view.string == source)
                    #expect(view.selectedRange().location == range.location)
                    #expect(copilot.handleKey(try key(48), in: view))
                    let normalized = CopilotInline.normalize(replacement, in: source)
                    let minimal = CopilotNextEditPolicy.minimized(.init(range: range, text: normalized, primary: true), in: source)
                    #expect(view.string == (source as NSString).replacingCharacters(in: range, with: normalized))
                    #expect(view.selectedRange() == NSRange(location: minimal.range.location + minimal.text.utf16.count, length: 0))
                    view.undoManager?.undo()
                    #expect(view.string == source)
                    try await Task.sleep(for: .milliseconds(100))
                    #expect(view.semanticGhost == nil)
                    view.undoManager?.redo()
                    #expect(view.string == (source as NSString).replacingCharacters(in: range, with: normalized))
                    window.setContentSize(NSSize(width: 800, height: 400))
                }
            }
        }
        // Visual acceptance against the supplied VS Code examples. Both widths
        // use the same real editor font/line height and synthetic source.
        view.breakUndoCoalescing(); view.undoManager?.removeAllActions()
        view.wrapsLines = true
        let visualSource = "def say_hello(name: str, greeting: str):\n    return f'{greeting or \"Hello\"}, {name}!'\n\n\ndef function():\n    pass"
        let visualRange = (visualSource as NSString).range(of: "Hello")
        for dark in [true, false] {
            view.backgroundColor = dark ? NSColor(calibratedWhite: 0.118, alpha: 1) : .white
            view.textColor = dark ? NSColor(calibratedWhite: 0.83, alpha: 1) : NSColor(calibratedWhite: 0.18, alpha: 1)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width in [CGFloat(800), 360] {
                window.setContentSize(NSSize(width: width, height: 300))
                for (label, replacement, insertion) in [("word", "Goodbye", false), ("insert", "kind ", true), ("overflow", String(repeating: "long_identifier + ", count: 16) + "END", true), ("multiline", "Hello\n    another_line()", false)] {
                    view.string = visualSource; view.semanticDocumentContext = { (nil, "Python") }
                    view.selectedRange = NSRange(location: visualRange.location - 1, length: 0)
                    let editRange = NSRange(location: visualRange.location, length: insertion ? 0 : visualRange.length)
                    let item: LSPJSON = .object(["text": .string(replacement), "range": try CopilotInline.rangeJSON(editRange, in: visualSource)])
                    try JSONEncoder().encode(LSPJSON.object(["source": .string(visualSource), "edit": item])).write(to: fixture)
                    _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
                    try await waitFor("visual " + label) { copilot.hasVisibleSuggestion(in: view) }
                    view.scrollRangeToVisible(editRange)
                    view.updateSemanticGhostPresentation()
                    #expect(view.string == visualSource)
                    if let panel = view.semanticGhostPanel {
                        let number = panel.windowNumber
                        for _ in 0..<3 { view.updateSemanticGhostPresentation() }
                        #expect(view.semanticGhostPanel === panel && panel.windowNumber == number)
                        #expect(panel.parent === window && NSApp.keyWindow === window)
                    }
                    if label == "overflow" {
                        let panel = try #require(view.semanticGhostPanel)
                        #expect(panel.frame.width <= view.visibleRect.width)
                        func textViews(_ target: NSView) -> [NSTextView] { (target as? NSTextView).map { [$0] } ?? target.subviews.flatMap(textViews) }
                        let displayed = panel.contentView.map(textViews) ?? []
                        #expect(displayed.contains { $0.string == replacement })
                        #expect(displayed.allSatisfy { text in guard let layout = text.layoutManager, let container = text.textContainer else { return false }; return layout.glyphRange(for: container).length == layout.numberOfGlyphs })
                    }
                    try captureEditorWithPanel(name: "vscode-density-\(dark ? "dark" : "light")-\(Int(width))-\(label)")
                }
            }
        }
        window.appearance = nil; view.backgroundColor = .textBackgroundColor; view.textColor = .textColor
        window.setContentSize(NSSize(width: 800, height: 400))
        // Exercise native ordinary-completion visibility with NES, retaining the
        // original normal-inline exclusion policy.
        let popupSource = "HelloWorld\nHelloUniverse\nfirst()\nvalue = Hello\n" + (0..<80).map { "tail\($0)()" }.joined(separator: "\n")
        let popupWord = (popupSource as NSString).range(of: "Hello", options: .backwards)
        view.lineEnding = .lf
        view.isAutomaticCompletionEnabled = false
        view.completionWordTypes = .document
        // Replacing string directly bypasses didChangeText/revision and AppKit's
        // text-input lifecycle. Native completion must observe real input, just
        // like the user opening the menu after editing a document.
        let beforePopupRevision = view.semanticRevision
        view.insertText(popupSource, replacementRange: NSRange(location: 0, length: view.string.utf16.count))
        #expect(view.semanticRevision > beforePopupRevision)
        view.semanticDocumentContext = { (nil, "Python") }
        view.selectedRange = NSRange(location: NSMaxRange(popupWord), length: 0)
        view.scrollRangeToVisible(view.selectedRange())
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try #require(view.rangeForUserCompletion == popupWord)
        #if DEBUG
        var completionInvocationEvents: [UInt16] = []
        var completionCommandEvents: [String] = []
        var finalCompletionEvents: [String] = []
        var priorWindowMoveTimestamp: TimeInterval?
        view.nativeCompletionTrace = { event in
            MainActor.assumeIsolated {
                if event.hasPrefix("complete called") {
                    let current = NSApp.currentEvent
                    completionInvocationEvents.append(current?.type == .keyDown ? current!.keyCode : UInt16.max)
                }
                if event.hasPrefix("insertCompletion final=true") { finalCompletionEvents.append(event) }
                print("NES_NATIVE " + event)
            }
        }
        defer { view.nativeCompletionTrace = nil }
        #endif
        #if DEBUG
        var observingNativeCommand = false
        let eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .any) { event in
            if observingNativeCommand {
                // Match event identity within clock precision after queue transport.
                if event.type == .appKitDefined, event.subtype == .windowMoved, priorWindowMoveTimestamp.map({ abs(event.timestamp - $0) < 0.000001 }) == true {
                    completionCommandEvents.append("priorWindowMove")
                } else if event.type == .keyDown, event.keyCode == 96 {
                    completionCommandEvents.append("F5")
                }
                let key = [.keyDown, .keyUp, .flagsChanged].contains(event.type) ? Int(event.keyCode) : -1
                let subtype = [.appKitDefined, .applicationDefined, .systemDefined].contains(event.type) ? Int(event.subtype.rawValue) : -1
                print("NES_EVENT type=\(event.type.rawValue) subtype=\(subtype) key=\(key) window=\(event.windowNumber) time=\(event.timestamp)")
            }
            return event
        }
        defer { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }
        let notificationObservers = [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSApplication.didResignActiveNotification, NSView.boundsDidChangeNotification, NSTextView.didChangeSelectionNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let rawName = note.name.rawValue
                let own = (note.object as? NSWindow) === window
                MainActor.assumeIsolated {
                    if observingNativeCommand {
                        print("NES_NOTE \(rawName) ownWindow=\(own) active=\(NSApp.isActive) key=\(NSApp.keyWindow === window) responder=\(window.firstResponder === view) native=\(view.isNativeCompletionVisible) selected=\(view.selectedRange()) viewport=\(view.visibleRect.origin)")
                    }
                }
            }
        }
        defer { notificationObservers.forEach(NotificationCenter.default.removeObserver) }
        #endif
        func prepareNativeCommandWindow(_ targetWindow: NSWindow, editor targetView: EditorTextView) throws {
            focusWindow(targetWindow, editor: targetView)
            targetView.layoutSubtreeIfNeeded(); targetWindow.displayIfNeeded(); NSApp.updateWindows()
            #if DEBUG
            observingNativeCommand = true
            #endif
            let timestamp = ProcessInfo.processInfo.systemUptime - 0.1
            let moved = try #require(NSEvent.otherEvent(with: .appKitDefined, location: .zero, modifierFlags: [], timestamp: timestamp, windowNumber: targetView.semanticGhostPanel?.windowNumber ?? targetWindow.windowNumber, context: nil, subtype: NSEvent.EventSubtype.windowMoved.rawValue, data1: 0, data2: 0))
            #if DEBUG
            priorWindowMoveTimestamp = moved.timestamp
            #endif
            // WindowServer can deliver an older geometry event after a synthetic
            // key was already enqueued. Reproduce that delayed delivery too.
            let movedWindowNumber = moved.windowNumber
            let movedTimestamp = moved.timestamp
            let delivery = Timer(timeInterval: 0.02, repeats: false) { _ in
                MainActor.assumeIsolated {
                    let delayed = NSEvent.otherEvent(with: .appKitDefined, location: .zero, modifierFlags: [], timestamp: movedTimestamp, windowNumber: movedWindowNumber, context: nil, subtype: NSEvent.EventSubtype.windowMoved.rawValue, data1: 0, data2: 0)!
                    NSApp.postEvent(delayed, atStart: false)
                }
            }
            RunLoop.main.add(delivery, forMode: .common)
            defer { delivery.invalidate() }
            try settleEditorWindow(targetWindow, editor: targetView, awaiting: moved.timestamp)
        }

        func requestWordCompletion() throws {
            // F5 is AppKit's standard complete: binding. Deliver it through the
            // application event queue, as a user command, instead of calling a
            // modal native action from an unrelated Swift task/current event.
            #if DEBUG
            observingNativeCommand = true
            #endif
            let character = String(UnicodeScalar(NSF5FunctionKey)!)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 96))
            NSApp.postEvent(event, atStart: false)
        }
        let popupItem: LSPJSON = .object(["text": .string("Goodbye"), "range": try CopilotInline.rangeJSON(popupWord, in: popupSource)])
        try JSONEncoder().encode(LSPJSON.object(["source": .string(popupSource), "edit": popupItem])).write(to: fixture)
        _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
        try await waitFor("popup NES") { view.semanticGhost?.nextEdit == true && copilot.hasVisibleSuggestion(in: view) }
        #expect(!view.hasExclusiveCopilotInlineGhost)
        var popupSelection = 0
        #expect(view.completions(forPartialWordRange: popupWord, indexOfSelectedItem: &popupSelection)?.contains("HelloWorld") == true)
        let savedPreview = view.semanticGhost
        var inlinePreview = try #require(savedPreview)
        inlinePreview.nextEdit = false
        view.semanticGhost = inlinePreview
        #expect(view.hasExclusiveCopilotInlineGhost)
        #expect(view.completions(forPartialWordRange: popupWord, indexOfSelectedItem: &popupSelection)?.isEmpty != false)
        view.semanticGhost = savedPreview
        let panelBeforeNativeUI = try #require(view.semanticGhostPanel)
        var previewCloseCount = 0
        let closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panelBeforeNativeUI, queue: .main) { _ in
            MainActor.assumeIsolated { previewCloseCount += 1 }
        }
        defer { NotificationCenter.default.removeObserver(closeObserver) }
        @MainActor final class PopupObservation {
            var shown = false; var tabConsumed = false; var escapeConsumed = false; var attempts = 0
        }
        let popupObservation = PopupObservation()
        // AppKit can track a completion popup in a nested event loop. A common-
        // mode timer observes that real popup and posts Escape to this QA app only.
        // Also exercise a real completion command while the retained NES target
        // is offscreen. AppKit must bring its actual completion into view.
        view.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 500))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: view.enclosingScrollView!.contentView)
        #expect(!view.nextEditTargetIsVisible && copilot.hasSuggestions(in: view))
        try prepareNativeCommandWindow(window, editor: view)
        #expect(!view.nextEditTargetIsVisible && copilot.hasSuggestions(in: view))
        let popupTimer = Timer(timeInterval: 0.05, repeats: true) { timer in
            let finished = MainActor.assumeIsolated {
                popupObservation.attempts += 1
                guard view.isNativeCompletionVisible || popupObservation.attempts >= 100 else { return false }
                popupObservation.shown = view.isNativeCompletionVisible
                let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
                let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                popupObservation.tabConsumed = copilot.handleKey(tab, in: view)
                popupObservation.escapeConsumed = copilot.handleKey(escape, in: view)
                NSApp.postEvent(escape, atStart: true)
                return true
            }
            if finished { timer.invalidate() }
        }
        RunLoop.main.add(popupTimer, forMode: .common)
        #expect(!view.isNativeCompletionVisible)
        print("NES_NATIVE ESC before range=\(view.rangeForUserCompletion) selected=\(view.selectedRange()) visibleRect=\(view.visibleRect)")
        try requestWordCompletion()
        try await waitFor("native completion popup observed") { popupObservation.attempts > 0 && !popupTimer.isValid }
        print("NES_NATIVE ESC after attempts=\(popupObservation.attempts) shown=\(popupObservation.shown)")
        #if DEBUG
        #expect(completionInvocationEvents == [96])
        #expect(completionCommandEvents == ["priorWindowMove", "F5"])
        #expect(finalCompletionEvents.count == 1)
        #expect(finalCompletionEvents.last?.hasPrefix("insertCompletion final=true movement=\(NSCancelTextMovement) ") == true)
        #endif
        popupTimer.invalidate()
        #if DEBUG
        observingNativeCommand = false
        #endif
        #expect(popupObservation.shown)
        #expect(!popupObservation.tabConsumed && !popupObservation.escapeConsumed)
        #expect(view.string == popupSource)
        #expect(!view.string.contains("Goodbye"))
        #expect(!view.isNativeCompletionVisible)
        view.breakUndoCoalescing(); view.undoManager?.removeAllActions()
        view.insertText(popupSource, replacementRange: NSRange(location: 0, length: view.string.utf16.count))
        view.selectedRange = NSRange(location: NSMaxRange(popupWord), length: 0)
        view.scrollRangeToVisible(view.selectedRange()); view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try #require(view.rangeForUserCompletion == popupWord)
        try settleEditorWindow(window, editor: view)
        _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
        try await waitFor("native Tab NES baseline") { copilot.hasVisibleSuggestion(in: view) }
        let tabObservation = PopupObservation()
        try prepareNativeCommandWindow(window, editor: view)
        let tabTimer = Timer(timeInterval: 0.05, repeats: true) { timer in
            let finished = MainActor.assumeIsolated {
                tabObservation.attempts += 1
                guard view.isNativeCompletionVisible || tabObservation.attempts >= 100 else { return false }
                tabObservation.shown = view.isNativeCompletionVisible
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
                tabObservation.tabConsumed = copilot.handleKey(event, in: view)
                NSApp.postEvent(event, atStart: true)
                return true
            }
            if finished { timer.invalidate() }
        }
        RunLoop.main.add(tabTimer, forMode: .common)
        #expect(!view.isNativeCompletionVisible)
        print("NES_NATIVE TAB before range=\(view.rangeForUserCompletion) selected=\(view.selectedRange())")
        try requestWordCompletion()
        try await waitFor("native Tab applied") { !tabTimer.isValid && !view.isNativeCompletionVisible }
        print("NES_NATIVE TAB after attempts=\(tabObservation.attempts) shown=\(tabObservation.shown)")
        #if DEBUG
        #expect(completionInvocationEvents == [96, 96])
        #expect(completionCommandEvents == ["priorWindowMove", "F5", "priorWindowMove", "F5"])
        #expect(finalCompletionEvents.count == 2)
        #expect(finalCompletionEvents.last?.hasPrefix("insertCompletion final=true movement=\(NSTabTextMovement) ") == true)
        #endif
        tabTimer.invalidate()
        #if DEBUG
        observingNativeCommand = false
        #endif
        #expect(tabObservation.shown && !tabObservation.tabConsumed)
        let ordinaryResults = ["HelloWorld", "HelloUniverse"].map { (popupSource as NSString).replacingCharacters(in: popupWord, with: $0) }
        #expect(ordinaryResults.contains(view.string))
        #expect(!view.string.contains("Goodbye"))
        #expect(previewCloseCount == 1)
        #expect(panelBeforeNativeUI.parent == nil && !panelBeforeNativeUI.isVisible)

        // Normal multiple-document use: the first editor stays visible while a
        // second document owns native completion. No old NES child stays attached.
        do {
            let firstWindowText = view.string
            let otherDocument = Document()
            otherDocument.makeWindowControllers()
            let otherWindow = try #require(otherDocument.windowControllers.first?.window)
            let otherView = try #require(otherDocument.textViews.first as? EditorTextView)
            otherView.copilotController = copilot
            otherView.semanticDocumentContext = { (nil, "Python") }
            otherView.isAutomaticCompletionEnabled = false
            otherView.completionWordTypes = .document
            otherWindow.tabbingMode = .disallowed
            otherWindow.setContentSize(NSSize(width: 600, height: 320))
            otherView.insertText(popupSource, replacementRange: NSRange(location: 0, length: 0))
            otherView.selectedRange = NSRange(location: NSMaxRange(popupWord), length: 0)
            var otherClosed = false
            defer {
                if !otherClosed { otherWindow.orderOut(nil); otherDocument.close() }
                focus()
            }
            focusWindow(otherWindow, editor: otherView)
            try prepareNativeCommandWindow(otherWindow, editor: otherView)
            #expect(window.isVisible && otherWindow.isVisible && NSApp.keyWindow === otherWindow)
            #expect(otherView.rangeForUserCompletion == popupWord)
            let observation = PopupObservation()
            #if DEBUG
            var otherFinalWasEscape = false
            otherView.nativeCompletionTrace = { event in
                MainActor.assumeIsolated {
                    if event.hasPrefix("insertCompletion final=true") { otherFinalWasEscape = event.hasPrefix("insertCompletion final=true movement=\(NSCancelTextMovement) ") }
                    print("NES_OTHER_WINDOW " + event)
                }
            }
            defer { otherView.nativeCompletionTrace = nil }
            #endif
            let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
                let finished = MainActor.assumeIsolated {
                    observation.attempts += 1
                    guard otherView.isNativeCompletionVisible || observation.attempts >= 100 else { return false }
                    observation.shown = otherView.isNativeCompletionVisible
                    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: otherWindow.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                    observation.escapeConsumed = copilot.handleKey(escape, in: otherView)
                    NSApp.postEvent(escape, atStart: false)
                    return true
                }
                if finished { timer.invalidate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            defer { timer.invalidate() }
            let character = String(UnicodeScalar(NSF5FunctionKey)!)
            let command = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: otherWindow.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 96))
            NSApp.postEvent(command, atStart: false)
            let deadline = Date().addingTimeInterval(6)
            while (timer.isValid || otherView.isNativeCompletionVisible), Date() < deadline {
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            }
            #expect(observation.shown && !observation.escapeConsumed && !timer.isValid)
            #expect(!otherView.isNativeCompletionVisible && otherView.string == popupSource)
            #expect(view.string == firstWindowText && panelBeforeNativeUI.parent == nil)
            #if DEBUG
            #expect(otherFinalWasEscape)
            observingNativeCommand = false
            #endif
            print("MULTIWINDOW_UI_RESULT firstVisible=\(window.isVisible) secondPopup=\(observation.shown) oldPreviewClosed=\(previewCloseCount == 1) firstTextUnchanged=\(view.string == firstWindowText)")
            otherWindow.orderOut(nil); otherDocument.close(); otherClosed = true
            try prepareNativeCommandWindow(window, editor: view)
            #expect(!otherWindow.isVisible && NSApp.keyWindow === window && view.string == firstWindowText)
            #if DEBUG
            observingNativeCommand = false
            #endif
            print("MULTIWINDOW_TEARDOWN_READY firstKey=\(NSApp.keyWindow === window) secondClosed=\(!otherWindow.isVisible)")
        }
        // Subsequent cases replace the whole synthetic document directly. Native
        // completion undo records belong to this old fixture, not the next one.
        view.breakUndoCoalescing()
        view.undoManager?.removeAllActions()
        view.string = popupSource

        // Rebase a displayed payload through a real text mutation, then reject a
        // late response after a newer request has already displayed.
        let source = "first()\nvalue = Hello"
        let range = (source as NSString).range(of: "Hello")
        func setFixture(source: String, text: String, delay: Int = 0) throws {
            let item: LSPJSON = .object(["text": .string(text), "range": try CopilotInline.rangeJSON((source as NSString).range(of: "Hello"), in: source)])
            let payload: LSPJSON = .object(["source": .string(source), "edit": item, "delay": .number(delay)])
            try JSONEncoder().encode(payload).write(to: fixture)
        }
        view.lineEnding = .lf
        view.string = source; view.semanticDocumentContext = { (nil, "Python") }
        view.selectedRange = NSRange(location: 0, length: 0)
        try setFixture(source: source, text: "Goodbye")
        _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
        try await waitFor("indent precedence") { view.semanticGhost?.text == "Goodbye" }
        #expect(!copilot.handleKey(try key(48), in: view))
        #expect(view.string == source)
        view.selectedRange = NSRange(location: 1, length: 0)
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: view)
        #expect(copilot.handleKey(try key(48), in: view))
        #expect(view.string == "first()\nvalue = Goodbye")
        #expect(view.selectedRange() == NSRange(location: range.location + "Goodbye".utf16.count, length: 0))
        #expect(!copilot.handleKey(try key(48), in: view))
        view.undoManager?.undo()
        _ = copilot.perform(NSSelectorFromString("toggleNextEdits"))
        view.selectedRange = NSRange(location: range.location + 1, length: 0)
        _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
        try await waitFor("automatic Undo candidate") { view.semanticGhost?.text == "Goodbye" }
        #expect(copilot.handleKey(try key(48), in: view))
        try await Task.sleep(for: .milliseconds(250))
        func rpcCount(_ method: String = "textDocument/copilotInlineEdit") -> Int {
            guard let data = try? Data(contentsOf: sessionState), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let methods = json["methods"] as? [String: Int] else { return -1 }
            return methods[method] ?? 0
        }
        let beforeUndoRPCs = rpcCount()
        #expect(beforeUndoRPCs > 0)
        view.undoManager?.undo()
        try await Task.sleep(for: .milliseconds(350))
        #expect(view.string == source)
        #expect(view.semanticGhost == nil)
        #expect(rpcCount() == beforeUndoRPCs)
        _ = copilot.perform(NSSelectorFromString("toggleNextEdits"))
        view.selectedRange = NSRange(location: range.location, length: 0)
        try setFixture(source: source, text: "Goodbye")
        _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
        try await waitFor("rebase original") { view.semanticGhost?.text == "Goodbye" }
        view.insertText("# 😀\n", replacementRange: NSRange(location: 0, length: 0))
        // Non-key input posts AppKit notifications without a keyDown/typed repair.
        #expect(view.semanticGhost?.revision == view.semanticRevision)
        #expect(copilot.hasVisibleSuggestion(in: view))
        #expect(view.semanticGhost?.replacementRange?.location == range.location + "# 😀\n".utf16.count)
        #expect(view.semanticGhost?.snapshot == view.string)
        view.selectedRange = NSRange(location: view.string.utf16.count, length: 0)
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: view)
        #expect(copilot.hasSuggestions(in: view))
        #expect(copilot.handleKey(try key(53), in: view))
        #expect(view.semanticGhost == nil)
        view.string = source; view.selectedRange = NSRange(location: 1, length: 0)
        try setFixture(source: source, text: "OLD", delay: 1)
        _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
        try await Task.sleep(for: .milliseconds(100))
        let newer = source + "!"
        view.string = newer
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: view)
        try setFixture(source: newer, text: "NEW")
        _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
        try await waitFor("new response") { view.semanticGhost?.text == "NEW" }
        try await Task.sleep(for: .milliseconds(1100))
        #expect(view.semanticGhost?.text == "NEW")
        #expect(view.semanticGhost?.snapshot == newer)
        // NSTextInputClient's real marked-text state, rather than an overridden
        // hasMarkedText flag, owns Japanese composition and its Tab/Esc keys.
        view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(view.hasMarkedText() && view.markedRange().length == 2)
        let composing = view.string
        #expect(!copilot.hasVisibleSuggestion(in: view))
        #expect(!copilot.handleKey(try key(48), in: view))
        #expect(!copilot.handleKey(try key(53), in: view))
        let composingRPCs = rpcCount()
        _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rpcCount() == composingRPCs && LSPText.sameText(view.string, composing))
        view.insertText("仮名", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.hasMarkedText() && view.string.contains("仮名"))
        view.string = newer; view.selectedRange = NSRange(location: 1, length: 0)
        try setFixture(source: newer, text: "LATE_IME", delay: 1)
        _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
        try await Task.sleep(for: .milliseconds(100))
        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(view.hasMarkedText())
        let lateComposition = view.string
        try await Task.sleep(for: .milliseconds(1100))
        #expect(view.semanticGhost == nil && LSPText.sameText(view.string, lateComposition))
        view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.hasMarkedText() && view.string.contains("日本"))
        try setFixture(source: view.string, text: "AFTER_IME")
        _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
        try await waitFor("fresh NES after Japanese composition") { view.semanticGhost?.text == "AFTER_IME" }
        print("NES_IME_PASS actualMarkedText=true kanaCommit=true lateResponseRejected=true freshRequest=true")

        // The ordinary provider deliberately takes 500 ms. NES must reach the
        // peer during that wait, while the eventual usable inline result wins.
        let jointSource = "# NORMAL_FIRST\nHello"
        view.string = jointSource; view.selectedRange = NSRange(location: 3, length: 0)
        try setFixture(source: jointSource, text: "JOINT_NES")
        let jointBefore = rpcCount()
        _ = copilot.perform(NSSelectorFromString("toggleNextEdits"))
        _ = copilot.perform(NSSelectorFromString("triggerInline"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rpcCount() > jointBefore)
        #expect(view.semanticGhost == nil)
        try await waitFor("joint provider inline priority") { copilot.hasVisibleSuggestion(in: view) && view.semanticGhost?.nextEdit == false }
        #expect(view.string == jointSource)
        _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
        try await waitFor("joint previous shown NES") { view.semanticGhost?.text == "JOINT_NES" }
        let beforeAgreeingInline = rpcCount("textDocument/inlineCompletion")
        _ = copilot.perform(NSSelectorFromString("triggerInline"))
        try await waitFor("joint agreeing fast NES") { view.semanticGhost?.text == "JOINT_NES" && copilot.hasVisibleSuggestion(in: view) }
        #expect(rpcCount("textDocument/inlineCompletion") == beforeAgreeingInline)
        _ = copilot.perform(NSSelectorFromString("toggleNextEdits"))
        print("NES_JOINT_PASS concurrentRequest=true usableInlineWins=true agreeingNESGrace=true")
        do {
            _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
            try await waitFor("Tab focus candidate") { view.semanticGhost?.nextEdit == true && copilot.hasVisibleSuggestion(in: view) }
            let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 160, height: 24))
            window.contentView?.addSubview(field)
            let savedNext = view.nextKeyView
            defer { EditorTextView.tabMovesFocus = false; view.nextKeyView = savedNext; field.removeFromSuperview() }
            view.nextKeyView = field
            try #require(!EditorTextView.tabMovesFocus)
            view.toggleTabFocusMode(nil)
            #expect(EditorTextView.tabMovesFocus)
            #expect(!copilot.handleKey(try key(48), in: view))
            window.sendEvent(try key(48))
            #expect(window.firstResponder === field.currentEditor())
            #expect(window.firstResponder !== view && view.string == jointSource)
            // A focused native control owns its keyboard interaction even when
            // the proposal existed before focus left the editor.
            #expect(!copilot.handleKey(try key(48), in: view))
            view.toggleTabFocusMode(nil)
            #expect(!EditorTextView.tabMovesFocus)
        }
        focus()
        print("NES_FOCUS_PASS tabMovesFocus=true focusedControlOwnsKeys=true documentUnchanged=true")
        do {
            // Earlier cases deliberately dismiss NES. Let its public five-second
            // rejection cooldown expire before creating this fresh edit history.
            try await Task.sleep(for: .milliseconds(5100))
            let returningDocument = Document()
            returningDocument.makeWindowControllers()
            let returningWindow = try #require(returningDocument.windowControllers.first?.window)
            let returningView = try #require(returningDocument.textViews.first as? EditorTextView)
            returningView.copilotController = copilot
            returningView.semanticDocumentContext = { (nil, "Python") }
            returningWindow.tabbingMode = .disallowed
            returningView.string = "Hello\none()\ntwo()\nthree()\n"
            defer { returningWindow.orderOut(nil); returningDocument.close() }
            try settleEditorWindow(returningWindow, editor: returningView)
            returningView.insertText("!", replacementRange: NSRange(location: returningView.string.utf16.count, length: 0))
            let returningSource = returningView.string
            try setFixture(source: returningSource, text: "Bye")
            _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
            func waitReturning(_ label: String, _ condition: () -> Bool) async throws {
                for _ in 0..<200 {
                    focusWindow(returningWindow, editor: returningView)
                    if condition() { return }
                    try await Task.sleep(for: .milliseconds(20))
                }
                Issue.record("Returning document checkpoint: \(label); RPC=\(rpcCount())")
                throw CancellationError()
            }
            try await waitReturning("B requested") { copilot.hasVisibleSuggestion(in: returningView) }
            try settleEditorWindow(window, editor: view)
            view.insertText("!", replacementRange: NSRange(location: view.string.utf16.count, length: 0))
            try setFixture(source: view.string, text: "Bye")
            _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
            try await waitFor("A requested after B") { copilot.hasVisibleSuggestion(in: view) }
            try setFixture(source: returningSource, text: "Bye")
            try settleEditorWindow(returningWindow, editor: returningView)
            _ = copilot.perform(NSSelectorFromString("toggleNextEdits"))
            let beforeReturn = rpcCount()
            returningView.selectedRange = NSRange(location: (returningSource as NSString).range(of: "two").location, length: 0)
            try await waitReturning("B selection requests after A (before=\(beforeReturn))") { rpcCount() == beforeReturn + 1 && copilot.hasVisibleSuggestion(in: returningView) }
            NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: view)
            #expect(copilot.hasVisibleSuggestion(in: returningView))
            #expect(rpcCount() == beforeReturn + 1)
            // Hide without explicit rejection, preserving the same-line policy.
            _ = copilot.perform(NSSelectorFromString("toggleNextEdits"))
            _ = copilot.perform(NSSelectorFromString("toggleNextEdits"))
            let beforeCooldown = rpcCount()
            returningView.selectedRange = NSRange(location: returningView.selectedRange().location + 1, length: 0)
            try await Task.sleep(for: .milliseconds(150))
            #expect(rpcCount() == beforeCooldown && returningView.semanticGhost == nil)
            _ = copilot.perform(NSSelectorFromString("toggleNextEdits"))
            let untouchedDocument = Document()
            untouchedDocument.makeWindowControllers()
            let untouchedWindow = try #require(untouchedDocument.windowControllers.first?.window)
            let untouchedView = try #require(untouchedDocument.textViews.first as? EditorTextView)
            untouchedView.copilotController = copilot
            untouchedView.string = "Hello\nneverEdited()\n"
            untouchedView.semanticDocumentContext = { (nil, "Python") }
            defer { untouchedWindow.orderOut(nil); untouchedDocument.close() }
            try settleEditorWindow(untouchedWindow, editor: untouchedView)
            _ = copilot.perform(NSSelectorFromString("toggleNextEdits"))
            let beforeUntouched = rpcCount()
            untouchedView.selectedRange = NSRange(location: 7, length: 0)
            try await Task.sleep(for: .milliseconds(150))
            #expect(rpcCount() == beforeUntouched && untouchedView.semanticGhost == nil)
            _ = copilot.perform(NSSelectorFromString("toggleNextEdits"))
            print("NES_RETURN_PASS BtoAtoB=true recentHistoryRequests=true backgroundIgnored=true sameLineCooldown=true noHistorySilent=true")
        }
        focus()
        do {
            let splitDocument = Document()
            let splitURI = directory.appendingPathComponent("unrequested-split.py")
            try "Hello split".write(to: splitURI, atomically: true, encoding: .utf8)
            splitDocument.fileURL = splitURI
            splitDocument.makeWindowControllers()
            let splitWindow = try #require(splitDocument.windowControllers.first?.window)
            var requested: EditorTextView? = try #require(splitDocument.textViews.first as? EditorTextView)
            requested!.copilotController = copilot
            requested!.string = "Hello split"
            requested!.semanticDocumentContext = { (splitURI, "Python") }
            requested!.selectedRange = NSRange(location: 1, length: 0)
            splitWindow.tabbingMode = .disallowed
            defer { splitWindow.orderOut(nil); splitDocument.close() }
            try settleEditorWindow(splitWindow, editor: requested!)
            func waitSplit(_ checkpoint: String, _ condition: () -> Bool) async throws {
                for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
                Issue.record("Unrequested split checkpoint: \(checkpoint); status=\(copilot.connectionPresentation.detail); requestedLive=\(requested != nil); rpc=\(rpcCount())"); throw CancellationError()
            }
            try setFixture(source: requested!.string, text: "Bye")
            _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
            try await waitSplit("requested candidate") { requested.map { copilot.hasVisibleSuggestion(in: $0) } == true }
            requested!.insertText("!", replacementRange: NSRange(location: requested!.string.utf16.count, length: 0))
            try setFixture(source: requested!.string, text: "Bye")
            _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
            try await waitSplit("requested candidate") { requested.map { copilot.hasVisibleSuggestion(in: $0) } == true }
            let buffer = requested!.semanticBufferID, revision = requested!.semanticRevision
            let splits = try #require(splitDocument.viewController)
            splits.openSplitTextView(requested)
            let untouched = try #require(splitDocument.textViews.compactMap { $0 as? EditorTextView }.first(where: { $0 !== requested }))
            untouched.copilotController = copilot
            untouched.semanticDocumentContext = { (splitURI, "Python") }
            #expect(untouched.semanticBufferID == buffer && untouched.semanticRevision == revision)
            let beforeSplitRPC = rpcCount()
            weak var retired = requested
            autoreleasepool { splits.closeSplitTextView(requested); requested = nil }
            try settleEditorWindow(splitWindow, editor: untouched)
            try await waitSplit("requested detached") { retired?.window == nil }
            #expect(rpcCount() == beforeSplitRPC)
            try settleEditorWindow(window, editor: view)
            try setFixture(source: view.string, text: "Bye")
            _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
            try await waitFor("other document prunes after unrequested split") { copilot.hasVisibleSuggestion(in: view) }
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: sessionState)) as? [String: Any]
            let versions = json?["versions"] as? [String: Int]
            #expect(versions?[splitURI.absoluteString] == 2)
            try settleEditorWindow(splitWindow, editor: untouched)
            try setFixture(source: untouched.string, text: "Bye")
            _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
            try await waitSplit("first sibling request") { copilot.hasVisibleSuggestion(in: untouched) }
            let after = try JSONSerialization.jsonObject(with: Data(contentsOf: sessionState)) as? [String: Any]
            #expect((after?["versions"] as? [String: Int])?[splitURI.absoluteString] == 2)
            print("NES_UNREQUESTED_SPLIT_PASS originalViewDetached=true siblingNeverRequestedBeforePrune=true sharedBufferIdentity=true versionContinuity=true")
        }
        focus()
        do {
            let targetDocument = Document()
            targetDocument.makeWindowControllers()
            let targetWindow = try #require(targetDocument.windowControllers.first?.window)
            let targetView = try #require(targetDocument.textViews.first as? EditorTextView)
            let targetURI = directory.appendingPathComponent("target.py")
            let targetSource = "Hello target"
            targetView.copilotController = copilot
            targetView.string = targetSource
            targetView.semanticDocumentContext = { (targetURI, "Python") }
            targetView.selectedRange = NSRange(location: 1, length: 0)
            targetWindow.tabbingMode = .disallowed
            defer { targetWindow.orderOut(nil); targetDocument.close() }
            try settleEditorWindow(targetWindow, editor: targetView)
            try setFixture(source: targetSource, text: "Bye")
            _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
            for _ in 0..<200 {
                focusWindow(targetWindow, editor: targetView)
                if copilot.hasVisibleSuggestion(in: targetView) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(copilot.hasVisibleSuggestion(in: targetView))
            // Two document windows may own the same already-synchronized URI.
            // Closing the most recently requested view must not close the live
            // baseline still owned by the first window.
            do {
                let siblingDocument = Document()
                siblingDocument.makeWindowControllers()
                let siblingWindow = try #require(siblingDocument.windowControllers.first?.window)
                let siblingView = try #require(siblingDocument.textViews.first as? EditorTextView)
                siblingView.copilotController = copilot
                siblingView.string = targetSource
                siblingView.semanticDocumentContext = { (targetURI, "Python") }
                siblingView.selectedRange = NSRange(location: 1, length: 0)
                siblingWindow.tabbingMode = .disallowed
                try settleEditorWindow(siblingWindow, editor: siblingView)
                _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
                for _ in 0..<200 {
                    focusWindow(siblingWindow, editor: siblingView)
                    if copilot.hasVisibleSuggestion(in: siblingView) { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try #require(copilot.hasVisibleSuggestion(in: siblingView))
                siblingWindow.orderOut(nil); siblingDocument.close()
            }
            let source = "Hello source"
            view.string = source; view.selectedRange = NSRange(location: 1, length: 0)
            try settleEditorWindow(window, editor: view)
            let item: LSPJSON = .object(["text": .string("Bye"), "range": try CopilotInline.rangeJSON(NSRange(location: 0, length: 5), in: targetSource)])
            let payload: LSPJSON = .object(["source": .string(source), "edit": item,
                "target": .object(["uri": .string(targetURI.absoluteString), "version": .number(1)])])
            try JSONEncoder().encode(payload).write(to: fixture)
            _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
            try await waitFor("cross-file navigation hint") { view.semanticGhost?.text.contains("target.py") == true && copilot.hasVisibleSuggestion(in: view) }
            window.sendEvent(try key(48))
            #expect(NSApp.keyWindow === targetWindow && targetWindow.firstResponder === targetView)
            #expect(view.string == source && targetView.string == targetSource)
            try #require(copilot.hasVisibleSuggestion(in: targetView))
            let acceptKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: targetWindow.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
            targetWindow.sendEvent(acceptKey)
            #expect(targetView.string == "Bye target" && view.string == source)
            #expect(targetView.selectedRange() == NSRange(location: 3, length: 0))
            targetView.undoManager?.undo()
            #expect(targetView.string == targetSource && view.string == source)
            try settleEditorWindow(window, editor: view)
            _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
            try await waitFor("cross-file stale target baseline") { view.semanticGhost?.text.contains("target.py") == true && copilot.hasVisibleSuggestion(in: view) }
            targetView.string = targetSource + "!"
            #expect(!copilot.handleKey(try key(48), in: view))
            #expect(view.string == source && targetView.string == targetSource + "!")
            let unknown = directory.appendingPathComponent("never-requested.py")
            try targetSource.write(to: unknown, atomically: true, encoding: .utf8)
            let unknownPayload: LSPJSON = .object(["source": .string(source), "edit": item,
                "target": .object(["uri": .string(unknown.absoluteString), "version": .number(1)])])
            try JSONEncoder().encode(unknownPayload).write(to: fixture)
            _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
            try await waitFor("unknown cross-file target rejected") { copilot.connectionPresentation.detail.contains("表示できるAI候補") }
            #expect(view.semanticGhost == nil && view.string == source)
            #expect(try String(contentsOf: unknown, encoding: .utf8) == targetSource)
            print("NES_CROSS_FILE_PASS knownOpenTarget=true firstTabNavigationOnly=true secondTabAccept=true sourceUnchanged=true targetUndo=true staleTargetRejected=true existingUnknownTargetRejected=true siblingClosePreservesBaseline=true")
        }
        focus()
        do {
            // Keep this synthetic scenario unsaved even if exclusion checks
            // outlast AppKit's ordinary autosave timer. Restore runtime state;
            // do not change persisted application/user preferences.
            let autosavingDelay = NSDocumentController.shared.autosavingDelay
            NSDocumentController.shared.autosavingDelay = 3600
            defer { NSDocumentController.shared.autosavingDelay = autosavingDelay }
            let worktreeRoot = directory.appendingPathComponent("linked-project").resolvingSymlinksInPath()
            let projectRoot = worktreeRoot.appendingPathComponent("ordinary-project")
            let repository = directory.appendingPathComponent("project-admin")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            func fixtureGit(_ arguments: [String]) throws {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["--no-optional-locks"] + arguments; process.currentDirectoryURL = repository
                process.environment = ["PATH":"/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM":"1", "GIT_CONFIG_GLOBAL":"/dev/null", "GIT_TERMINAL_PROMPT":"0", "LC_ALL":"C"]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit(); try #require(process.terminationStatus == 0)
            }
            try fixtureGit(["init", "-q"])
            try fixtureGit(["config", "core.ignorecase", "true"])
            try fixtureGit(["-c", "core.hooksPath=/dev/null", "-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid", "commit", "--allow-empty", "-qm", "fixture"])
            try fixtureGit(["worktree", "add", "-qb", "nes-native", worktreeRoot.path])
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            // Preserve Git's literal whitespace/CR condition semantics in a
            // real registered worktree. All data here is synthetic and private.
            let marker = worktreeRoot.appendingPathComponent(".git")
            let pointer = try String(contentsOf: marker, encoding: .utf8)
            let oldAdmin = URL(fileURLWithPath: String(pointer.dropFirst(8)).trimmingCharacters(in: CharacterSet(charactersIn: "\r\n")))
            let spacedAdmin = URL(fileURLWithPath: oldAdmin.path + " ", isDirectory: true)
            try FileManager.default.moveItem(at: oldAdmin, to: spacedAdmin)
            try ("gitdir: " + spacedAdmin.path + "\n").write(to: marker, atomically: true, encoding: .utf8)
            let commonAdmin = repository.appendingPathComponent(".git")
            try "[core]\nignoreCase=false\n".write(to: commonAdmin.appendingPathComponent("nonmatching.conf"), atomically: true, encoding: .utf8)
            try "[core]\nexcludesFile=worktree-conditional-excludes\n".write(to: commonAdmin.appendingPathComponent("matching.conf"), atomically: true, encoding: .utf8)
            try "sensitive.py\nconditional-excluded.py\n".write(to: worktreeRoot.appendingPathComponent("worktree-conditional-excludes"), atomically: true, encoding: .utf8)
            try fixtureGit(["config", "core.excludesFile", "worktree-excludes"])
            let configURL = commonAdmin.appendingPathComponent("config")
            var config = try String(contentsOf: configURL, encoding: .utf8)
            config += "[includeIf \"onbranch:nes-native \"]\npath=nonmatching.conf\n[includeIf \"onbranch:nes-native\r\"]\npath=nonmatching.conf\n"
            config += "[includeIf \"gitdir:" + spacedAdmin.path + "\"]\npath=matching.conf\n"
            // The including file is outside admin but within the validated
            // main worktree. Its literal ./ directory must retain trailing **.
            try "[extensions]\nworktreeConfig=true\n[includeIf \"gitdir:./\"]\npath=.git/context-matching.conf\n".write(to: repository.appendingPathComponent("local-conditions.conf"), atomically: true, encoding: .utf8)
            // Git ignores the feature declaration in this included file. A
            // host must not load this overriding per-worktree config early.
            try "[core]\nignoreCase=false\nexcludesFile=\n".write(to: spacedAdmin.appendingPathComponent("config.worktree"), atomically: true, encoding: .utf8)
            try "[core]\nexcludesFile=worktree-context-excludes\n".write(to: commonAdmin.appendingPathComponent("context-matching.conf"), atomically: true, encoding: .utf8)
            try "sensitive.py\nconditional-excluded.py\norigin-excluded.py\n".write(to: worktreeRoot.appendingPathComponent("worktree-context-excludes"), atomically: true, encoding: .utf8)
            config += "[include]\npath=../local-conditions.conf\n"
            try config.write(to: configURL, atomically: true, encoding: .utf8)
            try "sensitive.py\n".write(to: worktreeRoot.appendingPathComponent("worktree-excludes"), atomically: true, encoding: .utf8)
            try "PRIVATE/\n foo.py\n".write(to: worktreeRoot.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            let sourceURI = projectRoot.appendingPathComponent("source.py"), targetURI = projectRoot.appendingPathComponent("unopened.py")
            let diskSourceText = "Hello source", sourceText = "Hello source!", targetText = "Hello unopened"
            try diskSourceText.write(to: sourceURI, atomically: true, encoding: .utf8)
            try targetText.write(to: targetURI, atomically: true, encoding: .utf8)
            let project = DirectoryDocument()
            project.fileURL = projectRoot
            try project.read(from: projectRoot, ofType: "public.folder")
            project.makeWindowControllers()
            let projectWindow = try #require(project.windowControllers.first?.window)
            projectWindow.tabbingMode = .disallowed
            defer { projectWindow.orderOut(nil); project.close() }
            #expect(await project.openDocument(at: sourceURI, asPlainText: true))
            let sourceDocument = try #require(project.currentDocument as? Document)
            let sourceView = try #require(sourceDocument.textViews.first as? EditorTextView)
            sourceView.copilotController = copilot
            #if DEBUG
            sourceView.nativeCompletionTrace = { print("NES_PROJECT_TRACE " + $0) }
            #endif
            sourceView.semanticDocumentContext = { (sourceURI, "Python") }
            sourceView.insertText("!", replacementRange: NSRange(location: diskSourceText.utf16.count, length: 0))
            sourceDocument.updateChangeCount(.changeDone)  // Explicit dirty fixture outside an NSApplication event group.
            #expect(sourceDocument.isDocumentEdited)
            sourceView.selectedRange = NSRange(location: 1, length: 0)
            try settleEditorWindow(projectWindow, editor: sourceView)
            let badEdit: LSPJSON = .object(["text": .string("UNVERIFIED"), "range": try CopilotInline.rangeJSON(NSRange(location: 0, length: 5), in: targetText)])
            let freshEdit: LSPJSON = .object(["text": .string("VERIFIED"), "range": try CopilotInline.rangeJSON(NSRange(location: 0, length: 5), in: targetText)])
            for excluded in [projectRoot.appendingPathComponent("Sensitive.py"), projectRoot.appendingPathComponent("private/normal.py"), projectRoot.appendingPathComponent(" foo.py"), projectRoot.appendingPathComponent("conditional-excluded.py"), projectRoot.appendingPathComponent("origin-excluded.py"), worktreeRoot.appendingPathComponent("outside-open-folder.py")] {
                try FileManager.default.createDirectory(at: excluded.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "Hello excluded".write(to: excluded, atomically: true, encoding: .utf8)
                let rejected: LSPJSON = .object(["source": .string(sourceText), "edit": badEdit,
                    "target": .object(["uri": .string(excluded.absoluteString), "version": .number(999)])])
                try JSONEncoder().encode(rejected).write(to: fixture)
                _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
                for _ in 0..<250 {
                    if copilot.connectionPresentation.detail.contains("表示できるAI候補") { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(copilot.connectionPresentation.detail.contains("表示できるAI候補"))
                #expect(sourceView.semanticGhost == nil && project.currentDocument === sourceDocument)
                let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: projectWindow.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
                #expect(!copilot.handleKey(tab, in: sourceView))
                let data = try Data(contentsOf: sessionState)
                let state = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect((state["versions"] as? [String: Int])?[excluded.absoluteString] == nil)
                #expect((state["openedURIs"] as? [String])?.contains(excluded.absoluteString) == false)
                #expect(try String(contentsOf: excluded, encoding: .utf8) == "Hello excluded")
            }
            print("NES_GIT_EXCLUSION_PASS relativeExcludesFile=true ancestorRules=true outsideOpenedFolderRejected=true caseFile=true caseParent=true leadingSpace=true conditionalTrailingSpace=true literalCR=true gitdirTrailingSpace=true relativeConditionOrigin=true directFormatActivationOnly=true noNavigation=true noTargetSync=true")
            try #require(sourceDocument.isDocumentEdited && !sourceDocument.semanticIsClosed)
            try #require(try String(contentsOf: sourceURI, encoding: .utf8) == diskSourceText)
            let payload: LSPJSON = .object(["cases": .array([
                .object(["source": .string(sourceText), "edit": badEdit, "target": .object(["uri": .string(targetURI.absoluteString), "version": .number(999)])]),
                .object(["source": .string(targetText), "edit": freshEdit])])])
            try JSONEncoder().encode(payload).write(to: fixture)
            _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
            for _ in 0..<200 {
                if copilot.hasVisibleSuggestion(in: sourceView) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(sourceView.semanticGhost?.text.contains("再確認") == true)
            #expect(project.currentDocument === sourceDocument)
            let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: projectWindow.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
            if let panel = sourceView.semanticGhostPanel?.contentView { try capture(panel, name: "project-navigation") }
            projectWindow.sendEvent(tab)
            var targetView: EditorTextView?
            for _ in 0..<250 {
                if let document = project.currentDocument as? Document, document.fileURL == targetURI,
                   let view = document.textViews.first as? EditorTextView, copilot.hasVisibleSuggestion(in: view) { targetView = view; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if targetView == nil { Issue.record("Project navigation checkpoint: status=\(copilot.connectionPresentation.detail); current=\(project.currentDocument?.fileURL?.path ?? "nil"); target=\(targetURI.path); language=\((project.currentDocument as? Document)?.textViews.first.flatMap { ($0 as? EditorTextView)?.semanticDocumentContext?().syntax } ?? "nil")") }
            let destination = try #require(targetView)
            #expect(destination.string == targetText && sourceDocument.textStorage.string == sourceText)
            #expect(destination.semanticGhost?.text == "VERIFIED")
            #expect(sourceDocument.isDocumentEdited && !sourceDocument.semanticIsClosed)
            #expect(try String(contentsOf: sourceURI, encoding: .utf8) == diskSourceText)
            #expect(try String(contentsOf: targetURI, encoding: .utf8) == targetText)
            destination.selectedRange = NSRange(location: 1, length: 0)
            projectWindow.sendEvent(tab)
            #expect(destination.string == "VERIFIED unopened" && sourceDocument.textStorage.string == sourceText)
            destination.undoManager?.undo()
            #expect(destination.string == targetText)
            let dirtyURI = projectRoot.appendingPathComponent("unsynchronized.py")
            let dirtyDisk = "Hello disk", dirtyMemory = "Hello disk!"
            try dirtyDisk.write(to: dirtyURI, atomically: true, encoding: .utf8)
            #expect(await project.openDocument(at: dirtyURI, asPlainText: true))
            let dirtyDocument = try #require(project.currentDocument as? Document)
            let dirtyView = try #require(dirtyDocument.textViews.first as? EditorTextView)
            dirtyView.copilotController = copilot
            dirtyView.insertText("!", replacementRange: NSRange(location: dirtyDisk.utf16.count, length: 0))
            dirtyDocument.updateChangeCount(.changeDone)
            #expect(dirtyDocument.isDocumentEdited && dirtyDocument.textStorage.string == dirtyMemory)
            // No suggestion request has ever synchronized this dirty target.
            #expect(await project.openDocument(at: sourceURI, asPlainText: true))
            let returning = try #require(sourceDocument.textViews.first as? EditorTextView)
            returning.copilotController = copilot
            returning.selectedRange = NSRange(location: 1, length: 0)
            try settleEditorWindow(projectWindow, editor: returning)
            let dirtyPayload: LSPJSON = .object(["cases": .array([
                .object(["source": .string(sourceText), "edit": badEdit, "target": .object(["uri": .string(dirtyURI.absoluteString), "version": .number(999)])]),
                .object(["source": .string(dirtyMemory), "edit": freshEdit])])])
            try JSONEncoder().encode(dirtyPayload).write(to: fixture)
            _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
            for _ in 0..<200 { if copilot.hasVisibleSuggestion(in: returning) { break }; try await Task.sleep(for: .milliseconds(20)) }
            #expect(returning.semanticGhost?.text.contains("再確認") == true)
            projectWindow.sendEvent(tab)
            for _ in 0..<250 {
                if project.currentDocument === dirtyDocument, let active = dirtyDocument.textViews.first as? EditorTextView,
                   copilot.hasVisibleSuggestion(in: active) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let dirtyForeground = try #require(dirtyDocument.textViews.first as? EditorTextView)
            #expect(project.currentDocument === dirtyDocument && copilot.hasVisibleSuggestion(in: dirtyForeground))
            #expect(dirtyForeground.semanticGhost?.text == "VERIFIED" && dirtyForeground.string == dirtyMemory)
            #expect(dirtyDocument.isDocumentEdited && sourceDocument.textStorage.string == sourceText)
            #expect(try String(contentsOf: dirtyURI, encoding: .utf8) == dirtyDisk)
            print("NES_PROJECT_PASS realGitWorktree=true nestedOpenedFolder=true explicitOpenRoot=true unopenedNavigation=true unownedVersion999NeverApplied=true foregroundFreshRequest=true sourceUnsavedPreserved=true secondTabAdoptsFreshOnly=true targetUndo=true unsynchronizedDirtyTargetPreserved=true")
        }
        focus()
        // Use a fresh synthetic document and a private event-group manager.
        // XCTest dispatches multiple synthetic user events in one task, while
        // real NSApplication closes each event's group. Never close a document's
        // live automatic groups: an asynchronous autosave can own one of them.
        do {
            let normalizationDocument = Document()
            let undo = UndoManager(); undo.groupsByEvent = false
            normalizationDocument.undoManager = undo
            normalizationDocument.makeWindowControllers()
            let window = try #require(normalizationDocument.windowControllers.first?.window)
            let view = try #require(normalizationDocument.textViews.first as? EditorTextView)
            view.copilotController = copilot
            view.semanticDocumentContext = { (nil, "Python") }
            func focusNormalization() {
                focusWindow(window, editor: view)
            }
            func waitForNormalization(_ label: String, _ condition: () -> Bool) async throws {
                for _ in 0..<200 { focusNormalization(); if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
                Issue.record("Normalization checkpoint: \(label); active=\(NSApp.isActive); key=\(NSApp.keyWindow === window); responder=\(window.firstResponder === view); selected=\(view.selectedRange()); revision=\(view.semanticRevision); ghostRevision=\(view.semanticGhost?.revision ?? -1); ghostCaret=\(view.semanticGhost?.caret ?? -1); ghostCurrent=\(view.semanticGhostIsCurrent); snapshotSame=\(view.semanticGhost.map { LSPText.sameText($0.snapshot, view.string) } ?? false); marked=\(view.hasMarkedText()); phase=\(copilot.connectionPresentation.phase); detail=\(copilot.connectionPresentation.detail)"); throw CancellationError()
            }
            func key(_ code: UInt16) throws -> NSEvent {
                try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: code == 48 ? "\t" : "\u{1b}", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            }
            focusNormalization()
            try prepareNativeCommandWindow(window, editor: view)
            #if DEBUG
            observingNativeCommand = false
            #endif
            defer { window.orderOut(nil); normalizationDocument.close() }
            let decomposed = "e\u{301} Hello!"
            view.string = decomposed; view.selectedRange = NSRange(location: 3, length: 0)
            try setFixture(source: decomposed, text: "Bye")
            try settleEditorWindow(window, editor: view)
            _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
            try await waitForNormalization("normalization original") { copilot.hasVisibleSuggestion(in: view) }
            undo.beginUndoGrouping()
            view.insertText("é", replacementRange: NSRange(location: 0, length: 2))
            undo.endUndoGrouping()
            #expect(LSPText.sameText(view.string, "é Hello!"))
            #expect(view.semanticGhost?.replacementRange == NSRange(location: 2, length: 5))
            #expect(view.semanticGhost?.revision == view.semanticRevision && copilot.hasVisibleSuggestion(in: view))
            undo.beginUndoGrouping()
            window.sendEvent(try key(48))
            undo.endUndoGrouping()
            #expect(LSPText.sameText(view.string, "é Bye!"))
            view.undoManager?.undo()
            #expect(LSPText.sameText(view.string, "é Hello!"))
            view.undoManager?.undo()
            #expect(LSPText.sameText(view.string, decomposed))
            view.undoManager?.redo()
            #expect(LSPText.sameText(view.string, "é Hello!"))
            let dismissedSource = view.string
            view.selectedRange = NSRange(location: 2, length: 0)
            try setFixture(source: dismissedSource, text: "Bye")
            _ = copilot.perform(NSSelectorFromString("toggleNextEdits"))
            _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
            try await waitForNormalization("dismiss original") { copilot.hasVisibleSuggestion(in: view) }
            window.sendEvent(try key(53))
            #expect(view.semanticGhost == nil)
            let dismissedRPCs = rpcCount()
            try await Task.sleep(for: .milliseconds(300))
            view.selectedRange = NSRange(location: view.string.utf16.count, length: 0)
            NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: view)
            try await Task.sleep(for: .milliseconds(450))
            #expect(rpcCount() == dismissedRPCs)
            try setFixture(source: dismissedSource + "!", text: "Bye")
            undo.beginUndoGrouping()
            view.insertText("!", replacementRange: NSRange(location: view.string.utf16.count, length: 0))
            undo.endUndoGrouping()
            try await waitForNormalization("new edit resumes after dismissal") { rpcCount() > dismissedRPCs && copilot.hasVisibleSuggestion(in: view) }
            _ = copilot.perform(NSSelectorFromString("toggleNextEdits"))
            let hunkSource = "old + " + String(repeating: "context ", count: 600) + "middle + old"
            try #require(hunkSource.utf16.count > 2048)
            view.string = hunkSource; view.selectedRange = NSRange(location: 0, length: 0)
            let hunkPayload: LSPJSON = .object(["source": .string(hunkSource), "edit": .object([
                "text": .string(hunkSource.replacingOccurrences(of: "old", with: "new")), "range": try CopilotInline.rangeJSON(NSRange(location: 0, length: hunkSource.utf16.count), in: hunkSource)])])
            try JSONEncoder().encode(hunkPayload).write(to: fixture)
            _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
            try await waitForNormalization("derived two-hunk proposal") { copilot.hasVisibleSuggestion(in: view) }
            #expect(view.semanticGhost?.replacementHunks.count == 2)
            undo.beginUndoGrouping()
            view.insertText("updated😀", replacementRange: (view.string as NSString).range(of: "middle"))
            undo.endUndoGrouping()
            #expect(copilot.hasVisibleSuggestion(in: view) && view.semanticGhost?.replacementHunks.count == 2)
            let editedIsland = hunkSource.replacingOccurrences(of: "middle", with: "updated😀")
            #expect(LSPText.sameText(view.string, editedIsland))
            // Column zero intentionally gives Tab to indentation. Exercise
            // adoption from inside the affected word instead.
            view.selectedRange = NSRange(location: 1, length: 0)
            try #require(copilot.hasVisibleSuggestion(in: view))
            undo.beginUndoGrouping()
            window.sendEvent(try key(48))
            undo.endUndoGrouping()
            let acceptedHunks = editedIsland.replacingOccurrences(of: "old", with: "new")
            try #require(LSPText.sameText(view.string, acceptedHunks))
            #expect(view.selectedRange() == NSRange(location: acceptedHunks.utf16.count, length: 0))
            undo.undo()
            #expect(LSPText.sameText(view.string, editedIsland))
            undo.undo()
            #expect(LSPText.sameText(view.string, hunkSource))
            undo.redo(); undo.redo()
            #expect(LSPText.sameText(view.string, acceptedHunks))
            print("NES_HUNKS_PASS twoDerivedHunks=true largeUTF16=\(hunkSource.utf16.count) unchangedIslandRebase=true lastActualCaret=true separateUndo=true redo=true")
        }
        focus()
        // A remote whole-line edit starts at column zero. Its second Tab must
        // adopt, not insert indentation after the navigation stage.
        let lineSource = "first()\na()\nb()\nc()\nHello"
        view.string = lineSource; view.selectedRange = NSRange(location: 1, length: 0)
        try setFixture(source: lineSource, text: "Goodbye")
        _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
        try await waitFor("line-start jump") { view.semanticGhost?.snapshot == lineSource && view.semanticGhost?.text == "Goodbye" }
        #expect(copilot.handleKey(try key(48), in: view))
        #expect(view.string == lineSource)
        #expect(copilot.handleKey(try key(48), in: view))
        #expect(view.string == "first()\na()\nb()\nc()\nGoodbye")
        view.string = newer; view.selectedRange = NSRange(location: 1, length: 0)
        try setFixture(source: newer, text: "NEW")
        _ = copilot.perform(NSSelectorFromString("triggerNextEdit"))
        try await waitFor("foreign document baseline") { view.semanticGhost?.text == "NEW" }
        view.semanticDocumentContext = { (URL(fileURLWithPath: "/synthetic/other.py"), "Python") }
        #expect(!copilot.hasSuggestions(in: view))
        #expect(!copilot.handleKey(try key(48), in: view))
        #expect(view.string == newer)
    }

    @Test func rewritePreviewDoesNotEditAndAcceptanceHasOneUndoStep() throws {
        let document = Document()
        document.makeWindowControllers()
        let window = try #require(document.windowControllers.first?.window)
        let view = try #require(document.textViews.first as? EditorTextView)
        defer { window.orderOut(nil) }
        let original = "def f(number):\n    return value\n"
        view.string = original
        view.semanticDocumentContext = { (nil, "Python") }
        view.selectedRange = NSRange(location: 13, length: 0)
        let range = (original as NSString).range(of: "value")
        let item: LSPJSON = .object(["text": .string("number"), "range": try CopilotInline.rangeJSON(range, in: original)])
        let edit = try CopilotInline.nextEdit(item, text: original)
        view.semanticGhost = SemanticGhostPreview(text: edit.text, snapshot: original, caret: 13, fileURL: nil,
                                                  language: .python, copilot: true, languageId: "python",
                                                  nextEdit: true, replacementRange: edit.range, replacedText: "value", revision: view.semanticRevision)
        #expect(view.string == original)
        #expect(document.undoManager?.canUndo == false)
        view.semanticGhost = nil
        #expect(SemanticActionApplication.apply([edit], title: "Accept Copilot Next Edit", to: view))
        #expect(view.string == "def f(number):\n    return number\n")
        document.undoManager?.undo()
        #expect(view.string == original)
        #expect(document.undoManager?.canUndo == false)
        document.undoManager?.redo()
        #expect(view.string == "def f(number):\n    return number\n")
    }

    @Test func nextEditCannotApplyDuringCompositionOrMultipleSelection() throws {
        let document = Document()
        document.makeWindowControllers()
        let window = try #require(document.windowControllers.first?.window)
        let view = try #require(document.textViews.first as? EditorTextView)
        defer { window.orderOut(nil) }
        view.string = "abc"
        let edit = LSPText.Edit(range: NSRange(location: 0, length: 1), text: "x", primary: true)
        view.selectedRange = NSRange(location: 0, length: 0)
        view.insertionLocations = [2]
        #expect(view.selectedRange().location == 0)
        #expect(!SemanticActionApplication.apply([edit], title: "Accept Copilot Next Edit", to: view))
        #expect(view.string == "abc")
        view.insertionLocations = []
        view.selectedRange = NSRange(location: 0, length: 0)
        view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = view.string
        #expect(!SemanticActionApplication.apply([edit], title: "Accept Copilot Next Edit", to: view))
        #expect(view.string == marked)
    }
}
