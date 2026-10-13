// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

/// Presentation only. Authentication and context consent remain in the controller.
struct CopilotConnectionPresentation: Equatable {
    var phase: CopilotConnectionPhase
    var detail: String
    var enabled: Bool
    var consented: Bool
    var remembersConsent: Bool
    var serverAvailable: Bool
    var authenticating: Bool
    var reconnecting: Bool

    var title: String {
        if !serverAvailable, phase != .off { return "言語サーバーが見つかりません" }
        return switch phase {
            case .off: "AI補完はオフです"
            case .connecting: "接続を確認しています…"
            case .authenticated: "GitHubに接続済み"
            case .signInRequired: "GitHubへのサインインが必要です"
            case .failed: "接続を確認できませんでした"
            case .timedOut: "接続の確認がタイムアウトしました"
        }
    }
    var busy: Bool { phase == .connecting || authenticating || reconnecting }
    var canCheck: Bool { enabled && serverAvailable && !busy }
    var canAuthenticate: Bool { enabled && serverAvailable && !busy }
    var canCancel: Bool { authenticating }
    var suggestionsEnabled: Bool { enabled && consented }
    var consentTitle: String {
        if !enabled { return "停止中" }
        if !consented { return "未同意" }
        return remembersConsent ? "このMacで同意を記憶" : "この起動中のみ同意済み"
    }
    var consentExplanation: String {
        if !enabled { return "文書は送信しません。保存済みのGitHub認証は保持されます。" }
        if !consented { return "有効にする前に、文書と周辺コードの送信への同意を確認します。" }
        if remembersConsent { return "次回起動時もAI補完が有効になります。オフにすると文書の同期が停止します。" }
        return "次回起動時は送信への同意を確認します。オフにすると文書の同期が停止します。"
    }
    var statusImage: StatusImage.Status {
        if !serverAvailable, phase != .off { return .unavailable }
        return switch phase {
            case .off, .connecting: .none
            case .authenticated: .available
            case .signInRequired: .partiallyAvailable
            case .failed, .timedOut: .unavailable
        }
    }
}

@MainActor @Observable final class CopilotConnectionUIModel {
    var presentation = CopilotConnectionPresentation(phase: .signInRequired, detail: "", enabled: true,
        consented: false, remembersConsent: false, serverAvailable: false, authenticating: false, reconnecting: false)
}

/// Uses the same baseline-aligned grid, secondary captions and standard controls as Settings.
struct CopilotConnectionView: View {
    var model: CopilotConnectionUIModel
    var toggle: () -> Void
    var check: () -> Void
    var signIn: () -> Void
    var signOut: () -> Void
    var cancel: () -> Void
    var chooseServer: () -> Void
    var close: () -> Void

    private var state: CopilotConnectionPresentation { model.presentation }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if state.phase == .connecting {
                        ProgressView().controlSize(.small)
                    } else {
                        StatusImage(status: state.statusImage)
                    }
                }
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(state.title)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("CopilotConnectionStatus")
                    Text(state.detail)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 28, alignment: .topLeading)
                        .accessibilityIdentifier("CopilotConnectionDetail")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 18) {
                GridRow {
                    Text("AI補完:").gridColumnAlignment(.trailing)
                    Toggle("AI補完を有効にする", isOn: Binding(
                        get: { state.suggestionsEnabled }, set: { _ in toggle() }))
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("CopilotEnableSuggestions")
                }
                GridRow {
                    Text("送信への同意:")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.consentTitle)
                        Text(state.consentExplanation)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("CopilotContextConsent")
                }
                GridRow {
                    Text("言語サーバー:")
                    HStack {
                        Text(state.serverAvailable ? "準備済み" : "未選択")
                            .foregroundStyle(state.serverAvailable ? .secondary : .primary)
                        Spacer(minLength: 8)
                        Button("選択…", action: chooseServer)
                            .disabled(state.busy)
                            .accessibilityIdentifier("CopilotChooseServer")
                    }
                }
            }

            Divider()
            HStack(spacing: 8) {
                Button("接続を確認", action: check)
                    .disabled(!state.canCheck)
                    .accessibilityIdentifier("CopilotCheckConnection")
                if state.canCancel {
                    Button("キャンセル", action: cancel)
                        .accessibilityIdentifier("CopilotCancelSignIn")
                } else if state.phase == .authenticated {
                    Button("サインアウト", action: signOut)
                        .disabled(!state.canAuthenticate)
                        .accessibilityIdentifier("CopilotSignOut")
                } else {
                    Button("サインイン…", action: signIn)
                        .disabled(!state.canAuthenticate)
                        .accessibilityIdentifier("CopilotSignIn")
                }
                Spacer(minLength: 8)
                Button("閉じる", action: close)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("CopilotCloseStatus")
            }
        }
        .padding(20)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

final class CopilotConnectionPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
