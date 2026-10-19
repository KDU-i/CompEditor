// SPDX-License-Identifier: Apache-2.0
import Foundation

struct ExpectedOutput: Sendable {
    let id: UUID
    let url: URL
    let loadedAt: Date
    let bytes: Data
}
enum ExpectedOutputError: Error { case notRegular, tooLarge, invalidUTF8, unreadable }
nonisolated enum ExpectedOutputReader {
    static let limit = 10 * 1024 * 1024
    static func read(_ url: URL) throws -> ExpectedOutput {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey])
            guard values.isRegularFile == true, values.isPackage != true else { throw ExpectedOutputError.notRegular }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // Bounded even if a file grows after selection. Never read a FIFO/device.
            var bytes = Data()
            while bytes.count <= limit {
                let chunk = try handle.read(upToCount: min(65536, limit + 1 - bytes.count)) ?? Data()
                if chunk.isEmpty { break }
                bytes.append(chunk)
            }
            guard bytes.count <= limit else { throw ExpectedOutputError.tooLarge }
            if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
            guard String(data: bytes, encoding: .utf8) != nil else { throw ExpectedOutputError.invalidUTF8 }
            return ExpectedOutput(id: UUID(), url: url, loadedAt: Date(), bytes: bytes)
        } catch let error as ExpectedOutputError { throw error }
        catch { throw ExpectedOutputError.unreadable }
    }
}
enum OutputComparisonMode: String, CaseIterable, Sendable { case normalized, strict }
enum OutputComparisonState: String, Sendable {
    case noExpected, notRun, running, stopped, failed, indeterminate, comparing, match, mismatch
}
struct OutputComparisonKey: Hashable, Sendable {
    let runID: UUID
    let loadID: UUID
    let mode: OutputComparisonMode
}
struct OutputDifference: Sendable {
    let line: Int
    /// One-based UTF-8 byte column; explicit so multibyte characters are unambiguous.
    let column: Int
    let actualLines: Int
    let expectedLines: Int
    let actualEOF: Bool
    let expectedEOF: Bool
    let actualFinalNewline: Bool
    let expectedFinalNewline: Bool
    let actual: String
    let expected: String
    let abbreviated: Bool
}
struct OutputComparison: Sendable {
    let key: OutputComparisonKey
    let difference: OutputDifference?
    var validUTF8 = true
}
nonisolated enum OutputComparator {
    static func state(expected: Bool, result: RunResult?, active: Bool) -> OutputComparisonState {
        guard expected else { return .noExpected }
        guard let result else { return active ? .running : .notRun }
        switch result.phase {
            case .idle: return .notRun
            case .preparing, .compiling, .running, .stopping: return .running
            case .cancelled: return .stopped
            case .failed: return .failed
            case .finished:
                guard result.termination?.succeeded == true else { return .failed }
                guard result.comparable else { return .indeterminate }
                return .comparing
        }
    }
    static func normalize(_ bytes: Data, mode: OutputComparisonMode) -> [UInt8] {
        guard mode == .normalized else { return Array(bytes) }
        var output: [UInt8] = []; output.reserveCapacity(bytes.count)
        var previousCR = false
        for byte in bytes {
            if byte == 10 && previousCR { previousCR = false; continue }
            output.append(byte == 13 ? 10 : byte); previousCR = byte == 13
        }
        return output
    }
    static func compare(actual: Data, expected: ExpectedOutput, runID: UUID, mode: OutputComparisonMode, stderr: Data = Data()) -> OutputComparison {
        let key = OutputComparisonKey(runID: runID, loadID: expected.id, mode: mode)
        guard String(data: actual, encoding: .utf8) != nil, String(data: stderr, encoding: .utf8) != nil else {
            return OutputComparison(key: key, difference: nil, validUTF8: false)
        }
        let a = normalize(actual, mode: mode), e = normalize(expected.bytes, mode: mode)
        // Byte equality preserves NFC/NFD distinctions that Swift String equality erases.
        guard a != e else { return OutputComparison(key: key, difference: nil) }
        var offset = 0, line = 1, column = 1
        while offset < min(a.count, e.count), a[offset] == e[offset] {
            if a[offset] == 13 { line += 1; column = 1 }
            else if a[offset] == 10 {
                if offset == 0 || a[offset - 1] != 13 { line += 1 }
                column = 1
            } else { column += 1 }
            offset += 1
        }
        // Fixed context budget, no edit-distance matrix or unbounded text layout.
        let start = max(0, offset - 160), budget = 1024
        func excerpt(_ bytes: [UInt8]) -> String {
            var lower = min(start, bytes.count), upper = min(bytes.count, offset + budget)
            while lower > 0 && lower < bytes.count && bytes[lower] & 0xc0 == 0x80 { lower -= 1 }
            while upper < bytes.count && bytes[upper] & 0xc0 == 0x80 { upper += 1 }
            return (lower > 0 ? "…" : "") + String(decoding: bytes[lower..<upper], as: UTF8.self) + (upper < bytes.count ? "…" : "⟨EOF⟩")
        }
        func lineCount(_ bytes: [UInt8]) -> Int {
            var count = 1, previousCR = false
            for byte in bytes {
                if byte == 13 || (byte == 10 && !previousCR) { count += 1 }
                previousCR = byte == 13
            }
            return count
        }
        return OutputComparison(key: key, difference: OutputDifference(line: line, column: column,
            actualLines: lineCount(a), expectedLines: lineCount(e),
            actualEOF: offset == a.count, expectedEOF: offset == e.count,
            actualFinalNewline: a.last == 10 || a.last == 13, expectedFinalNewline: e.last == 10 || e.last == 13,
            actual: excerpt(a), expected: excerpt(e), abbreviated: start > 0 || offset + budget < max(a.count, e.count)))
    }
    static func visible(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "·").replacingOccurrences(of: "\t", with: "⇥")
            .replacingOccurrences(of: "\r", with: "␍").replacingOccurrences(of: "\n", with: "␊\n")
            .replacingOccurrences(of: "\u{a0}", with: "⍽")
    }
}
