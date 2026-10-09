// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: MIT
// Copyright (c) Microsoft Corporation. All rights reserved.
// Adapted theme defaults/metrics from microsoft/vscode at
// 651237c307271b300329a7039913da7e5676afa5 (suggestWidget.ts, suggest.css,
// colors/editorColors.ts, colors/listColors.ts, colors/quickpickColors.ts).
// Native AppKit port: see RuntimeNotices/VSCode-MIT-LICENSE.txt.
import AppKit

enum SemanticSuggestStyle {
    static let width: CGFloat = 430
    static let rowHeight: CGFloat = 22  // Compact native row height.
    static let background = adaptive(light: 0xF3F3F3, dark: 0x252526)
    static let foreground = adaptive(light: 0x333333, dark: 0xBBBBBB)
    static let selection = adaptive(light: 0x0060C0, dark: 0x04395E)
    static let selectedForeground = NSColor.white
    static let border = foreground.withAlphaComponent(0.2)
    static func adaptive(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}

class SemanticSuggestSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        SemanticSuggestStyle.background.setFill(); bounds.fill()
        SemanticSuggestStyle.border.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}
