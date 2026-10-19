// SPDX-License-Identifier: Apache-2.0
import Foundation

// Linux does not ship Apple's String.LocalizationValue. Only app-owned error
// keys are needed to exercise the production coordinator with Observation.
#if !canImport(AppKit)
func runText(_ key: String) -> String { key }
#else
func runText(_ key: String.LocalizationValue) -> String { String(localized: key, table: "Run") }
#endif

actor PendingOutputs {
    var reads: [URL: CheckedContinuation<Result<ExpectedOutput, ExpectedOutputError>, Never>] = [:]
    var comparisons: [OutputComparisonKey: CheckedContinuation<OutputComparison, Never>] = [:]
    func read(_ url: URL) async -> Result<ExpectedOutput, ExpectedOutputError> {
        await withCheckedContinuation { reads[url] = $0 }
    }
    func compare(_ result: RunResult, _ expected: ExpectedOutput, _ mode: OutputComparisonMode) async -> OutputComparison {
        await withCheckedContinuation { comparisons[OutputComparisonKey(runID: result.id, loadID: expected.id, mode: mode)] = $0 }
    }
    func hasRead(_ url: URL) -> Bool { reads[url] != nil }
    func hasComparison(_ key: OutputComparisonKey) -> Bool { comparisons[key] != nil }
    func finishRead(_ snapshot: ExpectedOutput) { reads.removeValue(forKey: snapshot.url)!.resume(returning: .success(snapshot)) }
    func failRead(_ url: URL) { reads.removeValue(forKey: url)!.resume(returning: .failure(.invalidUTF8)) }
    func finishComparison(_ key: OutputComparisonKey, mismatch: Bool = false) {
        let expected = ExpectedOutput(id: key.loadID, url: URL(fileURLWithPath: "/e"), loadedAt: Date(), bytes: Data())
        comparisons.removeValue(forKey: key)!.resume(returning: OutputComparator.compare(actual: Data((mismatch ? "x" : "").utf8), expected: expected, runID: key.runID, mode: key.mode))
    }
}

@main struct ExpectedOutputSessionTests {
    @MainActor static func main() async {
        var checks = 0
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { fatalError(label) } }
        func until(_ condition: () async -> Bool) async {
            for _ in 0..<100000 { if await condition() { return }; await Task.yield() }
            fatalError("async condition did not complete")
        }
        let pending = PendingOutputs()
        let model = ExpectedOutputSession(reader: { await pending.read($0) }, comparator: { await pending.compare($0, $1, $2) })
        let a = ExpectedOutput(id: UUID(), url: URL(fileURLWithPath: "/a"), loadedAt: Date(), bytes: Data())
        let b = ExpectedOutput(id: UUID(), url: URL(fileURLWithPath: "/b"), loadedAt: Date(), bytes: Data())
        model.load(a.url); await until { await pending.hasRead(a.url) }
        model.load(b.url); await until { await pending.hasRead(b.url) }
        await pending.finishRead(b); await until { model.expected?.id == b.id }
        await pending.finishRead(a)
        for _ in 0..<100 { await Task.yield() }
        check(model.expected?.id == b.id, "late load A must not replace B")
        let source = RunSource(url: URL(fileURLWithPath: "/source.py"), revision: 0, text: "", diskBytes: Data(), modificationDate: nil)
        let old = RunResult(id: UUID(), source: source, phase: .finished, termination: .exit(0))
        let new = RunResult(id: UUID(), source: source, phase: .finished, termination: .exit(0))
        let oldKey = OutputComparisonKey(runID: old.id, loadID: b.id, mode: .normalized)
        let newKey = OutputComparisonKey(runID: new.id, loadID: b.id, mode: .normalized)
        model.update(result: old, active: false); await until { await pending.hasComparison(oldKey) }
        model.update(result: nil, active: true)
        check(model.comparison == nil && model.state == .running, "rerun clears verdict immediately")
        model.update(result: new, active: false); await until { await pending.hasComparison(newKey) }
        await pending.finishComparison(newKey, mismatch: true); await until { model.comparison?.key == newKey }
        await pending.finishComparison(oldKey)
        for _ in 0..<100 { await Task.yield() }
        check(model.comparison?.key == newKey && model.state == .mismatch, "old run cannot replace new run")
        model.mode = .strict
        let strictKey = OutputComparisonKey(runID: new.id, loadID: b.id, mode: .strict)
        await until { await pending.hasComparison(strictKey) }
        check(model.comparison == nil, "mode clears verdict")
        model.clear(); await pending.finishComparison(strictKey)
        for _ in 0..<100 { await Task.yield() }
        check(model.comparison == nil && model.state == .noExpected, "clear rejects in-flight comparison")
        model.load(a.url); await until { await pending.hasRead(a.url) }
        model.clear(); await pending.finishRead(a)
        for _ in 0..<100 { await Task.yield() }
        check(model.expected == nil && !model.loading, "clear rejects in-flight read")
        model.load(b.url); await until { await pending.hasRead(b.url) }
        await pending.failRead(b.url); await until { model.error != nil }
        check(model.expected == nil && model.comparison == nil && !model.loading, "invalid import removes previous verdict")
        model.reload(); await until { await pending.hasRead(b.url) }
        await pending.finishRead(b); await until { await pending.hasComparison(strictKey) }
        await pending.finishComparison(strictKey); await until { model.state == .match }
        check(model.expected?.id == b.id && model.state == .match, "explicit reload")
        print("Expected output session: \(checks) async race checks passed")
    }
}
