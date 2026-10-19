// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Coordinates belong to the normalized preview, never to the source document.
/// Keep CRLF normalization identical to the existing native preview; lone CRs
/// remain intact. Layout, appearance and scale are deliberately absent here.
struct SemanticNextEditDisplayData {
    let before: String
    let after: String
    let removedRanges: [NSRange]
    let insertedRanges: [NSRange]

    init(before: String, after: String, budget: Duration = .milliseconds(50)) {
        self.before = before.replacingOccurrences(of: "\r\n", with: "\n")
        self.after = after.replacingOccurrences(of: "\r\n", with: "\n")
        let hunks = CopilotNextEditPolicy.hunks(.init(range: NSRange(location: 0, length: self.before.utf16.count), text: self.after, primary: true), in: self.before, budget: budget)
        removedRanges = hunks.map(\.range)
        var delta = 0
        insertedRanges = hunks.map { edit in
            let range = NSRange(location: edit.range.location + delta, length: edit.text.utf16.count)
            delta += edit.text.utf16.count - edit.range.length
            return range
        }
    }
}

/// A bounded, candidate-owned slot shared with its ghosts, never with NSViews.
/// A fresh candidate or changed edit/revision gets a fresh slot. Caret-only
/// presentation can create another ghost while retaining this slot. No text
/// hashing/comparison is needed during viewport updates. Main-thread use only.
final class SemanticNextEditDisplayCache {
    private var data: SemanticNextEditDisplayData?
    #if DEBUG
    private(set) var preparationCount = 0
    #endif

    func prepare(before: String, after: String) -> SemanticNextEditDisplayData {
        if let data { return data }
        let prepared = SemanticNextEditDisplayData(before: before, after: after)
        data = prepared
        #if DEBUG
        preparationCount += 1
        #endif
        return prepared
    }
}
