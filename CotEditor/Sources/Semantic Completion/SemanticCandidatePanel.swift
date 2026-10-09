// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import AppKit

/// Native list overlay that never takes the editor's key focus or starts menu tracking.
final class SemanticCandidatePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Original layout using macOS symbols and semantic colors; no copied editor assets.
final class SemanticCandidateCell: NSTableCellView {
    // Explicit row coloring preserves VS Code-like selected foregrounds.
    override var backgroundStyle: NSView.BackgroundStyle {
        get { .light }
        set { }
    }
    private var normalTint: NSColor = .systemBlue
    private var detailField: NSTextField?
    override var objectValue: Any? { didSet { updateColors() } }
    func updateColors() {
        let selected = (superview as? NSTableRowView)?.isSelected == true
        textField?.textColor = selected ? SemanticSuggestStyle.selectedForeground : SemanticSuggestStyle.foreground
        detailField?.textColor = selected ? SemanticSuggestStyle.selectedForeground.withAlphaComponent(0.85) : SemanticSuggestStyle.foreground.withAlphaComponent(0.65)
        imageView?.contentTintColor = selected ? SemanticSuggestStyle.selectedForeground : normalTint
    }
    init(item: LSPJSON) {
        super.init(frame: .zero)
        let kind = item["kind"].int ?? 1
        let symbol: String
        let tint: NSColor
        switch kind {
            case 2, 3, 4: symbol = "function"; tint = .systemPurple
            case 5, 6, 10: symbol = "cube"; tint = .systemBlue
            case 7, 8, 22: symbol = "shippingbox"; tint = .systemOrange
            case 9: symbol = "square.stack.3d.up"; tint = .systemTeal
            case 14: symbol = "textformat.abc"; tint = .secondaryLabelColor
            default: symbol = "curlybraces"; tint = .systemBlue
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: "Completion kind \(kind)") ?? NSImage())
        icon.contentTintColor = tint
        let fullLabel = item["label"].string ?? "Completion"
        let filter = item["filterText"].string ?? ""
        let hasSignature = !filter.isEmpty && fullLabel.hasPrefix(filter + "(")
        let label = NSTextField(labelWithString: hasSignature ? filter : fullLabel)
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = SemanticSuggestStyle.foreground
        let detail = NSTextField(labelWithString: item["labelDetails"]["description"].string ?? (hasSignature ? String(fullLabel.dropFirst(filter.count)) : item["detail"].string?.components(separatedBy: .newlines).first ?? ""))
        detail.alignment = .right
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for child in [icon, label, detail] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), icon.widthAnchor.constraint(equalToConstant: 15), icon.heightAnchor.constraint(equalToConstant: 15), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4), label.centerYAnchor.constraint(equalTo: centerYAnchor), label.widthAnchor.constraint(lessThanOrEqualToConstant: 285),
            detail.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12), detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), detail.centerYAnchor.constraint(equalTo: centerYAnchor), detail.widthAnchor.constraint(lessThanOrEqualToConstant: 240)
        ])
        textField = label; imageView = icon; detailField = detail; normalTint = tint; updateColors()
        toolTip = item["detail"].string
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class SemanticCandidateRow: NSTableRowView {
    override var isSelected: Bool { didSet { for cell in subviews.compactMap({ $0 as? SemanticCandidateCell }) { cell.updateColors() } } }
    override func drawSelection(in dirtyRect: NSRect) {
        SemanticSuggestStyle.selection.setFill(); bounds.fill()
    }
}
