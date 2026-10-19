// SPDX-License-Identifier: Apache-2.0
import AppKit
import Testing
@testable import CotEditor

/// Native regressions: no mouse/key event or manual revalidation after the
/// asynchronous session transition. Run under the isolated QA app identity.
@MainActor @Suite(.serialized) struct RunToolbarValidationTests {
    @Test func asyncSessionTransitionsRefreshRunAndStopWithoutInteraction() async {
        let fixture = ToolbarFixture()
        defer { fixture.close() }
        #expect(fixture.run.isEnabled)
        #expect(!fixture.stop.isEnabled)
        await Task { @MainActor in
            fixture.document.runSession.active = true
            #expect(!fixture.run.isEnabled)
            #expect(fixture.stop.isEnabled)
            fixture.document.runSession.active = false
            #expect(fixture.run.isEnabled)
            #expect(!fixture.stop.isEnabled)
        }.value
    }

    @Test func toolbarValidationUsesItsDocumentBeforeMainWindowAndAcrossDocuments() {
        let first = ToolbarFixture(), second = ToolbarFixture()
        defer { second.close(); first.close() }
        // Neither setup requires making its window main. A singleton target
        // must not validate both toolbars against whichever window is main.
        #expect(RunActions.shared.validateToolbarItem(first.run))
        #expect(!RunActions.shared.validateToolbarItem(first.stop))
        second.document.runSession.active = true
        #expect(first.run.isEnabled)
        #expect(!first.stop.isEnabled)
        #expect(!second.run.isEnabled)
        #expect(second.stop.isEnabled)
        #expect(RunActions.shared.validateToolbarItem(first.run))
        #expect(!RunActions.shared.validateToolbarItem(second.run))
    }
}

@MainActor private final class ToolbarFixture: NSObject, NSToolbarDelegate {
    let document: Document
    let controller: DocumentWindowController
    let toolbar = NSToolbar(identifier: "RunToolbarRegression-" + UUID().uuidString)
    let runID = NSToolbarItem.Identifier("test.run")
    let stopID = NSToolbarItem.Identifier("test.stop")
    var run: NSToolbarItem { toolbar.items.first(where: { $0.itemIdentifier == runID })! }
    var stop: NSToolbarItem { toolbar.items.first(where: { $0.itemIdentifier == stopID })! }

    override init() {
        let document = Document()
        self.document = document
        controller = DocumentWindowController(document: document)
        super.init()
        document.addWindowController(controller)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        controller.window!.toolbar = toolbar
        toolbar.insertItem(withItemIdentifier: runID, at: 0)
        toolbar.insertItem(withItemIdentifier: stopID, at: 1)
        controller.window!.orderFront(nil)
        controller.window!.contentView?.layoutSubtreeIfNeeded()
        controller.window!.displayIfNeeded()
        toolbar.validateVisibleItems()  // Initial setup only, never after active changes.
    }
    func close() { document.runSession.active = false; document.close() }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [runID, stopID] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = runText(identifier == runID ? "Run" : "Stop")
        item.image = NSImage(systemSymbolName: identifier == runID ? "play.fill" : "stop.fill", accessibilityDescription: item.label)
        item.target = RunActions.shared
        item.action = identifier == runID ? #selector(RunActions.runSource(_:)) : #selector(RunActions.stopSource(_:))
        return item
    }
}
