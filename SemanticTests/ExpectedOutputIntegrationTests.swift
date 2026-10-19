// SPDX-License-Identifier: Apache-2.0
import Foundation

@main struct ExpectedOutputIntegrationTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("期待出力 " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expectedURL = root.appendingPathComponent("answer.unrestricted")
        let expectedBytes = Data("日本語😀\r\n".utf8)
        try expectedBytes.write(to: expectedURL)
        let expected = try ExpectedOutputReader.read(expectedURL)
        let python = "/usr/bin/python3", jdk = ProcessInfo.processInfo.environment["RUN_TEST_JDK"]
        var count = 0
        for language in ["py", "java"] {
            if language == "java" && jdk == nil { print("SKIP Java comparison integration: set RUN_TEST_JDK"); continue }
            for wrong in [false, true] {
                let sourceURL = root.appendingPathComponent(language == "java" ? "Main.java" : "main.py")
                let output = wrong ? "wrong" : "日本語😀"
                let text = language == "java"
                    ? "public class Main { public static void main(String[] a) { System.out.println(\"\(output)\"); System.err.print(\"warning\"); } }"
                    : "import sys\nprint('\(output)')\nprint('warning', file=sys.stderr)\n"
                let bytes = Data(text.utf8)
                try bytes.write(to: sourceURL)
                let source = RunSource(url: sourceURL, revision: 0, text: text, diskBytes: bytes, modificationDate: nil)
                let plan = try RunPlanner.plan(source: source, python: python, jdk: jdk, main: "", temporaryRoot: root.appendingPathComponent("compile"))
                defer { if let owned = plan.ownedDirectory { try? FileManager.default.removeItem(at: owned) } }
                let worker = RunWorker()!
                let outcome = RunPipeline.perform(plan, input: Data(), interactive: false, launcher: worker) { _ in }
                var result = RunResult(id: UUID(), source: source, phase: .finished)
                result.stdout = worker.output(0, finished: true); result.stderr = worker.output(1, finished: true)
                result.termination = outcome.termination
                guard outcome.termination.succeeded,
                      OutputComparator.state(expected: true, result: result, active: false) == .comparing,
                      !result.stderr.bytes.isEmpty else { fatalError("fixture failed \(language)") }
                let value = OutputComparator.compare(actual: result.stdout.bytes, expected: expected, runID: result.id, mode: .normalized)
                guard (value.difference != nil) == wrong else { fatalError("unexpected verdict") }
                let strict = OutputComparator.compare(actual: result.stdout.bytes, expected: expected, runID: result.id, mode: .strict)
                guard strict.difference != nil else { fatalError("strict newline distinction lost") }
                guard try Data(contentsOf: sourceURL) == bytes,
                      try Data(contentsOf: expectedURL) == expectedBytes,
                      plan.execute.directory.path == root.path else { fatalError("source/expected/cwd changed") }
                count += 1
                print("PASS \(language) comparison: \(wrong ? "mismatch" : "match"), stderr warning, strict newline, source/expected/cwd preserved")
            }
        }
        print("Expected output integration: \(count) fixtures passed")
    }
}
