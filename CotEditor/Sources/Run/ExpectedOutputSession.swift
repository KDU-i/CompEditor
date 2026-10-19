// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(AppKit)
import AppKit
#endif
import Observation

/// Serialize bounded work across documents so rapid mode/selection changes do
/// not allocate multiple full comparison buffers concurrently.
private actor ExpectedOutputWork {
    static let shared = ExpectedOutputWork()
    func read(_ url: URL) async -> Result<ExpectedOutput, ExpectedOutputError> {
        do { return .success(try ExpectedOutputReader.read(url)) }
        catch { return .failure((error as? ExpectedOutputError) ?? .unreadable) }
    }
    func compare(_ result: RunResult, _ expected: ExpectedOutput, _ mode: OutputComparisonMode) async -> OutputComparison {
        OutputComparator.compare(actual: result.stdout.bytes, expected: expected, runID: result.id, mode: mode, stderr: result.stderr.bytes)
    }
}

@MainActor @Observable final class ExpectedOutputSession {
    private(set) var expected: ExpectedOutput?
    private(set) var selectedURL: URL?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var comparison: OutputComparison?
    var mode: OutputComparisonMode = .normalized { didSet { compare() } }
    var showWhitespace = true
    typealias Reader = @Sendable (URL) async -> Result<ExpectedOutput, ExpectedOutputError>
    typealias Comparator = @Sendable (RunResult, ExpectedOutput, OutputComparisonMode) async -> OutputComparison
    private let reader: Reader
    private let comparator: Comparator
    init(reader: @escaping Reader = { url in
        await ExpectedOutputWork.shared.read(url)
    }, comparator: @escaping Comparator = { result, expected, mode in
        await ExpectedOutputWork.shared.compare(result, expected, mode)
    }) { self.reader = reader; self.comparator = comparator }
    private var result: RunResult?
    private var active = false
    private var generation = UUID()
    private var loadGeneration = UUID()
    var state: OutputComparisonState {
        let state = OutputComparator.state(expected: expected != nil, result: result, active: active)
        guard state == .comparing else { return state }
        guard let expected, let result,
              comparison?.key == OutputComparisonKey(runID: result.id, loadID: expected.id, mode: mode) else { return .comparing }
        guard comparison?.validUTF8 == true else { return .indeterminate }
        return comparison?.difference == nil ? .match : .mismatch
    }
    func update(result: RunResult?, active: Bool) {
        self.result = result; self.active = active
        // Streaming refreshes do not schedule comparisons until terminal success.
        compare()
    }
    #if canImport(AppKit)
    func choose(window: NSWindow?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        // Intentionally no allowedContentTypes/extension whitelist.
        panel.message = runText("ExpectedPickerHelp")
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.load(url) }
        }
    }
    #endif
    func clear() {
        loadGeneration = UUID(); generation = UUID()
        expected = nil; selectedURL = nil; comparison = nil; error = nil; loading = false
    }
    func reload() { if let selectedURL { load(selectedURL) } }
    func load(_ url: URL) {
        let token = UUID(); loadGeneration = token; generation = UUID()
        selectedURL = url; expected = nil; comparison = nil; error = nil; loading = true
        Task {
            let outcome = await reader(url)
            guard loadGeneration == token else { return }
            loading = false
            switch outcome {
                case .success(let snapshot): expected = snapshot; compare()
                case .failure(let reason):
                    switch reason {
                        case .notRegular: error = runText("ExpectedNotRegular")
                        case .tooLarge: error = runText("ExpectedTooLarge")
                        case .invalidUTF8: error = runText("ExpectedInvalidUTF8")
                        case .unreadable: error = runText("ExpectedUnreadable")
                    }
            }
        }
    }
    private func compare() {
        generation = UUID(); comparison = nil
        guard let expected, let result,
              OutputComparator.state(expected: true, result: result, active: active) == .comparing else { return }
        let token = generation, mode = mode
        Task {
            let value = await comparator(result, expected, mode)
            guard generation == token, self.expected?.id == value.key.loadID,
                  self.result?.id == value.key.runID, self.mode == value.key.mode else { return }
            comparison = value
        }
    }
}
