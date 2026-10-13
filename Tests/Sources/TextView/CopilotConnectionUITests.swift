// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI
import Testing
@testable import CotEditor

@MainActor struct CopilotConnectionUITests {
    private func state(_ phase: CopilotConnectionPhase, enabled: Bool = true, consented: Bool = false,
                       remembered: Bool = false, server: Bool = true, auth: Bool = false,
                       reconnect: Bool = false) -> CopilotConnectionPresentation {
        .init(phase: phase, detail: "保存済みのGitHub認証は変更していません。", enabled: enabled,
              consented: consented, remembersConsent: remembered, serverAvailable: server,
              authenticating: auth, reconnecting: reconnect)
    }

    @Test func offStopsSendingEvenWithRememberedConsent() {
        let value = state(.off, enabled: false, consented: true, remembered: true)
        #expect(!value.suggestionsEnabled && !value.canCheck && !value.canAuthenticate)
        #expect(value.consentTitle == "停止中")
        #expect(value.consentExplanation.contains("文書は送信しません"))
    }

    @Test func authenticatedStatusDoesNotImplyContextConsent() {
        let value = state(.authenticated)
        #expect(value.title == "GitHubに接続済み")
        #expect(!value.suggestionsEnabled && value.consentTitle == "未同意")
        #expect(value.canCheck && value.canAuthenticate)
        let session = state(.authenticated, consented: true)
        #expect(session.consentExplanation.contains("次回起動時は送信への同意を確認"))
        let remembered = state(.authenticated, consented: true, remembered: true)
        #expect(remembered.suggestionsEnabled && remembered.consentTitle == "このMacで同意を記憶")
    }

    @Test func busyActionsAndMissingServerAreTruthful() {
        let signingIn = state(.connecting, auth: true)
        #expect(signingIn.busy && signingIn.canCancel && !signingIn.canCheck && !signingIn.canAuthenticate)
        let checking = state(.connecting, reconnect: true)
        #expect(checking.busy && !checking.canCancel && !checking.canCheck)
        let missing = state(.signInRequired, server: false)
        #expect(missing.title == "言語サーバーが見つかりません")
        #expect(!missing.canCheck && !missing.canAuthenticate)
        for phase in [CopilotConnectionPhase.failed, .timedOut] {
            let retry = state(phase)
            #expect(retry.canCheck && retry.canAuthenticate)
            #expect(!retry.title.contains("サインインが必要"))
        }
    }

    @Test func consentWithoutServerAndServerSelectionWhileOffRefreshImmediately() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let controller = CopilotCompletionController(defaults: defaults)
        controller.acceptContextConsent(remember: true)
        #expect(controller.connectionPresentation.suggestionsEnabled)
        #expect(controller.connectionPresentation.remembersConsent)
        #expect(!controller.connectionPresentation.serverAvailable)

        let offDefaults = UserDefaults(suiteName: UUID().uuidString)!
        let preferences = CopilotSessionPreferences(defaults: offDefaults)
        preferences.enabled = false
        let off = CopilotCompletionController(defaults: offDefaults)
        #expect(!off.connectionPresentation.enabled)
        off.useServer(URL(fileURLWithPath: "/tmp/synthetic-copilot-language-server"))
        #expect(off.connectionPresentation.serverAvailable)
        #expect(!off.connectionPresentation.enabled)
        #expect(!off.connectionPresentation.suggestionsEnabled)
    }

    @Test func nativeStatusLayoutFitsLightAndDarkWithoutChangingConsent() {
        let model = CopilotConnectionUIModel()
        model.presentation = state(.timedOut)
        model.presentation.detail = "応答が時間内に届きませんでした。保存済み認証は変更していません。「接続を確認」で再試行できます。"
        let original = model.presentation
        let root = CopilotConnectionView(model: model, toggle: {}, check: {}, signIn: {}, signOut: {},
                                        cancel: {}, chooseServer: {}, close: {})
        let host = NSHostingView(rootView: root)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: name)
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            #expect(size.width == 480 && size.height >= 200 && size.height <= 420)
            #expect(model.presentation == original)
        }
    }
}
