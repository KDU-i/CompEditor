// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
// Native AppKit/model checks in a fresh, explicitly named test preferences suite.
import AppKit

@main struct ForkIdentityHarness {
    @MainActor static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, arguments[2].hasPrefix("dev.local.CompEditorIdentityTest.") else {
            fatalError("mode, fresh test suite and built app path required")
        }
        let mode = arguments[1], suite = arguments[2]
        let defaults = UserDefaults(suiteName: suite)!
        let bundle = Bundle(url: URL(fileURLWithPath: arguments[3]))!
        let infoURL = bundle.bundleURL.appendingPathComponent("Contents/Info.plist")
        let before = try Data(contentsOf: infoURL)
        precondition(bundle.bundleIdentifier == "dev.local.SemanticEditor")
        precondition(bundle.object(forInfoDictionaryKey: "CFBundleName") as? String == "CompEditor")
        if mode == "cleanup" {
            defaults.removePersistentDomain(forName: suite)
            precondition(defaults.synchronize())
            print("PASS: isolated suite removed")
            return
        }
        if mode == "seed" {
            precondition(defaults.persistentDomain(forName: suite) == nil, "existing suite is protected")
            precondition(ForkIdentity.displayName(defaults: defaults) == "CompEditor")
            defaults.set("document-and-semantic-settings-sentinel", forKey: "unchangedData")
            defaults.set(true, forKey: ForkIdentity.legacyDisplayNameKey)
            precondition(defaults.synchronize())
            print("PASS: default CompEditor; CotEditor preference saved in isolated suite")
            return
        }
        precondition(defaults.string(forKey: "unchangedData") == "document-and-semantic-settings-sentinel")
        let expected = mode == "legacy" ? "CotEditor" : "CompEditor"
        precondition(ForkIdentity.displayName(defaults: defaults) == expected, "preference must survive a separate process")
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let mainMenu = NSMenu()
        let root = NSMenuItem(title: "CotEditor", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "CotEditor")
        root.submenu = applicationMenu; mainMenu.addItem(root)
        for (title, action) in [("CotEditorについて", "showAboutPanel:"), ("CotEditorを隠す", "hide:"), ("CotEditorを終了", "terminate:")] {
            applicationMenu.addItem(NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: ""))
        }
        let unrelated = NSMenuItem(title: "An unrelated command", action: NSSelectorFromString("other:"), keyEquivalent: "")
        applicationMenu.addItem(unrelated)
        app.mainMenu = mainMenu
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        panel.identifier = ForkDisplayNameController.aboutIdentifier
        let controller = ForkDisplayNameController(defaults: defaults)
        controller.install(menu: mainMenu)
        precondition(root.title == expected && applicationMenu.items[0].title.contains(expected))
        precondition(panel.title.contains(expected))
        defaults.set(!defaults.bool(forKey: ForkIdentity.legacyDisplayNameKey), forKey: ForkIdentity.legacyDisplayNameKey)
        controller.refresh()
        let other = expected == "CotEditor" ? "CompEditor" : "CotEditor"
        precondition(root.title == other && applicationMenu.items[1].title.contains(other))
        precondition(panel.title.contains(other))
        precondition(unrelated.title == "An unrelated command")
        precondition(defaults.string(forKey: "unchangedData") == "document-and-semantic-settings-sentinel")
        let after = try Data(contentsOf: infoURL)
        precondition(after == before, "display changes must never mutate bundle metadata")
        precondition(defaults.synchronize())
        print("PASS: separate-process preference \(expected); live native menu/About roundtrip; stable bundle/data")
    }
}
