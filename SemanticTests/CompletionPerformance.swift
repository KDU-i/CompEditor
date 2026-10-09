// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import Foundation

@main struct CompletionPerformance {
    static func main() async throws {
        setbuf(stdout, nil)
        let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let output = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let delay = UInt64(CommandLine.arguments[3])!
        defer { LSPProcesses.shared.stopAll() }
        for language in LSPLanguage.allCases {
            let workspace = output.appendingPathComponent(language.rawValue)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let server = try LSPBundledServers.server(language, resources: app.appendingPathComponent("Contents/Resources"), storage: workspace.appendingPathComponent("storage"))
            let client = LSPClient()
            let start = DispatchTime.now().uptimeNanoseconds
            try await client.start(server, workspace: workspace)
            print("\(language.rawValue) initialize_ms=\(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6)")
            let text = language == .python ? "value = 'sample'\nvalue.low" : "public class Demo { void run() { String value = \"sample\"; value.subs } }"
            let marker = language == .python ? "value.low" : "value.subs"
            let caret = NSMaxRange((text as NSString).range(of: marker))
            let uri = workspace.appendingPathComponent("Demo.\(language.fileExtension)")
            try text.write(to: uri, atomically: true, encoding: .utf8)
            var times: [Double] = []
            for index in 0..<13 {
                let began = DispatchTime.now().uptimeNanoseconds
                try await Task.sleep(nanoseconds: delay * 1_000_000)
                let items = try await client.complete(uri: uri, language: language, text: text, caret: caret)
                guard !items.isEmpty else { throw LSPError.server("No measured candidates") }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds-began)/1e6
                if index == 0 { print("\(language.rawValue) first_completion_with_policy_ms=\(elapsed)") }
                else { times.append(elapsed) }
            }
            times.sort()
            print("\(language.rawValue) warm_12_same_snapshot_with_policy_ms median=\(times[6]) p95=\(times[11]) delay_ms=\(delay)")
            await client.stop()
        }
        LSPProcesses.shared.stopAll()
    }
}
