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
    var replacementHunks: [LSPText.Edit] = []
    var displayDiff = SemanticNextEditDisplayCache()
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
        guard let ghost = semanticGhost, ghost.nextEdit, ghost.replacementRange?.length == 0,
              !ghost.text.contains(where: { $0.isNewline }), let range = ghost.replacementRange,
              NSMaxRange(range) <= string.utf16.count else { return false }
        let anchor = semanticGhostRect
        guard !anchor.isEmpty else { return false }
        // The source suffix moves with an insertion. Keep it visible too; a long
        // single-line edit uses the wrapping preview instead of silently clipping.
        let source = string as NSString
        var end = 0
        source.getLineStart(nil, end: nil, contentsEnd: &end, for: range)
        let suffix = source.substring(with: NSRange(location: range.location, length: end - range.location))
        let width = ((ghost.text + suffix) as NSString).size(withAttributes: [.font: font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)]).width
        return width <= anchor.width
    }
    private func nextEditSurface(for ghost: SemanticGhostPreview) -> SemanticNextEditPreview {
        let previewFont = font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let height = (layoutManager as? LayoutManager)?.lineHeight ?? previewFont.boundingRectForFont.height
        return SemanticNextEditPreview(diff: ghost.displayDiff.prepare(before: ghost.replacedText ?? "", after: ghost.text),
            maximumWidth: max(32, visibleRect.width - 8), font: previewFont, lineHeight: height,
            baseline: (layoutManager as? LayoutManager)?.baselineOffset(for: .horizontal) ?? previewFont.ascender,
            foreground: textColor ?? .labelColor, background: backgroundColor)
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
        } else if let ghost = semanticGhost, ghost.nextEdit, !ghost.text.isEmpty, LSPText.sameText(ghost.snapshot, string), let range = ghost.replacementRange {
            // Reserve only the preview's exact height. It never obscures the next
            // source line or changes the document/Undo history.
            let surface = nextEditSurface(for: ghost)
            layout?.semanticGhostGap = .init(caret: max(range.location, NSMaxRange(range) - 1), lines: 0, extraHeight: min(surface.fullHeight, visibleRect.height * 0.6, (window?.screen?.visibleFrame.height ?? visibleRect.height) * 0.5) + 2)
        } else { layout?.semanticGhostGap = nil }
        if let layoutManager, let textContainer { layoutManager.ensureLayout(for: textContainer) }
        updateSemanticGhostPanel(); enclosingScrollView?.verticalRulerView?.needsDisplay = true; needsDisplay = true
    }
    func updateSemanticGhostPanel() {
        guard semanticGhostIsCurrent, let ghost = semanticGhost, ghost.copilot, let window else {
            dismissSemanticGhostPanel(); return
        }
        let lines = ghost.text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).count
        guard (ghost.nextEdit && !nextEditIsInlineInsertion && !ghost.text.isEmpty) || lines > 200 else {
            dismissSemanticGhostPanel(); return
        }
        let available = window.screen?.visibleFrame ?? window.frame
        if ghost.nextEdit {
            let surface = nextEditSurface(for: ghost)
            let width = surface.frame.width
            let height = min(surface.fullHeight, visibleRect.height * 0.6, available.height * 0.5)
            var range = NSRange(location: max(ghost.replacementRange?.location ?? 0, NSMaxRange(ghost.replacementRange ?? .init()) - 1), length: 0)
            let lastRect = firstRect(forCharacterRange: range, actualRange: &range)
            let target = convert(window.convertFromScreen(lastRect), from: nil)
            let first = semanticGhostRect
            let viewport = window.convertToScreen(convert(visibleRect, to: nil))
            let local = NSRect(x: first.isEmpty ? visibleRect.minX + 2 : first.minX - 2,
                               y: min(max(target.minY + ((layoutManager as? LayoutManager)?.lineHeight ?? target.height) + 1, visibleRect.minY), visibleRect.maxY - height), width: width, height: height)
            let screen = window.convertToScreen(convert(local, to: nil))
            let x = min(max(screen.minX, viewport.minX + 1), viewport.maxX - width - 1)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            scroll.drawsBackground = false; scroll.documentView = surface
            scroll.hasVerticalScroller = surface.fullHeight > height; scroll.autohidesScrollers = true
            presentSemanticGhostPanel(scroll, frame: NSRect(x: x, y: screen.minY, width: width, height: height), nextEdit: true, in: window)
            return
        }
        let width = min(600, max(100, visibleRect.width - 24), available.width - 20)
        let surface = SemanticMultilinePreview(text: ghost.text, width: width, font: font ?? .monospacedSystemFont(ofSize: 13, weight: .regular))
        let height = min(surface.fullHeight, available.height * 0.5)
        let anchor = window.convertToScreen(convert(semanticGhostRect, to: nil))
        let x = min(max(anchor.minX, available.minX), available.maxX - width)
        let y = min(max(anchor.minY - height - 4, available.minY), available.maxY - height)
        presentSemanticGhostPanel(surface, frame: NSRect(x: x, y: y, width: width, height: height), nextEdit: false, in: window)
    }
    private func dismissSemanticGhostPanel() {
        guard let panel = semanticGhostPanel else { return }
        semanticGhostPanel = nil
        panel.parent?.removeChildWindow(panel)
        panel.close()
    }
    private func presentSemanticGhostPanel(_ content: NSView, frame: NSRect, nextEdit: Bool, in window: NSWindow) {
        // Reposition an existing preview instead of creating another native
        // window on every caret/viewport callback. Avoid redundant ordering and
        // frame requests that leave obsolete WindowServer geometry events.
        let panel = semanticGhostPanel ?? SemanticCandidatePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hasShadow = !nextEdit; panel.hidesOnDeactivate = true; panel.isReleasedWhenClosed = false
        panel.isOpaque = !nextEdit; panel.backgroundColor = nextEdit ? .clear : .windowBackgroundColor; panel.appearance = effectiveAppearance
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        panel.contentView = content
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        semanticGhostPanel = panel
        if !panel.isVisible { panel.orderFront(nil) }
    }
    private var semanticGhostRect: NSRect {
        guard let ghost = semanticGhost, let window else { return .zero }
        var actual = NSRange(location: ghost.nextEdit ? (ghost.replacementRange?.location ?? ghost.caret) : ghost.caret, length: 0)
        let screenRect = firstRect(forCharacterRange: actual, actualRange: &actual)
        var caret = convert(window.convertFromScreen(screenRect), from: nil)
        caret.size.height = (layoutManager as? LayoutManager)?.lineHeight ?? caret.height
        let available = NSRect(x: caret.minX, y: caret.minY, width: max(0, visibleRect.maxX - caret.minX - 4), height: caret.height)
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
            if let diagnostics = semanticDiagnostics, LSPText.sameText(diagnostics.snapshot, string) {
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
            if ghost.nextEdit { attributes[.foregroundColor] = textColor ?? .labelColor; attributes[.backgroundColor] = SemanticNextEditPreview.insertedColor(background: backgroundColor) }
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
                let line = canvas.attributedSubstring(from: NSRange(location: start, length: contentsEnd - start))
                if ghost.nextEdit {
                    let storage = NSTextStorage(attributedString: line)
                    let previewLayout = SemanticPreviewLayoutManager(lineHeight: height, baseline: (layoutManager as? LayoutManager)?.baselineOffset(for: .horizontal) ?? font?.ascender ?? height)
                    let container = NSTextContainer(size: NSSize(width: max(1, rect.width), height: height))
                    container.lineFragmentPadding = 0; container.maximumNumberOfLines = 1
                    storage.addLayoutManager(previewLayout); previewLayout.addTextContainer(container)
                    let glyphs = previewLayout.glyphRange(for: container)
                    previewLayout.drawBackground(forGlyphRange: glyphs, at: rect.origin)
                    previewLayout.drawGlyphs(forGlyphRange: glyphs, at: rect.origin)
                } else { line.draw(at: rect.origin) }
            }
            offset = end; row += 1
        } while offset < text.length && row <= 200
    }
    var nextEditTargetIsVisible: Bool { !semanticGhostRect.isEmpty }
    private func drawNextEditIndicator(in dirtyRect: NSRect) {
        guard let ghost = semanticGhost, let range = ghost.replacementRange else { return }
        let anchor = semanticGhostRect
        if !nextEditUsesGutter, let indicator = nextEditNavigationRect {
            SemanticNextEditPreview.drawArrow(in: indicator, offscreen: anchor.isEmpty)
        }
        guard range.length > 0, let layoutManager, let textContainer else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        visibleRect.intersection(dirtyRect).clip()
        for changed in ghost.replacementHunks.isEmpty ? [range] : ghost.replacementHunks.map(\.range) where changed.length > 0 {
          let glyphs = layoutManager.glyphRange(forCharacterRange: changed, actualCharacterRange: nil)
          layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
            let rect = rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
            SemanticNextEditPreview.removedColor(background: self.backgroundColor).setFill(); rect.fill(using: .sourceOver)
            if ghost.text.isEmpty {
                NSColor.systemRed.setStroke()
                let strike = NSBezierPath(); strike.move(to: NSPoint(x: rect.minX, y: rect.midY)); strike.line(to: NSPoint(x: rect.maxX, y: rect.midY)); strike.stroke()
            }
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

/// Compact code surfaces, using the editor font and line height. No headings or
/// diff prefixes: the red original range already locates the edit in its context.
final class SemanticNextEditPreview: NSView {
    let fullHeight: CGFloat
    override var isFlipped: Bool { true }
    static func insertedColor(background: NSColor) -> NSColor { NSColor.systemGreen.withAlphaComponent(0.16) }
    static func removedColor(background: NSColor) -> NSColor { NSColor.systemRed.withAlphaComponent(0.18) }
    static func drawArrow(in rect: NSRect, offscreen: Bool = false) {
        let size: CGFloat = min(15, rect.height - 2)
        let box = NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        NSColor.systemBlue.withAlphaComponent(offscreen ? 0.65 : 0.9).setFill(); path.fill()
        let arrow = NSBezierPath(); arrow.lineWidth = 1.1; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
        arrow.move(to: .init(x: box.minX + 3, y: box.midY)); arrow.line(to: .init(x: box.maxX - 3, y: box.midY))
        arrow.move(to: .init(x: box.midX, y: box.midY - 3)); arrow.line(to: .init(x: box.maxX - 3, y: box.midY)); arrow.line(to: .init(x: box.midX, y: box.midY + 3))
        NSColor.white.setStroke(); arrow.stroke()
    }
    init(diff: SemanticNextEditDisplayData, maximumWidth: CGFloat, font: NSFont, lineHeight: CGFloat, baseline: CGFloat, foreground: NSColor, background: NSColor) {
        let before = diff.before, after = diff.after
        let multiline = before.contains(where: { $0.isNewline }) || after.contains(where: { $0.isNewline })
        let naturalWidth = max((before as NSString).size(withAttributes: [.font: font]).width, (after as NSString).size(withAttributes: [.font: font]).width)
        let sideBySide = multiline && !before.isEmpty && maximumWidth >= 740
        let width = min(maximumWidth, max(24, naturalWidth + 24) * (sideBySide ? 2 : 1))
        let column = sideBySide ? width / 2 : width
        let inserted = SemanticNextEditBlock(text: after, width: column, font: font, lineHeight: lineHeight, baseline: baseline, foreground: foreground, background: background, tint: Self.insertedColor(background: background), connector: !multiline, tintRanges: diff.insertedRanges.count > 1 ? diff.insertedRanges : nil)
        let removed = multiline && !before.isEmpty ? SemanticNextEditBlock(text: before, width: column, font: font, lineHeight: lineHeight, baseline: baseline, foreground: foreground, background: background, tint: Self.removedColor(background: background), connector: false, tintRanges: diff.removedRanges.count > 1 ? diff.removedRanges : nil) : nil
        fullHeight = sideBySide ? max(removed?.frame.height ?? 0, inserted.frame.height) : (removed?.frame.height ?? 0) + inserted.frame.height
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: fullHeight))
        if let removed { removed.frame.origin = .zero; addSubview(removed) }
        inserted.frame.origin = NSPoint(x: sideBySide ? column : 0, y: sideBySide ? 0 : removed?.frame.height ?? 0)
        addSubview(inserted)
        setAccessibilityLabel(sideBySide ? "Copilot Next Edit Side by Side Difference" : "Copilot Next Edit Difference Preview")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class SemanticNextEditBlock: NSView {
    override var isFlipped: Bool { true }
    let fill: NSColor
    let tint: NSColor
    let connector: Bool
    init(text: String, width: CGFloat, font: NSFont, lineHeight: CGFloat, baseline: CGFloat, foreground: NSColor, background: NSColor, tint: NSColor, connector: Bool, tintRanges: [NSRange]? = nil) {
        self.fill = background; self.tint = tintRanges == nil ? tint : .clear; self.connector = connector
        let leading: CGFloat = connector ? 18 : 4
        let contentWidth = max(1, width - leading - 4)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight; paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byCharWrapping
        let storage = NSTextStorage(string: text, attributes: [.font: font, .foregroundColor: foreground, .paragraphStyle: paragraph])
        for range in tintRanges ?? [] where range.length > 0 { storage.addAttribute(.backgroundColor, value: tint, range: range) }
        let layout = SemanticPreviewLayoutManager(lineHeight: lineHeight, baseline: baseline), container = NSTextContainer(size: NSSize(width: contentWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout); layout.addTextContainer(container); layout.ensureLayout(for: container)
        let height = max(lineHeight, ceil(layout.usedRect(for: container).height)) + 4
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let view = NSTextView(frame: NSRect(x: leading, y: 2, width: contentWidth, height: height - 4), textContainer: container)
        view.isEditable = false; view.isSelectable = false; view.drawsBackground = false; view.textContainerInset = .zero
        view.setAccessibilityLabel("Copilot Suggested Code")
        addSubview(view)
    }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill(); bounds.fill(); tint.setFill(); bounds.fill(using: .sourceOver)
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        border.lineWidth = 1; border.stroke()
        if connector {
            NSAttributedString(string: "↳", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]).draw(at: NSPoint(x: 3, y: (bounds.height - 15) / 2))
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Reuse the source editor's exact baseline as well as its line height. AppKit's
/// default text metrics otherwise put an inline preview above the adjacent code.
private final class SemanticPreviewLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    let previewLineHeight: CGFloat
    let previewBaseline: CGFloat
    init(lineHeight: CGFloat, baseline: CGFloat) {
        previewLineHeight = lineHeight; previewBaseline = baseline
        super.init(); delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>, lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>, in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        lineFragmentRect.pointee.size.height = previewLineHeight
        lineFragmentUsedRect.pointee.size.height = previewLineHeight
        baselineOffset.pointee = previewBaseline
        return true
    }
}
