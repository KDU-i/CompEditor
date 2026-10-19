// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

struct RunPaneView: View {
    @Bindable var session: RunSession
    let editor: () -> EditorTextView?
    let close: () -> Void
    @State private var outputTab = 0
    var body: some View {
        let stale = session.stale
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(runText("Run"), systemImage: "play.fill") { session.run() }.disabled(session.active)
                    Button(runText("Stop"), systemImage: "stop.fill") { session.stop() }.disabled(!session.active)
                    Spacer()
                    Text(status).font(.callout).textSelection(.enabled)
                    Button(action: close) { Image(systemName: "xmark") }.help(runText("HideResults")).accessibilityLabel(runText("HideResults"))
                }
                if !session.message.isEmpty { Text(session.message).font(.callout).textSelection(.enabled) }
                if let result = session.result {
                    Text(result.source.url.path).lineLimit(1).truncationMode(.middle).help(result.source.url.path)
                    LabeledContent(runText("Directory")) { Text(result.source.directory.path).lineLimit(1).truncationMode(.middle).help(result.source.directory.path).textSelection(.enabled) }
                    LabeledContent(runText("Runtime")) { Text(result.runtime).lineLimit(1).truncationMode(.middle).help(result.runtime).textSelection(.enabled) }
                    if let failure = result.failureKind { Text(failureExplanation(failure)).font(.callout).textSelection(.enabled) }
                    if stale { Label(runText("SourceChanged"), systemImage: "exclamationmark.triangle") }
                }
                DisclosureGroup(runText("RuntimeSettings")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(runText("ChoosePython")) { session.selectRuntime(python: true) }
                        Text(session.pythonPath.isEmpty ? runText("PythonUnconfigured") : session.pythonPath).textSelection(.enabled)
                        Button(runText("ChooseJDK")) { session.selectRuntime(python: false) }
                        Text(session.jdkHome.isEmpty ? runText("BundledJDK") : session.jdkHome).textSelection(.enabled)
                        TextField(runText("MainClass"), text: $session.mainClass)
                            .help(runText("MainClassHelp"))
                    }.disabled(session.active)
                }
                Toggle(runText("Interactive"), isOn: $session.interactive).disabled(session.active)
                Text(runText("Stdin")).font(.headline)
                TextEditor(text: $session.input).font(.system(.body, design: .monospaced))
                    .frame(height: 65).border(Color(nsColor: .separatorColor)).accessibilityLabel(runText("Stdin"))
                    .disabled(session.active && !session.inputOpen)
                if session.interactive {
                    HStack {
                        Button(runText("Send")) { session.send() }.disabled(!session.inputOpen || session.result?.phase != .running)
                        Button(runText("EOF")) { session.eof() }.disabled(!session.inputOpen)
                        Text(session.inputOpen ? runText("InputOpen") : runText("InputClosed"))
                    }
                    Text(runText("SendHelp")).font(.caption)
                } else { Text(runText("SnapshotInputHelp")).font(.caption) }
                Picker(runText("Output"), selection: $outputTab) {
                    Text(runText("Stdout")).tag(0); Text(runText("Stderr")).tag(1)
                }.pickerStyle(.segmented)
                let output = outputTab == 0 ? session.result?.stdout : session.result?.stderr
                RunOutputText(text: output?.text ?? "", label: runText(outputTab == 0 ? "Stdout" : "Stderr"))
                    .frame(height: 160)
                if let output, output.omitted > 0 {
                    Text(runText("OutputOmitted") + " \(output.omitted) bytes").font(.callout)
                }
                if output?.decodingError == true { Label(runText("DecodeError"), systemImage: "exclamationmark.triangle") }
                if session.result != nil {
                    let diagnostics = session.diagnostics
                    if !diagnostics.isEmpty {
                        HStack { Text(runText("ErrorLocations")).font(.headline); Spacer(); Button(runText("Back")) { session.back(view: editor()) } }
                        Text(runText("LocationsLimit")).font(.caption)
                        ForEach(diagnostics) { diagnostic in
                            Button { session.navigate(diagnostic, view: editor()) } label: {
                                Text("\(diagnostic.line): " + diagnostic.message).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            }.disabled(stale)
                        }
                    }
                }
                DisclosureGroup(runText("Help")) { Text(runText("HelpBody")).textSelection(.enabled) }
            }.padding(12)
        }.background(.background).font(.system(size: NSFont.systemFontSize))
    }
    private func failureExplanation(_ kind: RunFailureKind) -> String {
        switch kind {
            case .launch: runText("LaunchExplanation")
            case .javaFilename: runText("JavaFilenameExplanation")
            case .javaDependency: runText("JavaDependencyExplanation")
            case .javaCompile: runText("JavaCompileExplanation")
            case .javaMain: runText("JavaMainExplanation")
            case .javaRuntime: runText("JavaRuntimeExplanation")
            case .program: runText("ProgramExplanation")
        }
    }
    private var status: String {
        guard let result = session.result else { return session.active ? runText("Preparing") : runText("Idle") }
        switch result.phase {
            case .preparing: return runText("Preparing")
            case .compiling: return runText("Compiling")
            case .running: return runText("Running")
            case .stopping: return runText("Stopping")
            case .cancelled: return runText("Cancelled")
            default:
                if result.compilationFailed { return runText("CompileFailed") + termination(result.termination) }
                return termination(result.termination)
        }
    }
    private func termination(_ termination: RunTermination?) -> String {
        switch termination {
            case .exit(let code): runText("ExitCode") + " \(code)"
            case .signal(let signal): runText("Signal") + " \(signal)"
            case .launchFailure(let code): runText("LaunchFailed") + " (errno \(code))"
            case .cancelled: runText("Cancelled")
            case nil: runText("Idle")
        }
    }
}

