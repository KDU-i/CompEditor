// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

struct ExpectedOutputView: View {
    @Bindable var model: ExpectedOutputSession
    let window: NSWindow?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack { controls }
                VStack(alignment: .leading) { controls }
            }
            if let url = model.selectedURL {
                Text(url.lastPathComponent).help(url.path).textSelection(.enabled)
            }
            if let expected = model.expected {
                Text("UTF-8 · " + expected.loadedAt.formatted(date: .numeric, time: .standard))
                    .font(.caption).textSelection(.enabled)
            }
            Picker(runText("ComparisonMode"), selection: $model.mode) {
                Text(runText("NewlineNormalized")).tag(OutputComparisonMode.normalized)
                Text(runText("StrictComparison")).tag(OutputComparisonMode.strict)
            }.pickerStyle(.menu)
            Text(model.loading ? runText("ExpectedLoading") : model.error ?? stateText)
                .font(.callout).textSelection(.enabled)
                .accessibilityLabel(runText("ComparisonStatus") + ": " + (model.loading ? runText("ExpectedLoading") : model.error ?? stateText))
            if let difference = model.comparison?.difference {
                Text(runText("FirstDifference") + " \(difference.line):\(difference.column) (" + runText("UTF8Column") + ")")
                    .textSelection(.enabled)
                Text(runText("LineCounts") + " \(difference.actualLines) / \(difference.expectedLines)")
                if difference.actualLines > difference.expectedLines {
                    Text(runText("ExtraActualLines") + " \(difference.actualLines - difference.expectedLines)")
                } else if difference.actualLines < difference.expectedLines {
                    Text(runText("MissingActualLines") + " \(difference.expectedLines - difference.actualLines)")
                }
                Text(runText("FinalNewline") + " " + runText("Actual") + ": " + yesNo(difference.actualFinalNewline)
                     + " / " + runText("Expected") + ": " + yesNo(difference.expectedFinalNewline))
                if difference.actualEOF { Text(runText("ActualEOF")) }
                if difference.expectedEOF { Text(runText("ExpectedEOF")) }
                Toggle(runText("ShowWhitespace"), isOn: $model.showWhitespace)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top) {
                        excerpt(difference.actual, label: runText("Actual")).frame(minWidth: 260)
                        excerpt(difference.expected, label: runText("Expected")).frame(minWidth: 260)
                    }
                    VStack(alignment: .leading) { excerpts(difference) }
                }
                if difference.abbreviated { Text(runText("DifferenceLimited")).font(.caption) }
            }
            Text(runText("ExpectedSnapshotHelp")).font(.caption)
            Divider()
        }
    }
    @ViewBuilder private var controls: some View {
        Button(runText("LoadExpected")) { model.choose(window: window) }
        Button(runText("ReloadExpected")) { model.reload() }.disabled(model.selectedURL == nil || model.loading)
        Button(runText("ClearExpected")) { model.clear() }.disabled(model.selectedURL == nil)
    }
    @ViewBuilder private func excerpts(_ difference: OutputDifference) -> some View {
        excerpt(difference.actual, label: runText("Actual"))
        excerpt(difference.expected, label: runText("Expected"))
    }
    private func excerpt(_ text: String, label: String) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.headline)
            RunOutputText(text: model.showWhitespace ? OutputComparator.visible(text) : text, label: label).frame(height: 120)
        }
    }
    private func yesNo(_ value: Bool) -> String { runText(value ? "Present" : "Absent") }
    private var stateText: String {
        switch model.state {
            case .noExpected: runText("NoExpected")
            case .notRun: runText("ComparisonNotRun")
            case .running: runText("ComparisonRunning")
            case .stopped: runText("ComparisonStopped")
            case .failed: runText("ComparisonFailed")
            case .indeterminate: runText("ComparisonIndeterminate")
            case .comparing: runText("Comparing")
            case .match: runText("OutputMatch")
            case .mismatch: runText("OutputMismatch")
        }
    }
}
