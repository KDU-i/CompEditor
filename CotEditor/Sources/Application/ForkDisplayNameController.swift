// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import AppKit

/// Updates app-owned labels without changing the running bundle or OS registration.
@MainActor final class ForkDisplayNameController {
    static let shared = ForkDisplayNameController()
    static let aboutIdentifier = NSUserInterfaceItemIdentifier("CompEditor.About")
    private let defaults: UserDefaults
    private var templates: [(NSMenuItem, String)] = []
    private weak var applicationMenu: NSMenu?
    private weak var applicationMenuItem: NSMenuItem?
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func install(menu: NSMenu?) {
        guard let root = menu?.items.first, let applicationMenu = root.submenu else { return }
        self.applicationMenu = applicationMenu
        self.applicationMenuItem = root
        // The fork has no donation/purchase route; preserve upstream code and attribution.
        applicationMenu.items.first { $0.action.map(NSStringFromSelector) == "showDonationWindow:" }?.isHidden = true
        self.templates = applicationMenu.items.filter {
            ["showAboutPanel:", "hide:", "terminate:"].contains($0.action.map(NSStringFromSelector) ?? "")
        }.map { ($0, $0.title) }
        if self.observer == nil {
            self.observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        self.refresh()
    }

    func refresh() {
        let name = ForkIdentity.displayName(defaults: self.defaults)
        self.applicationMenuItem?.title = name
        for (item, template) in self.templates {
            item.title = ForkIdentity.label(template, name: name)
        }
        self.applicationMenu?.title = name
        for window in NSApp.windows where window.identifier == Self.aboutIdentifier {
            window.title = String(localized: "About \(name)", table: "About", comment: "window title; %@ is app name")
        }
    }
}
