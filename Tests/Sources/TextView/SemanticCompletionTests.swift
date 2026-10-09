// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import AppKit
import Testing
@testable import CotEditor

@MainActor struct SemanticCompletionTests {
    @Test func automaticPanelKeepsEditorFocus() {
        let panel = SemanticCandidatePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }

    @Test func compositionKeysPassThrough() {
        let document = Document()
        let controller = EditorTextViewController(document: document)
        controller.loadView()
        let view = controller.textView
        view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        #expect(!SemanticCompletionController.shared.handleAutomaticKey(event, in: view))
        #expect(view.hasMarkedText())
    }

    @Test func suggestionCellRendering() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        for language in ["python", "java"] {
            let source = root.appendingPathComponent("ExternalServers/acceptance/\(language)/CompletionCandidates.json")
            // Optional visual fixtures captured by the separately approved real-server harness.
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let original = try JSONDecoder().decode([LSPJSON].self, from: Data(contentsOf: source))
            let text = language == "python" ? "value = 'example'\nvalue.low" : "public class Demo { void run() { String value = \"example\"; value.subs } }"
            let marker = language == "python" ? "value.low" : "value.subs"
            let caret = NSMaxRange((text as NSString).range(of: marker))
            let count = language == "python" ? 3 : 4
            let items = LSPPresentation.candidates(original, text: text, fallback: NSRange(location: caret - count, length: count), caret: caret).map(\.item)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let metadata = items.first?["documentation"].string ?? items.first?["documentation"]["value"].string ?? items.first?["detail"].string
                let footerHeight: CGFloat = metadata?.isEmpty == false ? 54 : 24
                let height = CGFloat(items.count) * SemanticSuggestStyle.rowHeight + footerHeight + 2
                let surface = SemanticSuggestSurface(frame: NSRect(x: 0, y: 0, width: SemanticSuggestStyle.width, height: height))
                surface.appearance = NSAppearance(named: appearance)
                for (index, item) in items.enumerated() {
                    let row = SemanticCandidateRow(frame: NSRect(x: 1, y: surface.bounds.height - CGFloat(index + 1) * SemanticSuggestStyle.rowHeight - 1, width: surface.bounds.width - 2, height: SemanticSuggestStyle.rowHeight))
                    let cell = SemanticCandidateCell(item: item); cell.frame = row.bounds
                    row.addSubview(cell); surface.addSubview(row); row.isSelected = index == 0
                    cell.updateColors()
                }
                let rule = NSBox(frame: NSRect(x: 1, y: footerHeight, width: surface.bounds.width - 2, height: 1)); rule.boxType = .separator; surface.addSubview(rule)
                let footer = NSTextField(wrappingLabelWithString: String((metadata ?? "Tab accept preview   ↑ ↓ alternatives   Esc dismiss").prefix(120)))
                footer.font = .systemFont(ofSize: 11); footer.textColor = SemanticSuggestStyle.foreground
                footer.frame = NSRect(x: 8, y: 8, width: surface.bounds.width - 16, height: footerHeight - 12)
                surface.addSubview(footer)
                surface.layoutSubtreeIfNeeded()
                let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds)!
                surface.cacheDisplay(in: surface.bounds, to: bitmap)
                let png = bitmap.representation(using: .png, properties: [:])!
                #expect(!png.isEmpty)
                try png.write(to: root.appendingPathComponent("suggestions-vscode-\(language)-\(name).png"))
            }
        }
    }

    @Test func ghostLeavesTextStorageAndUndoUntouched() {
        let document = Document()
        let controller = EditorTextViewController(document: document); controller.loadView()
        let view = controller.textView
        view.string = "value.low"; view.selectedRange = NSRange(location: 9, length: 0)
        document.undoManager?.removeAllActions()
        let before = view.textStorage!.string
        view.semanticGhost = SemanticGhostPreview(text: "er", snapshot: before, caret: 9, fileURL: nil, language: .python)
        #expect(view.string == before && view.textStorage!.string == before)
        #expect(document.undoManager?.canUndo == false)
        #expect(!view.semanticGhostIsCurrent)  // Detached/unfocused editor cannot accept preview.
        view.semanticGhost = nil
        #expect(view.string == before && document.undoManager?.canUndo == false)
    }

    @Test func ghostRendererLightAndDark() throws {
        let midtone = SemanticGhostDrawing.color(background: NSColor(calibratedWhite: 0.5, alpha: 1)).usingColorSpace(.deviceRGB)!
        #expect(midtone.redComponent < 0.2)  // Avoid low-contrast gray against a midtone custom theme.
        final class Preview: NSView {
            var dark = false
            override func draw(_ dirtyRect: NSRect) {
                let background: NSColor = dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white
                background.setFill(); bounds.fill()
                let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
                let prefix = "value.low"
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: dark ? NSColor.white : .black]
                let width = (prefix as NSString).size(withAttributes: attrs).width
                (prefix as NSString).draw(at: NSPoint(x: 10, y: 12), withAttributes: attrs)
                SemanticGhostDrawing.draw(text: "er", in: NSRect(x: 10 + width, y: 12, width: 80, height: 24), font: font, background: background, dirtyRect: dirtyRect)
            }
        }
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<5 { root.deleteLastPathComponent() }
        for dark in [false, true] {
            let view = Preview(frame: NSRect(x: 0, y: 0, width: 220, height: 48)); view.dark = dark
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = bitmap.representation(using: .png, properties: [:])!
            #expect(!png.isEmpty)
            try png.write(to: root.appendingPathComponent("ghost-preview-\(dark ? "dark" : "light").png"))
        }
    }

    @Test func hoverUsesPlainTextAndRealMetadataRendering() throws {
        let hostile = "<img src='https://invalid.example/pixel'> [run](command:run) Map<T, U>"
        let sample = SemanticHoverView(text: hostile, width: 440)
        let label = sample.subviews.compactMap { $0 as? NSTextField }.first!
        #expect(label.stringValue == hostile && !label.isSelectable)
        #expect(label.maximumNumberOfLines == 12)
        var foundLink = false
        label.attributedStringValue.enumerateAttribute(.link, in: NSRange(location: 0, length: label.attributedStringValue.length)) { value, _, _ in if value != nil { foundLink = true } }
        #expect(!foundLink)
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<5 { root.deleteLastPathComponent() }
        for language in ["java", "python"] {
            let fixture = root.appendingPathComponent("SemanticTestBuild/hover-final/\(language)/HoverMetadata.json")
            guard FileManager.default.fileExists(atPath: fixture.path) else { continue }
            let metadata = try JSONDecoder().decode(LSPJSON.self, from: Data(contentsOf: fixture))
            let text = metadata["function"].string!
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let surface = SemanticHoverView(text: text, width: 440)
                surface.appearance = NSAppearance(named: appearance)
                surface.setFrameSize(NSSize(width: 440, height: min(260, max(36, surface.fittingSize.height))))
                surface.layoutSubtreeIfNeeded()
                let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds)!
                surface.cacheDisplay(in: surface.bounds, to: bitmap)
                let png = bitmap.representation(using: .png, properties: [:])!
                #expect(!png.isEmpty)
                try png.write(to: root.appendingPathComponent("hover-\(language)-\(name).png"))
            }
        }
    }

    @Test func hoverGlyphHitTestingUsesUTF16AndRejectsBlankSpace() {
        let document = Document()
        let controller = EditorTextViewController(document: document); controller.loadView()
        let view = controller.textView
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        view.string = "😀\r\nprobe(count)\nα_name\n"
        let layout = view.layoutManager!, container = view.textContainer!
        layout.ensureLayout(for: container)
        let glyph = layout.glyphRange(forCharacterRange: NSRange(location: 5, length: 1), actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyph, in: container).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let point = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        #expect(view.semanticHoverTarget(at: point)?.symbol == NSRange(location: 4, length: 5))
        let blank = view.convert(NSPoint(x: view.bounds.maxX - 10, y: rect.midY), to: nil)
        #expect(view.semanticHoverTarget(at: blank) == nil)
        #expect(view.string == "😀\r\nprobe(count)\nα_name\n")
    }

    @Test func actionImportUsesNativeUndoAndKeepsOtherDocumentUntouched() {
        let document = Document(), other = Document()
        let controller = EditorTextViewController(document: document); controller.loadView()
        let otherController = EditorTextViewController(document: other); otherController.loadView()
        let view = controller.textView, sibling = otherController.textView
        view.string = "Path\n"; sibling.string = "unsaved sibling"; view.isEditable = true; view.allowsUndo = true
        view.selectedRange = NSRange(location: 4, length: 0)
        let manager = document.undoManager!; manager.removeAllActions(); manager.beginUndoGrouping()
        #expect(SemanticActionApplication.apply([LSPText.Edit(range: NSRange(location: 0, length: 0), text: "from pathlib import Path\n\n")], title: "Import Path", to: view))
        manager.endUndoGrouping()
        #expect(view.string == "from pathlib import Path\n\nPath\n" && sibling.string == "unsaved sibling")
        manager.undo(); #expect(view.string == "Path\n" && view.selectedRange == NSRange(location: 4, length: 0))
        manager.redo(); #expect(view.string == "from pathlib import Path\n\nPath\n" && sibling.string == "unsaved sibling")
    }

    @Test func diagnosticDrawingLeavesTextAttributesAndUndoUntouched() throws {
        let document = Document()
        let controller = EditorTextViewController(document: document)
        controller.loadView(); let view = controller.textView
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 160); view.frame = controller.view.bounds
        view.string = "wrong warning\n"; view.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        document.undoManager?.removeAllActions()
        let before = NSAttributedString(attributedString: view.textStorage!)
        view.semanticDiagnostics = SemanticDiagnostics(snapshot: view.string, fileURL: nil, items: [
            LSPAssistance.Diagnostic(range: NSRange(location: 0, length: 5), severity: 1, message: "Synthetic error", raw: .null),
            LSPAssistance.Diagnostic(range: NSRange(location: 6, length: 7), severity: 2, message: "Synthetic warning", raw: .null)])
        view.layoutManager!.ensureLayout(for: view.textContainer!)
        // A detached scroll view can retain a nonzero clip origin; render the source origin.
        view.bounds.origin = .zero
        let glyphs = view.layoutManager!.glyphRange(forCharacterRange: NSRange(location: 0, length: 13), actualCharacterRange: nil)
        let rect = view.layoutManager!.boundingRect(forGlyphRange: glyphs, in: view.textContainer!).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        #expect(view.bounds.contains(rect))
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(view.textStorage!.isEqual(to: before))
        #expect(document.undoManager?.canUndo == false)
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<5 { root.deleteLastPathComponent() }
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("diagnostics-native-synthetic.png"))
    }

    @Test func signatureHighlightUsesActualParameterRangeWithoutEditing() {
        let signature = LSPAssistance.Signature(label: "add(left: int, right: int)", active: NSRange(location: 15, length: 10), documentation: nil)
        let surface = SemanticSignatureView(signature: signature, width: 440)
        let label = surface.subviews.compactMap { $0 as? NSTextField }.first!
        #expect(label.attributedStringValue.string == signature.label && !label.isSelectable)
        #expect(label.attributedStringValue.attribute(.backgroundColor, at: 15, effectiveRange: nil) != nil)
        #expect(label.attributedStringValue.attribute(.backgroundColor, at: 4, effectiveRange: nil) == nil)
    }

    @Test func completionAndAdditionalEditUndoTogether() throws {
        let document = Document()
        let controller = EditorTextViewController(document: document)
        controller.loadView()
        let view = controller.textView
        view.string = "obj.le"
        view.isEditable = true
        view.allowsUndo = true
        view.selectedRange = NSRange(location: 6, length: 0)
        let manager = document.undoManager!
        manager.removeAllActions()
        manager.beginUndoGrouping()
        let ranges = [NSRange(location: 0, length: 0), NSRange(location: 4, length: 2)]
        #expect(view.replace(with: ["import sample\n", "length"], ranges: ranges, selectedRanges: [NSRange(location: 24, length: 0)], actionName: "Semantic Completion"))
        manager.endUndoGrouping()
        #expect(view.string == "import sample\nobj.length")
        manager.undo()
        #expect(view.string == "obj.le")
        #expect(view.selectedRange == NSRange(location: 6, length: 0))
        manager.redo()
        #expect(view.string == "import sample\nobj.length")
    }
}
