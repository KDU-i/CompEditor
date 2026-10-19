// SPDX-License-Identifier: Apache-2.0
import Foundation

@main struct ExpectedOutputTests {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !value() { fatalError(label) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let run = UUID()
        func snapshot(_ data: Data) -> ExpectedOutput {
            ExpectedOutput(id: UUID(), url: root.appendingPathComponent("expected"), loadedAt: Date(), bytes: data)
        }
        func compare(_ actual: String, _ expected: String, _ mode: OutputComparisonMode) -> OutputComparison {
            OutputComparator.compare(actual: Data(actual.utf8), expected: snapshot(Data(expected.utf8)), runID: run, mode: mode)
        }
        let pairs: [(String, String, Bool, Bool)] = [
            ("", "", true, true), ("", "\n", false, false),
            ("a\n", "a\r\n", true, false), ("a\n", "a\r", true, false),
            ("a", "a\n", false, false), ("a\n\n", "a\n", false, false),
            ("a \n", "a\n", false, false), ("\t", " ", false, false),
            ("\u{a0}", " ", false, false), ("日本語😀\n", "日本語😀\n", true, true),
            ("é", "e\u{301}", false, false), ("a", "b", false, false),
            ("a\nb\n", "a\n", false, false), ("A", "a", false, false),
            ("x\r\r\n", "x\n\n", true, false)
        ]
        for (a, e, normalized, strict) in pairs {
            for mode in OutputComparisonMode.allCases {
                check((compare(a, e, mode).difference == nil) == (mode == .strict ? strict : normalized), "pair \(a.debugDescription) \(e.debugDescription) \(mode)")
            }
        }
        for name in ["answer.out", "answer.txt", "answer.log", "answer.arbitrary", "answer"] {
            let url = root.appendingPathComponent(name)
            try Data("日本語😀\r\n".utf8).write(to: url)
            let loaded = try ExpectedOutputReader.read(url)
            check(loaded.bytes == Data("日本語😀\r\n".utf8), "extension \(name)")
            try Data([0xc0, 0xaf]).write(to: url)
            do { _ = try ExpectedOutputReader.read(url); fatalError("invalid accepted") }
            catch ExpectedOutputError.invalidUTF8 { checks += 1 }
        }
        let url = root.appendingPathComponent("sizes")
        for count in [0, ExpectedOutputReader.limit - 1, ExpectedOutputReader.limit] {
            try Data(repeating: 0x61, count: count).write(to: url)
            let sized = try ExpectedOutputReader.read(url)
            check(sized.bytes.count == count, "size \(count)")
        }
        try Data(repeating: 0x61, count: ExpectedOutputReader.limit + 1).write(to: url)
        do { _ = try ExpectedOutputReader.read(url); fatalError("oversize accepted") }
        catch ExpectedOutputError.tooLarge { checks += 1 }
        try Data([0xef,0xbb,0xbf] + Array("text".utf8)).write(to: url)
        let bom = try ExpectedOutputReader.read(url)
        check(bom.bytes == Data("text".utf8), "BOM")
        do { _ = try ExpectedOutputReader.read(root); fatalError("directory accepted") }
        catch ExpectedOutputError.notRegular { checks += 1 }
        do { _ = try ExpectedOutputReader.read(root.appendingPathComponent("missing")); fatalError("missing accepted") }
        catch ExpectedOutputError.unreadable { checks += 1 }
        let denied = root.appendingPathComponent("denied.out")
        try Data("private".utf8).write(to: denied)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        do { _ = try ExpectedOutputReader.read(denied); fatalError("permission denied file accepted") }
        catch ExpectedOutputError.unreadable { checks += 1 }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: denied.path)
        let source = RunSource(url: url, revision: 0, text: "", diskBytes: Data(), modificationDate: nil)
        var result = RunResult(id: run, source: source)
        check(OutputComparator.state(expected: false, result: nil, active: false) == .noExpected, "no expected")
        check(OutputComparator.state(expected: true, result: nil, active: false) == .notRun, "not run")
        check(OutputComparator.state(expected: true, result: nil, active: true) == .running, "preparing")
        for phase in [RunPhase.preparing, .compiling, .running, .stopping] {
            result.phase = phase
            check(OutputComparator.state(expected: true, result: result, active: true) == .running, "active")
        }
        result.phase = .cancelled; result.termination = .cancelled
        check(OutputComparator.state(expected: true, result: result, active: false) == .stopped, "stopped")
        for termination in [RunTermination.exit(1), .signal(9), .launchFailure(2), .cancelled] {
            for phase in [RunPhase.failed, .finished] {
                result.phase = phase; result.termination = termination
                check(OutputComparator.state(expected: true, result: result, active: false) == .failed, "failure \(termination)")
            }
        }
        result.phase = .finished; result.termination = .exit(0)
        result.compilationFailed = true
        check(OutputComparator.state(expected: true, result: result, active: false) == .failed, "failed compilation cannot match")
        result.compilationFailed = false
        result.stderr.bytes = Data("warning".utf8)
        check(OutputComparator.state(expected: true, result: result, active: false) == .comparing, "stderr warning allowed")
        for stream in [0,1] {
            for decode in [false,true] {
                var bad = RunOutput(); bad.omitted = decode ? 0 : 1; bad.decodingError = decode
                if stream == 0 { result.stdout = bad } else { result.stderr = bad }
                check(OutputComparator.state(expected: true, result: result, active: false) == .indeterminate, "incomplete")
                result.stdout = RunOutput(); result.stderr = RunOutput()
            }
        }
        let invalid = OutputComparator.compare(actual: Data([0xff]), expected: snapshot(Data()), runID: run, mode: .strict)
        check(!invalid.validUTF8, "raw invalid UTF8")
        let invalidError = OutputComparator.compare(actual: Data(), expected: snapshot(Data()), runID: run, mode: .strict, stderr: Data([0xff]))
        check(!invalidError.validUTF8, "raw invalid stderr UTF8")
        let diff = compare("a\nb", "a\nb\nextra", .normalized).difference!
        check(diff.line == 2 && diff.column == 2 && diff.actualEOF && !diff.expectedEOF, "EOF position")
        check(diff.actualLines == 2 && diff.expectedLines == 3 && diff.expected.contains("EOF"), "line counts")
        check(!diff.actualFinalNewline, "missing LF")
        let nfc = compare("é", "e\u{301}", .strict).difference!
        check(nfc.actualByte == 0xc3 && nfc.expectedByte == 0x65, "Unicode mismatch byte evidence")
        let cr = compare("a\rb", "a\rc", .strict).difference!
        check(cr.line == 2 && cr.column == 1 && cr.actualLines == 2, "strict CR coordinates")
        let crlf = compare("a\r\nb", "a\r\nc", .strict).difference!
        check(crlf.line == 2 && crlf.column == 1 && crlf.actualLines == 2, "strict CRLF coordinates")
        let large = String(repeating: "a", count: ExpectedOutputReader.limit - 1)
        let first = compare("b" + large, "a" + large, .strict).difference!
        let last = compare(large + "b", large + "a", .normalized).difference!
        check(first.line == 1 && first.column == 1 && first.abbreviated && first.actual.utf8.count < 1300, "large first")
        check(last.column == ExpectedOutputReader.limit && last.abbreviated && last.actual.utf8.count < 1300, "large last")
        let a = snapshot(Data()), b = snapshot(Data())
        let key = OutputComparisonKey(runID: run, loadID: a.id, mode: .normalized)
        check(key != OutputComparisonKey(runID: run, loadID: b.id, mode: .normalized), "load identity")
        check(key != OutputComparisonKey(runID: UUID(), loadID: a.id, mode: .normalized), "run identity")
        check(key != OutputComparisonKey(runID: run, loadID: a.id, mode: .strict), "mode identity")
        check(OutputComparator.visible(" \t\r\n\u{a0}").contains("·⇥␍␊\n⍽"), "visible whitespace")
        print("Expected output: \(checks) checks passed")
    }
}
