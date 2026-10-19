// SPDX-License-Identifier: Apache-2.0
import AppKit
import Testing
@testable import CotEditor

@MainActor struct SemanticNextEditDisplayTests {
    @Test func normalizedUTF16RangesReconstructThePreview() {
        let pairs = [
            ("", ""), ("", "😀\r\n"), ("delete😀", ""),
            ("old\r\nsame😀e\u{301}\r\nold", "new\r\nsame😀e\u{301}\r\nlonger"),
            ("old\rsame\rold", "new\rsame\rlonger"),
            ("e\u{301} tail", "é end"), ("old + middle + old", "new + middle + longer")
        ]
        for (before, after) in pairs {
            // Zero budget exercises the policy's conservative fallback too.
            for budget in [Duration.milliseconds(50), .zero] {
                let diff = SemanticNextEditDisplayData(before: before, after: after, budget: budget)
                #expect(diff.before.utf16.elementsEqual(before.replacingOccurrences(of: "\r\n", with: "\n").utf16))
                #expect(diff.after.utf16.elementsEqual(after.replacingOccurrences(of: "\r\n", with: "\n").utf16))
                #expect(diff.removedRanges.count == diff.insertedRanges.count)
                var reconstructed = diff.before
                for (removed, inserted) in zip(diff.removedRanges, diff.insertedRanges).reversed() {
                    #expect(NSMaxRange(removed) <= diff.before.utf16.count)
                    #expect(NSMaxRange(inserted) <= diff.after.utf16.count)
                    reconstructed = (reconstructed as NSString).replacingCharacters(in: removed, with: (diff.after as NSString).substring(with: inserted))
                }
                #expect(reconstructed.utf16.elementsEqual(diff.after.utf16))
            }
        }
        let diff = SemanticNextEditDisplayData(before: "old\r\nsame😀\r\nold", after: "new\r\nsame😀\r\nlonger")
        #expect(diff.removedRanges.count == 2)
        #expect(diff.removedRanges.last == NSRange(location: 11, length: 3))
        #expect(diff.insertedRanges.last == NSRange(location: 11, length: 6))
    }

    @Test func ghostLifetimesSeparateEqualTextDocumentsAndRevisions() {
        func ghost(revision: Int) -> SemanticGhostPreview {
            SemanticGhostPreview(text: "new\n", snapshot: "old\n", caret: 0, fileURL: nil,
                language: .python, copilot: true, nextEdit: true,
                replacementRange: NSRange(location: 0, length: 4), replacedText: "old\n", revision: revision)
        }
        var first: SemanticGhostPreview? = ghost(revision: 1)
        let otherDocument = ghost(revision: 1), newer = ghost(revision: 2)
        weak var released = first?.displayDiff
        #expect(first?.displayDiff !== otherDocument.displayDiff)
        #expect(first?.displayDiff !== newer.displayDiff)
        _ = first?.displayDiff.prepare(before: "old\n", after: "new\n")
        first = nil
        #expect(released == nil)
        #if DEBUG
        #expect(otherDocument.displayDiff.preparationCount == 0)
        #expect(newer.displayDiff.preparationCount == 0)
        #endif
    }

    @Test func cachedDataRelayoutsWithoutPreparingAgainAndReleasesWithOwner() {
        var cache: SemanticNextEditDisplayCache? = SemanticNextEditDisplayCache()
        weak var released = cache
        let before = "old\nsame😀\nold", after = "new\nsame😀\nlonger"
        for index in 0..<100 {
            let diff = cache!.prepare(before: before, after: after)
            let wide = index.isMultiple(of: 2)
            let surface = SemanticNextEditPreview(diff: diff, maximumWidth: wide ? 800 : 300,
                font: .monospacedSystemFont(ofSize: wide ? 13 : 16, weight: .regular), lineHeight: 20, baseline: 15,
                foreground: wide ? .black : .white, background: wide ? .white : .black)
            #expect(surface.fullHeight > 0)
            #expect(surface.frame.width <= (wide ? 800 : 300))
            #expect(surface.subviews.count == 2)
            #expect((surface.subviews[1].frame.minY == 0) == wide)
        }
        #if DEBUG
        #expect(cache?.preparationCount == 1)
        #endif
        let another = SemanticNextEditDisplayCache()
        _ = another.prepare(before: before, after: after)
        #expect(another !== cache!) // Equal text in a different owner never aliases.
        cache = nil
        #expect(released == nil)
    }
}
