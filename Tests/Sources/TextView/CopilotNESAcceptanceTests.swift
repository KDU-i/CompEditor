// SPDX-License-Identifier: Apache-2.0
import AppKit
import LineEnding
import Testing
@testable import CotEditor

@MainActor @Suite(.serialized) struct CopilotNESAcceptanceTests {
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
        let editorController = EditorTextViewController(document: document)
        editorController.loadView()
        let view = editorController.textView
        view.string = "NO_NES"
        view.semanticDocumentContext = { (nil, "Python") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.tabbingMode = .disallowed
        window.contentViewController = editorController
        window.setContentSize(NSSize(width: 600, height: 300))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        _ = NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
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
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("Synthetic checkpoint failed: \(checkpoint); RPC count=\(rpcCount()); active=\(NSApp.isActive); key=\(NSApp.keyWindow === window); responder=\(window.firstResponder === view); visible=\(window.isVisible); canKey=\(window.canBecomeKey); python=\(view.semanticDocumentContext?().syntax == "Python")")
            throw CancellationError()
        }
        func rpcCount() -> Int {
            guard let data = try? Data(contentsOf: state),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let methods = json["methods"] as? [String: Int] else { return 0 }
            return methods["textDocument/copilotInlineEdit"] ?? 0
        }
        try await waitUntil("authentication") { copilot.connectionPresentation.phase == .authenticated }
        _ = NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        try await waitUntil("focused editor", limit: 750) {
            // The test host can finish opening its initial empty window after auth.
            _ = NSApp.setActivationPolicy(.regular)
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true)
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
        let controller = EditorTextViewController(document: document)
        controller.loadView()
        let view = controller.textView
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.tabbingMode = .disallowed; window.contentViewController = controller
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
        func focus() {
            _ = NSApp.setActivationPolicy(.regular)
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeKey(); window.makeMain(); window.makeFirstResponder(view)
            for _ in 0..<50 { guard let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) else { break }; NSApp.sendEvent(event) }
        }
        func waitFor(_ label: String, _ condition: () -> Bool) async throws {
            for _ in 0..<1000 { focus(); if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
            Issue.record("NES031 checkpoint: \(label); active=\(NSApp.isActive); key=\(NSApp.keyWindow === window); phase=\(copilot.connectionPresentation.phase); status=\(copilot.connectionPresentation.detail)"); throw CancellationError()
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
        func key(_ code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: code == 48 ? "\t" : "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        focus(); copilot.installMenu()
        let menu = NSApp.mainMenu?.items.last
        defer {
            _ = copilot.perform(NSSelectorFromString("toggle"))
            if let menu { NSApp.mainMenu?.removeItem(menu) }
            window.orderOut(nil); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try await waitFor("authenticated") { copilot.connectionPresentation.phase == .authenticated }
        for language in ["Python", "Java"] {
            for newline in ["\n", "\r\n"] {
                for (replacement, insertion) in [("Goodbye😀", false), ("", false), ("one\n\ttwo", false), (" + added😀", true)] {
                    let source = (["# 😀", "first()", "second()", "third()", "value = Hello"] + (0..<30).map { "tail\($0)()" }).joined(separator: newline)
                    view.lineEnding = newline == "\r\n" ? .crlf : .lf
                    view.string = source; view.semanticDocumentContext = { (nil, language) }
                    view.selectedRange = NSRange(location: 2, length: 0)
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
                    #expect(copilot.handleKey(try key(48), in: view))
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
        // Exercise native ordinary-completion visibility with NES, retaining the
        // original normal-inline exclusion policy.
        let popupSource = "HelloWorld\nHelloUniverse\nfirst()\nvalue = Hello"
        let popupWord = (popupSource as NSString).range(of: "Hello", options: .backwards)
        view.lineEnding = .lf; view.string = popupSource
        view.semanticDocumentContext = { (nil, "Python") }
        view.selectedRange = NSRange(location: NSMaxRange(popupWord), length: 0)
        view.completionWordTypes = .document
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
        @MainActor final class PopupObservation {
            var shown = false; var tabConsumed = false; var escapeConsumed = false; var attempts = 0
        }
        let popupObservation = PopupObservation()
        // AppKit can track a completion popup in a nested event loop. A common-
        // mode timer observes that real popup and posts Escape to this QA app only.
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
        view.complete(nil)
        try await waitFor("native completion popup observed") { popupObservation.attempts > 0 && !popupTimer.isValid }
        popupTimer.invalidate()
        #expect(popupObservation.shown)
        #expect(!popupObservation.tabConsumed && !popupObservation.escapeConsumed)
        #expect(!view.string.contains("Goodbye"))
        #expect(!view.isNativeCompletionVisible)
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
        func rpcCount() -> Int {
            guard let data = try? Data(contentsOf: sessionState), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let methods = json["methods"] as? [String: Int] else { return -1 }
            return methods["textDocument/copilotInlineEdit"] ?? 0
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
        copilot.typed(in: view, previous: source)
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
        let controller = EditorTextViewController(document: document)
        controller.loadView()
        let view = controller.textView
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
        let controller = EditorTextViewController(document: document)
        controller.loadView()
        let view = controller.textView
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
