// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import AppKit

/// Noninteractive, plain-text tooltip: no URL attributes, HTML or remote resources.
final class SemanticHoverView: SemanticSuggestSurface {
    init(text: String, width: CGFloat) {
        super.init(frame: .zero)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = SemanticSuggestStyle.foreground
        label.isSelectable = false
        label.maximumNumberOfLines = 12
        label.preferredMaxLayoutWidth = width - 20
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            widthAnchor.constraint(equalToConstant: width)
        ])
        setAccessibilityLabel("Semantic Hover Information")
        setAccessibilityHelp(text)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension EditorTextView {
    /// Glyph hit testing avoids hovering nearest text while the pointer is on whitespace.
    func semanticHoverTarget(at pointInWindow: NSPoint) -> (symbol: NSRange, rect: NSRect)? {
        let point = convert(pointInWindow, from: nil)
        guard visibleRect.contains(point), let layoutManager, let textContainer else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        guard glyph != NSNotFound, layoutManager.isValidGlyphIndex(glyph) else { return nil }
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        guard glyphRect.contains(point) else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard let symbol = LSPHoverPresentation.symbol(in: string, at: character) else { return nil }
        let range = layoutManager.glyphRange(forCharacterRange: symbol, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: range, in: textContainer).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return (symbol, rect)
    }
}
