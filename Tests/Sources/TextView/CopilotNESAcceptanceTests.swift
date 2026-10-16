// SPDX-License-Identifier: Apache-2.0
import AppKit
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
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        try await waitUntil("focused editor", limit: 750) {
            // The test host can finish opening its initial empty window after auth.
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
