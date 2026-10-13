// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Only non-secret preferences are owned by the editor. Authentication material
/// remains opaque and is exclusively managed by the official language server.
struct CopilotSessionPreferences {
    let defaults: UserDefaults
    private static let enabledKey = "CompEditor.Copilot.connectionEnabled"
    private static let consentKey = "CompEditor.Copilot.rememberContextConsent.v1"
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
