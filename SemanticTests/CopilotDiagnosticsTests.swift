// SPDX-License-Identifier: Apache-2.0
import Foundation

@main struct CopilotDiagnosticsTests {
    static func main() {
        var log = CopilotDiagnostics()
        let ticket = log.ticket(.manualNextEdit)
        log.record(ticket, .started, automaticInline: true, automaticNextEdit: false)
        log.record(ticket, .response, fieldPresent: true, arrayPresent: true, count: 0,
                   automaticInline: true, automaticNextEdit: false)
        assert(log.entries[1].fieldPresent == true && log.entries[1].count == 0)
        assert(log.text.contains("manualNextEdit response"))
        assert(log.text.contains("automaticNextEdit=false"))
        log.record(ticket, .response, fieldPresent: false, arrayPresent: false, count: 0,
                   automaticInline: true, automaticNextEdit: false)
        log.record(ticket, .response, fieldPresent: true, arrayPresent: false, count: 0,
                   automaticInline: true, automaticNextEdit: false)
        log.record(ticket, .cancelled, reason: .selectionChanged,
                   automaticInline: true, automaticNextEdit: false)
        log.record(ticket, .failed, reason: .otherError,
                   automaticInline: true, automaticNextEdit: false)
        assert(log.entries[1].arrayPresent == true)
        assert(log.entries[2].fieldPresent == false)
        assert(log.entries[3].fieldPresent == true && log.entries[3].arrayPresent == false)
        assert(log.text.contains("reason=selectionChanged"))
        assert(log.text.contains("reason=otherError"))
        for _ in 0..<250 {
            log.record(ticket, .excluded, reason: .invalidEdit, automaticInline: true, automaticNextEdit: true)
        }
        assert(log.entries.count == CopilotDiagnostics.capacity)
        assert(log.entries.allSatisfy { $0.elapsedMS >= 0 })
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 #=\n")
        assert(log.text.allSatisfy { allowed.contains($0) })
        // Only enums, booleans and integers can enter the log; arbitrary source/error data cannot.
        assert(!log.text.contains("/")); assert(!log.text.contains(":"))
        print("Copilot diagnostics: bounded memory, fixed fields, settings and empty response tests passed")
    }
}
