// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Deliberately accepts no document, URI, candidate text or arbitrary error string.
/// Process-local only: no persistence, transport, defaults or telemetry hooks.
struct CopilotDiagnostics {
    enum Kind: String { case automaticInline, automaticNextEdit, manualInline, manualNextEdit, fallbackNextEdit, history, settings }
    enum Stage: String { case attempt, started, response, excluded, cancelled, failed, displayed, skipped, settings }
    enum Reason: String {
        case none, ineligible, noEditor, automaticDisabled, visibleSuggestion, duplicateRequest
        case replacedRequest, textChanged, selectionChanged, viewportChanged, windowChanged, appInactive, interaction
        case malformedResponse, foreignDocument, staleVersion, staleResponse, invalidEdit, noInlineParts, duplicateCandidate, candidateLimit, noCandidates
        case ghostNotCurrent, stalePresentation, methodNotFound, stopped, timeout, otherError
        case nextEditDisabled, inlineNonempty
        case disabled, consentMissing, disconnected, readOnly, markedText, selectedText, multipleCarets
        case notFirstResponder, inactiveWindow, missingContext, unsupportedLanguage
    }
    struct Ticket: Equatable { let id: Int; let kind: Kind; let start: TimeInterval }
    struct Entry {
        let ticket: Ticket
        let stage: Stage
        let reason: Reason
        let elapsedMS: Int
        let fieldPresent: Bool?
        let arrayPresent: Bool?
        let count: Int?
        let automaticInline: Bool
        let automaticNextEdit: Bool
    }
    private(set) var entries: [Entry] = []
    private var sequence = 0
    static let capacity = 200
    mutating func ticket(_ kind: Kind) -> Ticket {
        sequence += 1
        return Ticket(id: sequence, kind: kind, start: ProcessInfo.processInfo.systemUptime)
    }
    mutating func record(_ ticket: Ticket, _ stage: Stage, reason: Reason = .none,
                         fieldPresent: Bool? = nil, arrayPresent: Bool? = nil, count: Int? = nil,
                         automaticInline: Bool, automaticNextEdit: Bool) {
        entries.append(Entry(ticket: ticket, stage: stage, reason: reason,
                             elapsedMS: Int(max(0, ProcessInfo.processInfo.systemUptime - ticket.start) * 1000),
                             fieldPresent: fieldPresent, arrayPresent: arrayPresent, count: count.map { max(0, $0) },
                             automaticInline: automaticInline, automaticNextEdit: automaticNextEdit))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }
    var text: String {
        entries.map { e in
            var line = "#\(e.ticket.id) \(e.ticket.kind.rawValue) \(e.stage.rawValue) reason=\(e.reason.rawValue) elapsedMS=\(e.elapsedMS) automaticInline=\(e.automaticInline) automaticNextEdit=\(e.automaticNextEdit)"
            if let value = e.fieldPresent { line += " fieldPresent=\(value)" }
            if let value = e.arrayPresent { line += " arrayPresent=\(value)" }
            if let value = e.count { line += " count=\(value)" }
            return line
        }.joined(separator: "\n")
    }
}
