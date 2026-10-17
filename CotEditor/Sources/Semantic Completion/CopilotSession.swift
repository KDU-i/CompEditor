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

/// Default selection triggers from the public NES provider. Experiment-specific
/// debounce and editor-switch settings are deliberately not guessed.
struct CopilotSelectionTriggerPolicy {
    private struct Document {
        var edited: TimeInterval
        var lines: [Int: TimeInterval] = [:]
    }
    private var documents: [UUID: Document] = [:]
    private var lastRequest: TimeInterval?
    private var lastRejection: TimeInterval?
    mutating func edited(_ buffer: UUID, at now: TimeInterval) {
        // Entries older than the provider's trigger window cannot trigger again.
        // Keep every still-recent document instead of evicting an active one by
        // an unrelated fixed document count.
        documents = documents.filter { now - $0.value.edited < 10 }
        documents[buffer] = Document(edited: now)
    }
    mutating func requested(at now: TimeInterval) { lastRequest = now }
    mutating func rejected(at now: TimeInterval) { lastRejection = now }
    mutating func shouldRequest(_ buffer: UUID, line: Int, at now: TimeInterval) -> Bool {
        if let lastRejection, now - lastRejection < 5 { documents.removeValue(forKey: buffer); return false }
        guard var document = documents[buffer], now - document.edited < 10,
              let lastRequest, now - lastRequest < 10 else { return false }
        if let previous = document.lines[line], now - previous < 5 { return false }
        document.lines = document.lines.filter { now - $0.value < 10 }
        document.lines[line] = now
        documents[buffer] = document
        return true
    }
}
