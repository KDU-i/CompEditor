// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
// CompEditor is an unofficial CotEditor fork. Original attribution is retained.
import Foundation

enum ForkIdentity {
    static let standardName = "CompEditor"
    static let legacyDisplayNameKey = "compEditorUsesCotEditorDisplayName"
    static let supportURL = URL(string: "https://github.com/KDU-i/CompEditor")!

    static func displayName(defaults: UserDefaults = .standard) -> String {
        self.displayName(useCotEditor: defaults.bool(forKey: self.legacyDisplayNameKey))
    }

    static func displayName(useCotEditor: Bool) -> String {
        useCotEditor ? "CotEditor" : self.standardName
    }

    /// Change labels only; never use this name for bundle URLs, settings or documents.
    static func label(_ template: String, name: String) -> String {
        template.replacingOccurrences(of: "CompEditor", with: "{fork-app-name}")
            .replacingOccurrences(of: "CotEditor", with: "{fork-app-name}")
            .replacingOccurrences(of: "{fork-app-name}", with: name)
    }
}
