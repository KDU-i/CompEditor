// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import AppKit
import LineEnding

struct SemanticDiagnostics {
    let snapshot: String
    let fileURL: URL?
    let items: [LSPAssistance.Diagnostic]
}

extension EditorTextView {
    func drawSemanticDiagnostics(in dirty: NSRect) {
        guard let diagnostics = semanticDiagnostics, diagnostics.snapshot == string,
              diagnostics.fileURL == semanticDocumentContext?().url,
              layoutOrientation == .horizontal, let layoutManager, let textContainer else { return }
        let visible = layoutManager.glyphRange(forBoundingRect: dirty.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y), in: textContainer)
        let chars = layoutManager.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
        for item in diagnostics.items where item.severity <= 2 && (NSIntersectionRange(item.range, chars).length > 0 || NSLocationInRange(item.range.location, chars)) {
            let range = NSIntersectionRange(item.range, chars)
            let glyphs = layoutManager.glyphRange(forCharacterRange: range.length > 0 ? range : NSRange(location: min(item.range.location, max(0, (string as NSString).length - 1)), length: min(1, (string as NSString).length)), actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
                let rect = rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                let path = NSBezierPath(); path.lineWidth = 1
                path.setLineDash([2, 2], count: 2, phase: 0)
                path.move(to: NSPoint(x: rect.minX, y: rect.maxY - 1))
                path.line(to: NSPoint(x: max(rect.minX + 4, rect.maxX), y: rect.maxY - 1))
                (item.severity == 1 ? NSColor.systemRed : .systemOrange).setStroke(); path.stroke()
            }
        }
    }
}

final class SemanticSignatureView: SemanticSuggestSurface {
    init(signature: LSPAssistance.Signature, width: CGFloat) {
        super.init(frame: .zero)
        let label = NSTextField(wrappingLabelWithString: "")
        let text = NSMutableAttributedString(string: signature.label, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: SemanticSuggestStyle.foreground])
        if let active = signature.active, NSMaxRange(active) <= text.length {
            text.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), .backgroundColor: SemanticSuggestStyle.selection.withAlphaComponent(0.35)], range: active)
        }
        label.attributedStringValue = text; label.maximumNumberOfLines = 4; label.isSelectable = false
        label.preferredMaxLayoutWidth = width - 20; label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: width), label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), label.topAnchor.constraint(equalTo: topAnchor, constant: 8), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)])
        setAccessibilityLabel("Function Parameters"); setAccessibilityHelp(signature.label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// One native replacement/Undo operation for an explicitly selected validated action.
enum SemanticActionApplication {
    @MainActor static func apply(_ edits: [LSPText.Edit], title: String, to view: EditorTextView) -> Bool {
        guard view.isEditable, !view.hasMarkedText(), view.selectedRanges.count == 1, view.insertionLocations.count <= 1, !edits.isEmpty else { return false }
        let original = view.selectedRange().location
        let normalized = edits.map { LSPText.Edit(range: $0.range, text: $0.text.replacingLineEndings(with: view.lineEnding), primary: $0.primary) }
        let caret = LSPAssistance.caret(after: normalized, original: original, textLength: (view.string as NSString).length)
        view.breakUndoCoalescing()
        let result = view.replace(with: normalized.map(\.text), ranges: normalized.map(\.range), selectedRanges: [NSRange(location: caret, length: 0)], actionName: title)
        view.breakUndoCoalescing()
        return result
    }
}
