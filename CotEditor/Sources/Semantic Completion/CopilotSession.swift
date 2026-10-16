// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Only non-secret preferences are owned by the editor. Authentication material
/// remains opaque and is exclusively managed by the official language server.
struct CopilotSessionPreferences {
    let defaults: UserDefaults
    private static let enabledKey = "CompEditor.Copilot.connectionEnabled"
    private static let consentKey = "CompEditor.Copilot.rememberContextConsent.v1"
    var automaticSuggestions: Bool {
        get { defaults.object(forKey: "CompEditor.Copilot.automaticSuggestions.v1") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "CompEditor.Copilot.automaticSuggestions.v1") }
    }
    var automaticNextEdits: Bool {
        get { defaults.bool(forKey: "CompEditor.Copilot.automaticNextEdits.v1") }
        nonmutating set { defaults.set(newValue, forKey: "CompEditor.Copilot.automaticNextEdits.v1") }
    }
    var enabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }
    var remembersContextConsent: Bool {
        get { defaults.bool(forKey: Self.consentKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.consentKey) }
    }
}

enum CopilotAccountState: Equatable {
    case authenticated, notSignedIn, notAuthorized, unknown
    init(_ response: LSPJSON) {
        switch response["status"].string {
            case "OK", "MaybeOK", "AlreadySignedIn": self = .authenticated
            case "NotSignedIn": self = .notSignedIn
            case "NotAuthorized": self = .notAuthorized
            default: self = .unknown
        }
    }
}

/// One provider owns the preview at a time. NES stays usable with inline auto off.
enum CopilotAutomaticRequest { case inline, nextEdit }
enum CopilotAutomaticTrigger { case typing, caretMove, postAccept }
struct CopilotAutomaticPolicy {
    let inline: Bool
    let nextEdits: Bool
    func request(after trigger: CopilotAutomaticTrigger) -> CopilotAutomaticRequest? {
        switch trigger {
            case .typing: inline ? .inline : (nextEdits ? .nextEdit : nil)
            case .caretMove: nextEdits ? .nextEdit : nil
            case .postAccept: nextEdits ? .nextEdit : (inline ? .inline : nil)
        }
    }
    func needsNextEditFallback(displayableInlineCount: Int, serverAvailable: Bool) -> Bool {
        nextEdits && serverAvailable && displayableInlineCount == 0
    }
}
