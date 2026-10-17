// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import AppKit

struct SemanticGhostPreview {
    let text: String
    let snapshot: String
    let caret: Int
    let fileURL: URL?
    let language: LSPLanguage
    var copilot = false
    var languageId: String? = nil
    var parts: [CopilotInline.Part] = []
    var nextEdit = false
    var replacementRange: NSRange? = nil
    var replacedText: String? = nil
    var revision: Int? = nil
}

extension EditorTextView {
    var semanticGhostIsCurrent: Bool {
        guard let ghost = semanticGhost, string.utf16.elementsEqual(ghost.snapshot.utf16), ghost.revision == nil || ghost.revision == semanticRevision,
              selectedRange() == NSRange(location: ghost.caret, length: 0),
              selectedRanges.count == 1, insertionLocations.allSatisfy({ $0 == selectedRange().location }), !hasMarkedText(),
              isEditable, baseWritingDirection != .rightToLeft, layoutOrientation == .horizontal,
              window?.firstResponder === self, (NSApp.keyWindow ?? NSApp.mainWindow) === window, NSApp.isActive,
              let context = semanticDocumentContext?(), context.url == ghost.fileURL else { return false }
        let valid = ghost.copilot ? CopilotLanguage.resolve(url: context.url, syntax: context.syntax) == (ghost.languageId ?? ghost.language.rawValue) : CopilotLanguage.resolve(url: context.url, syntax: context.syntax) == ghost.language.rawValue
        return valid && (ghost.nextEdit || !semanticGhostRect.isEmpty)
    }
    private var nextEditIsInlineInsertion: Bool {
        semanticGhost?.nextEdit == true && semanticGhost?.replacementRange?.length == 0 && semanticGhost?.text.contains(where: { $0.isNewline }) == false
    }
    var hasVisibleCopilotGhost: Bool { semanticGhost?.copilot == true && semanticGhostIsCurrent }
    /// Ordinary completion may coexist with an edit preview, while a normal AI
    /// insertion still has exclusive ownership of its ghost text.
    var hasExclusiveCopilotInlineGhost: Bool { hasVisibleCopilotGhost && semanticGhost?.nextEdit != true }
    func updateSemanticGhostPresentation() {
        let layout = layoutManager as? LayoutManager
        if let ghost = semanticGhost, ghost.copilot, (!ghost.nextEdit || nextEditIsInlineInsertion), ghost.snapshot.utf16.elementsEqual(string.utf16) {
            let count = ghost.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").filter { $0 == "\n" }.count
            layout?.semanticGhostGap = .init(caret: ghost.nextEdit ? (ghost.replacementRange?.location ?? ghost.caret) : ghost.caret, lines: min(200, count))
        } else { layout?.semanticGhostGap = nil }
        if let layoutManager, let textContainer { layoutManager.ensureLayout(for: textContainer) }
        updateSemanticGhostPanel(); enclosingScrollView?.verticalRulerView?.needsDisplay = true; needsDisplay = true
    }
    func updateSemanticGhostPanel() {
        if let panel = semanticGhostPanel { panel.orderOut(nil); panel.parent?.removeChildWindow(panel); semanticGhostPanel = nil }
        guard semanticGhostIsCurrent, let ghost = semanticGhost, ghost.copilot, let window else { return }
        let lines = ghost.text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).count
        guard (ghost.nextEdit && !nextEditIsInlineInsertion && !ghost.text.isEmpty) || lines > 200 else { return }
        let available = window.screen?.visibleFrame ?? window.frame
        let multiline = ghost.nextEdit && ((ghost.replacedText ?? "").contains(where: { $0.isNewline }) || ghost.text.contains(where: { $0.isNewline }) || ghost.text.count > 60)
        let previewFont = font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let desired = multiline ? min(1000, visibleRect.width - 24) : (ghost.text as NSString).size(withAttributes: [.font: previewFont]).width + 56
        let width = min(ghost.nextEdit ? max(120, desired) : 600, max(100, visibleRect.width - 24), available.width - 20)
        guard width >= 100 else { return }
        let body: String
        if ghost.nextEdit {
            body = "↳ " + ghost.text
        } else { body = ghost.text }
        let surface = SemanticMultilinePreview(text: body, width: width, font: font ?? .monospacedSystemFont(ofSize: 13, weight: .regular))
        surface.setAccessibilityLabel(ghost.nextEdit ? "Copilot Next Edit Difference Preview" : "Copilot Full Suggestion Preview")
        if ghost.nextEdit {
            surface.previewText.textColor = .labelColor
            surface.previewText.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.18)
        }
        let difference = ghost.nextEdit && multiline ? SemanticNextEditPreview(before: ghost.replacedText ?? "", after: ghost.text, width: width, font: previewFont) : nil
        let height = min(difference?.fullHeight ?? surface.fullHeight, available.height * 0.5)
        let localAnchor = semanticGhostRect.isEmpty ? (nextEditNavigationRect ?? NSRect(x: visibleRect.minX + 24, y: visibleRect.minY, width: 1, height: 20)) : semanticGhostRect
        let anchor = window.convertToScreen(convert(localAnchor, to: nil))
        let x = min(max(anchor.minX, available.minX), available.maxX - width)
        let below = anchor.minY - height - 4
        let y = min(max(below >= available.minY ? below : anchor.maxY + 4, available.minY), available.maxY - height)
        let panel = SemanticCandidatePanel(contentRect: NSRect(x: x, y: y, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hasShadow = true; panel.hidesOnDeactivate = true; panel.isReleasedWhenClosed = false
        if let difference {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            scroll.documentView = difference; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            panel.contentView = scroll
        } else { panel.contentView = surface }
        panel.appearance = effectiveAppearance
        window.addChildWindow(panel, ordered: .above); semanticGhostPanel = panel; panel.orderFront(nil)
    }
    private var semanticGhostRect: NSRect {
        guard let ghost = semanticGhost, let window else { return .zero }
        var actual = NSRange(location: ghost.nextEdit ? (ghost.replacementRange?.location ?? ghost.caret) : ghost.caret, length: 0)
        let screenRect = firstRect(forCharacterRange: actual, actualRange: &actual)
        var caret = convert(window.convertFromScreen(screenRect), from: nil)
        caret.size.height = (layoutManager as? LayoutManager)?.lineHeight ?? caret.height
        let available = NSRect(x: caret.minX + 2, y: caret.minY, width: max(0, visibleRect.maxX - caret.minX - 4), height: caret.height)
        guard available.width >= 8, visibleRect.intersects(caret) else { return .zero }
        return available.intersection(visibleRect)
    }
    func semanticGhostAttributedContent() -> NSAttributedString? { ghostCanvas()?.0 }
    private func ghostCanvas() -> (NSAttributedString, [(NSRange, NSRange?, Int)])? {
        guard let ghost = semanticGhost, !ghost.nextEdit || nextEditIsInlineInsertion else { return nil }
        let anchor = ghost.nextEdit ? (ghost.replacementRange?.location ?? ghost.caret) : ghost.caret
        let source = string as NSString
        var start = 0, end = 0, contentsEnd = 0
        source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: anchor, length: 0))
        let parts = ghost.parts.isEmpty ? [CopilotInline.Part(offset: anchor, text: ghost.text)] : ghost.parts
        let result = NSMutableAttributedString(string: "")
        var maps: [(NSRange, NSRange?, Int)] = [], offset = anchor
        let font = font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        func appendSource(_ range: NSRange) {
            guard range.length > 0 else { return }
            let piece = textStorage?.attributedSubstring(from: range).mutableCopy() as? NSMutableAttributedString ?? NSMutableAttributedString(string: source.substring(with: range), attributes: [.font: font, .foregroundColor: textColor ?? .labelColor])
            if let diagnostics = semanticDiagnostics, diagnostics.snapshot == string {
                for diagnostic in diagnostics.items {
                    let intersection = NSIntersectionRange(diagnostic.range, range)
                    if intersection.length > 0 {
                        piece.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, .underlineColor: diagnostic.severity == 1 ? NSColor.systemRed : NSColor.systemOrange], range: NSRange(location: intersection.location - range.location, length: intersection.length))
                    }
                }
            }
            maps.append((NSRange(location: result.length, length: piece.length), range, range.location)); result.append(piece)
        }
        for part in parts {
            guard part.offset >= offset, part.offset <= contentsEnd else { return nil }
            appendSource(NSRange(location: offset, length: part.offset - offset))
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: SemanticGhostDrawing.color(background: backgroundColor)]
            if ghost.nextEdit { attributes[.foregroundColor] = textColor ?? .labelColor; attributes[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.25) }
            let piece = NSAttributedString(string: part.text, attributes: attributes)
            maps.append((NSRange(location: result.length, length: piece.length), nil, part.offset)); result.append(piece); offset = part.offset
        }
        appendSource(NSRange(location: offset, length: contentsEnd - offset))
        return (result, maps)
    }
    func drawSemanticGhost(in dirtyRect: NSRect) {
        guard semanticGhostIsCurrent, let ghost = semanticGhost else { return }
        if ghost.nextEdit { drawNextEditIndicator(in: dirtyRect) }
        guard !semanticGhostRect.isEmpty, let (canvas, _) = ghostCanvas() else { return }
        let caret = semanticGhostRect, height = (layoutManager as? LayoutManager)?.lineHeight ?? caret.height
        let text = canvas.string as NSString
        var offset = 0, row = 0
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        visibleRect.intersection(dirtyRect).clip()
        repeat {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: min(offset, text.length), length: 0))
            let x = row == 0 ? caret.minX : textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
            let rect = NSRect(x: x, y: caret.minY + CGFloat(row) * height, width: max(0, visibleRect.maxX - x), height: height)
            if rect.intersects(dirtyRect) {
                backgroundColor.setFill(); rect.fill()
                canvas.attributedSubstring(from: NSRange(location: start, length: contentsEnd - start)).draw(at: rect.origin)
            }
            offset = end; row += 1
        } while offset < text.length && row <= 200
    }
    var nextEditTargetIsVisible: Bool { !semanticGhostRect.isEmpty }
    private func drawNextEditIndicator(in dirtyRect: NSRect) {
        guard let ghost = semanticGhost, let range = ghost.replacementRange else { return }
        let anchor = semanticGhostRect
        if !nextEditUsesGutter, let indicator = nextEditNavigationRect {
            NSAttributedString(string: anchor.isEmpty ? "↪" : "➜", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: NSColor.systemBlue]).draw(in: indicator)
        }
        guard range.length > 0, let layoutManager, let textContainer else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        visibleRect.intersection(dirtyRect).clip()
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
            let rect = rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
            NSColor.systemRed.withAlphaComponent(0.22).setFill(); rect.fill(using: .sourceOver)
            if ghost.text.isEmpty {
                NSColor.systemRed.setStroke()
                let strike = NSBezierPath(); strike.move(to: NSPoint(x: rect.minX, y: rect.midY)); strike.line(to: NSPoint(x: rect.maxX, y: rect.midY)); strike.stroke()
            }
        }
    }
    var nextEditUsesGutter: Bool {
        guard let scroll = enclosingScrollView, let ruler = scroll.verticalRulerView else { return false }
        return scroll.rulersVisible && scroll.hasVerticalRuler && !ruler.isHidden
    }
    var nextEditNavigationRect: NSRect? {
        guard let ghost = semanticGhost, ghost.nextEdit, semanticGhostIsCurrent, let range = ghost.replacementRange else { return nil }
        guard let window else { return nil }
        var actual = NSRange(location: range.location, length: 0)
        let screen = firstRect(forCharacterRange: actual, actualRange: &actual)
        let target = convert(window.convertFromScreen(screen), from: nil)
        let height = max(16, (layoutManager as? LayoutManager)?.lineHeight ?? 18)
        let y = min(max(target.minY, visibleRect.minY), visibleRect.maxY - height)
        return NSRect(x: visibleRect.maxX - 20, y: y, width: 18, height: height)
    }
    func nextEditIndicatorHit(at point: NSPoint) -> Bool {
        !nextEditUsesGutter && nextEditNavigationRect?.contains(point) == true
    }
    /// Hit testing is mapped to original characters before removing a virtual preview gap.
    func semanticGhostMouseOffset(at point: NSPoint) -> Int? {
        guard let ghost = semanticGhost, ghost.copilot, !ghost.nextEdit, ghost.snapshot.utf16.elementsEqual(string.utf16),
              let (canvas, maps) = ghostCanvas() else { return nil }
        let caret = semanticGhostRect, height = (layoutManager as? LayoutManager)?.lineHeight ?? caret.height
        guard height > 0 else { return nil }
        let row = Int(floor((point.y - caret.minY) / height))
        if row < 0 || (row == 0 && point.x < caret.minX) || row > (layoutManager as? LayoutManager)?.semanticGhostGap?.lines ?? 0 {
            guard let layoutManager, let textContainer else { return nil }
            let glyph = layoutManager.glyphIndex(for: NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y), in: textContainer)
            return layoutManager.isValidGlyphIndex(glyph) ? layoutManager.characterIndexForGlyph(at: glyph) : string.utf16.count
        }
        let text = canvas.string as NSString
        var offset = 0, index = 0, lineRange = NSRange(location: 0, length: 0)
        while index <= row && offset <= text.length {
            var start = 0, end = 0, content = 0
            text.getLineStart(&start, end: &end, contentsEnd: &content, for: NSRange(location: offset, length: 0))
            lineRange = NSRange(location: start, length: content - start)
            if index == row { break }; offset = end; index += 1
        }
        let local = canvas.attributedSubstring(from: lineRange)
        let storage = NSTextStorage(attributedString: local), layout = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: 1_000_000, height: 1_000))
        container.lineFragmentPadding = 0; storage.addLayoutManager(layout); layout.addTextContainer(container); layout.ensureLayout(for: container)
        let x = row == 0 ? caret.minX : textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        let glyph = layout.glyphIndex(for: NSPoint(x: max(0, point.x - x), y: 1), in: container)
        let character = layout.isValidGlyphIndex(glyph) ? layout.characterIndexForGlyph(at: glyph) : local.length
        let display = lineRange.location + character
        for (range, original, anchor) in maps where display >= range.location && display <= NSMaxRange(range) {
            return original.map { min(NSMaxRange($0), $0.location + display - range.location) } ?? anchor
        }
        return ghost.caret
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

