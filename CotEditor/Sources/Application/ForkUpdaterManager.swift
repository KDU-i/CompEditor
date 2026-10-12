// Modified for the unofficial CompEditor fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import AppKit
import Sparkle

/// Sparkle owns download, signature verification, cancellation, installation and retry UI.
@MainActor final class ForkUpdaterManager: NSObject, SPUUpdaterDelegate, NSMenuItemValidation {
    static let shared = ForkUpdaterManager()
    private var controller: SPUStandardUpdaterController?
    private var policy: ForkUpdatePolicy?
    private var pendingInstall: (() -> Void)?
    private(set) var started = false
    var configurationDescription: String {
        return policy == nil ? "CompEditorの更新配信先が未設定です。署名付き更新の公開準備後に利用できます。" : "手動で確認します。更新先へIPとアプリ・Sparkleのバージョン等が送信されます。システムプロファイルや文書内容は送信しません。"
    }
    private var hasUnsavedDocuments: Bool { NSDocumentController.shared.documents.contains(where: \.isDocumentEdited) }
    func setup() {
        policy = try? ForkUpdatePolicy(info: Bundle.main.infoDictionary ?? [:], identifier: Bundle.main.bundleIdentifier)
        guard let menu = NSApp.mainMenu?.item(at: 0)?.submenu, !menu.items.contains(where: { $0.identifier?.rawValue == "CompEditorCheckForUpdates" }) else { return }
        let item = NSMenuItem(title: "アップデートを確認…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("CompEditorCheckForUpdates")
        item.target = self; menu.insertItem(item, at: 1)
    }
    @objc func checkForUpdates(_ sender: Any?) {
        if let pendingInstall {
            guard ForkUpdatePolicy.canInstall(hasUnsavedDocuments: hasUnsavedDocuments) else { showUnsaved(); return }
            self.pendingInstall = nil; pendingInstall(); return
        }
        guard policy != nil else { showMessage("更新を開始できません", configurationDescription); return }
        do {
            if controller == nil {
                let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
                controller.updater.clearFeedURLFromUserDefaults()
                controller.updater.automaticallyChecksForUpdates = false
                controller.updater.automaticallyDownloadsUpdates = false
                controller.updater.sendsSystemProfile = false
                try controller.updater.start()
                self.controller = controller; started = true
            }
            guard let updater = controller?.updater, updater.canCheckForUpdates else { return }
            updater.checkForUpdates()
        } catch { controller = nil; started = false; showMessage("更新を開始できません", "署名設定または更新機構を確認してください。現行版は変更されていません。再度確認できます。") }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { pendingInstall != nil || controller?.updater.canCheckForUpdates != false }
    func feedURLString(for updater: SPUUpdater) -> String? { policy?.feed.absoluteString }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard policy != nil, let url = item.fileURL, ForkUpdatePolicy.allowedArchive(url), !item.isInformationOnlyUpdate, item.installationType == "application" else {
            throw NSError(domain: "CompEditorUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "CompEditorの承認済み署名付き配布先ではありません。現行版を維持します。"])
        }
        guard ForkUpdatePolicy.canInstall(hasUnsavedDocuments: hasUnsavedDocuments) else {
            throw NSError(domain: "CompEditorUpdate", code: 2, userInfo: [NSLocalizedDescriptionKey: "未保存の文書を保存または閉じてから、もう一度更新を確認してください。"])
        }
    }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard !ForkUpdatePolicy.canInstall(hasUnsavedDocuments: hasUnsavedDocuments) else { return false }
        pendingInstall = installHandler; showUnsaved(); return true
    }
    private func showUnsaved() { showMessage("更新を保留しました", "未保存の文書を保存または閉じてから「アップデートを確認」を押すと再開します。文書と現行アプリは保持されています。") }
    private func showMessage(_ title: String, _ text: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.addButton(withTitle: "OK"); alert.runModal()
    }
}