private struct RunOutputText: NSViewRepresentable {
    let text: String
    let label: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false; view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        view.setAccessibilityLabel(label); scroll.borderType = .bezelBorder
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        if view.string != text { view.string = text }
        view.setAccessibilityLabel(label)
    }
}

@MainActor final class RunActions: NSObject, NSMenuItemValidation, NSToolbarItemValidation {
    static let shared = RunActions()
    private var controller: DocumentWindowController? { NSApp.mainWindow?.windowController as? DocumentWindowController }
    private var session: RunSession? { (controller?.fileDocument as? Document)?.runSession }
    func installMenu() {
        let menu = NSMenu(title: runText("Run"))
        for (key, selector, shortcut) in [("Run", #selector(runSource(_:)), "r"), ("Stop", #selector(stopSource(_:)), "."), ("ShowResults", #selector(showResults(_:)), "")] {
            let item = NSMenuItem(title: runText(String.LocalizationValue(key)), action: selector, keyEquivalent: shortcut)
            item.target = self; item.keyEquivalentModifierMask = [.command]; menu.addItem(item)
        }
        let root = NSMenuItem(title: runText("Run"), action: nil, keyEquivalent: ""); root.submenu = menu
        NSApp.mainMenu?.addItem(root)
    }
    @objc func runSource(_ sender: Any?) { showResults(sender); session?.run() }
    @objc func stopSource(_ sender: Any?) { session?.stop() }
    @objc func showResults(_ sender: Any?) {
        let content = (controller?.window?.contentViewController as? WindowContentViewController)?.documentViewController?.parent as? ContentViewController
        content?.showRunPane()
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(stopSource(_:)) { return session?.active == true }
        if item.action == #selector(runSource(_:)) { return session != nil && session?.active == false }
        return session != nil
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.action == #selector(stopSource(_:)) { return session?.active == true }
        return session != nil && session?.active == false
    }
    func shutdown() {
        RunSessionRegistry.shared.shutdown()
    }
}