/// Full plain-text candidate, scrollable when it exceeds the screen. Never takes editor focus.
final class SemanticMultilinePreview: NSScrollView {
    let previewText: NSTextView
    let fullHeight: CGFloat
    init(text: String, width: CGFloat, font: NSFont) {
        let contentWidth = max(1, width - 32)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let measured = (text as NSString).boundingRect(with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        fullHeight = max(ceil(measured.height) + 20, 44)
        previewText = NSTextView(frame: NSRect(x: 0, y: 0, width: width - 16, height: fullHeight))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: fullHeight))
        previewText.string = text; previewText.font = font
        previewText.isEditable = false; previewText.isSelectable = false; previewText.isRichText = false
        previewText.textContainerInset = NSSize(width: 8, height: 8)
        previewText.textContainer?.lineFragmentPadding = 0
        previewText.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        previewText.textContainer?.widthTracksTextView = false
        previewText.backgroundColor = .textBackgroundColor; previewText.textColor = .secondaryLabelColor
        documentView = previewText; hasVerticalScroller = true; autohidesScrollers = true
        borderType = .lineBorder
        setAccessibilityLabel("Copilot Full Suggestion Preview")
        previewText.setAccessibilityLabel("Copilot Suggestion")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Recreated on every viewport resize, so wide edits fall back to stacked rows.
final class SemanticNextEditPreview: NSView {
    let fullHeight: CGFloat
    init(before: String, after: String, width: CGFloat, font: NSFont) {
        let sideBySide = width >= 740
        let columnWidth = sideBySide ? width / 2 : width
        let removed = SemanticMultilinePreview(text: "− " + before, width: columnWidth, font: font)
        let inserted = SemanticMultilinePreview(text: "+ " + after, width: columnWidth, font: font)
        for (view, color) in [(removed, NSColor.systemRed), (inserted, NSColor.systemGreen)] {
            view.previewText.textColor = .labelColor
            view.previewText.backgroundColor = color.withAlphaComponent(0.18)
        }
        fullHeight = sideBySide ? max(removed.fullHeight, inserted.fullHeight) : removed.fullHeight + inserted.fullHeight
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: fullHeight))
        removed.frame = NSRect(x: 0, y: sideBySide ? 0 : inserted.fullHeight, width: columnWidth, height: sideBySide ? fullHeight : removed.fullHeight)
        inserted.frame = NSRect(x: sideBySide ? columnWidth : 0, y: 0, width: columnWidth, height: sideBySide ? fullHeight : inserted.fullHeight)
        addSubview(removed); addSubview(inserted)
        setAccessibilityLabel(sideBySide ? "Copilot Next Edit Side by Side Difference" : "Copilot Next Edit Line Difference")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
