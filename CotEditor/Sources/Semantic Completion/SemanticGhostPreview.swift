// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import AppKit

struct SemanticGhostPreview {
    let text: String
    let snapshot: String
    let caret: Int
    let fileURL: URL?
    let language: LSPLanguage
}

extension EditorTextView {
    var semanticGhostIsCurrent: Bool {
        guard let ghost = semanticGhost, string == ghost.snapshot,
              selectedRange() == NSRange(location: ghost.caret, length: 0),
              selectedRanges.count == 1, insertionLocations.count <= 1, !hasMarkedText(),
              isEditable, baseWritingDirection != .rightToLeft, layoutOrientation == .horizontal, window?.firstResponder === self,
              (NSApp.keyWindow ?? NSApp.mainWindow) === window, NSApp.isActive,
              let context = semanticDocumentContext?(), context.url == ghost.fileURL else { return false }
        let language = context.url.map { $0.pathExtension.lowercased() == ghost.language.fileExtension } ?? (context.syntax.caseInsensitiveCompare(ghost.language.rawValue) == .orderedSame)
        return language && !semanticGhostRect.isEmpty
    }
    private var semanticGhostRect: NSRect {
        guard let ghost = semanticGhost, let window else { return .zero }
        var actual = NSRange(location: ghost.caret, length: 0)
        let screenRect = firstRect(forCharacterRange: actual, actualRange: &actual)
        let caret = convert(window.convertFromScreen(screenRect), from: nil)
        let available = NSRect(x: caret.minX + 2, y: caret.minY, width: max(0, visibleRect.maxX - caret.minX - 4), height: caret.height)
        guard available.width >= 8, visibleRect.intersects(caret) else { return .zero }
        return available.intersection(visibleRect)
    }
    func drawSemanticGhost(in dirtyRect: NSRect) {
        guard semanticGhostIsCurrent, let ghost = semanticGhost else { return }
        let rect = semanticGhostRect
        guard rect.intersects(dirtyRect) else { return }
        SemanticGhostDrawing.draw(text: ghost.text, in: rect, font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), background: backgroundColor, dirtyRect: dirtyRect)
    }
}

enum SemanticGhostDrawing {
    static func color(background: NSColor) -> NSColor {
        let rgb = background.usingColorSpace(.deviceRGB) ?? .white
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        func contrast(_ gray: CGFloat) -> CGFloat {
            let grayLuminance = linear(gray)
            return (max(grayLuminance, luminance) + 0.05) / (min(grayLuminance, luminance) + 0.05)
        }
        let preferred: CGFloat = luminance < 0.18 ? 0.68 : 0.40
        let gray = contrast(preferred) >= 3 ? preferred : (contrast(0.15) > contrast(0.85) ? 0.15 : 0.85)
        return NSColor(calibratedWhite: gray, alpha: 1)
    }
    static func draw(text: String, in rect: NSRect, font: NSFont, background: NSColor, dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byClipping
        // Neutral gray with a stronger fallback for custom midtone backgrounds.
        let color = color(background: background)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        NSGraphicsContext.saveGraphicsState()
        rect.intersection(dirtyRect).clip()
        NSAttributedString(string: text, attributes: attributes).draw(at: rect.origin)
        NSGraphicsContext.restoreGraphicsState()
    }
}
