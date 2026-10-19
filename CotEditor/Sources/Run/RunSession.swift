// SPDX-License-Identifier: Apache-2.0
import AppKit
import Observation
import FileEncoding

func runText(_ key: String.LocalizationValue) -> String { String(localized: key, table: "Run") }

@MainActor @Observable final class RunSession: NSObject, RunOwnedSession {
    weak var document: Document?
    var result: RunResult?
    var diagnostics: [RunDiagnostic] = []
    var input = ""
    var interactive = false
    var mainClass = ""
    var message = ""
    var inputOpen = false
    var revision: UInt64 = 0
    var active = false {
        didSet {
            guard active != oldValue else { return }
            RunActions.shared.revalidateToolbars(for: document)
        }
    }
    private var worker: RunWorker?
    private var activity: RunActivity?
    private var ownedDirectory: URL?
    private var inspectingRuntime = false
    private var eofSent = false
    private var cancelled = false
    private var preparingWithSheet = false
    private var refresh: Task<Void, Never>?
    private var editObserver: NSObjectProtocol?
    private var oldSelection: (NSRange, UInt64)?
    var pythonPath: String {
        get { UserDefaults.standard.string(forKey: "RunPythonInterpreter") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "RunPythonInterpreter") }
    }
    var jdkHome: String {
        get { UserDefaults.standard.string(forKey: "RunJDKHome") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "RunJDKHome") }
    }
    init(document: Document) {
        self.document = document
        super.init()
        editObserver = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: document.textStorage, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
                self?.revision &+= 1
            }
        }
    }
    isolated deinit { if let editObserver { NotificationCenter.default.removeObserver(editObserver) }; refresh?.cancel() }
    var stale: Bool {
        guard let result, let document else { return true }
        guard let bytes = try? Data(contentsOf: result.source.url) else { return true }
        let date = try? result.source.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return !result.source.isCurrent(url: document.fileURL, revision: revision, text: document.textStorage.string, modificationDate: date, diskBytes: bytes)
    }
    func run() {
        guard !active, let document, !document.semanticIsClosed else { return }
        if let url = document.fileURL, !["py", "java"].contains(url.pathExtension.lowercased()) { message = runText("Unsupported"); return }
        if document.fileURL?.pathExtension.lowercased() == "java", document.fileEncoding.encoding != .utf8 { message = runText("JavaUTF8"); return }
        cancelled = false; eofSent = false
        active = true; result = nil; diagnostics = []; message = runText("Preparing"); oldSelection = nil
        // Stop is already valid while the standard save sheet is open.
        if document.isDocumentEdited || document.fileURL == nil {
            preparingWithSheet = true
            document.save(withDelegate: self, didSave: #selector(saved(_:didSave:contextInfo:)), contextInfo: nil)
        } else { prepare() }
    }
    @objc private func saved(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        preparingWithSheet = false
        guard active, !cancelled else { active = false; return }
        guard didSave else { active = false; message = runText("SaveCancelled"); return }
        prepare()
    }
    func stop() {
        guard active else { return }
        cancelled = true
        if worker == nil {
            if !preparingWithSheet { active = false }
            message = runText("Cancelled"); return
        }
        if !inspectingRuntime { result?.phase = .stopping }
        inputOpen = false; worker?.stop()
    }
    func close() { stop(); worker?.stop() }
    func waitForStop() {
        activity?.stopAndWait()
    }
    func send() {
        guard inputOpen, result?.phase == .running else { return }
        worker?.send(Data((input + "\n").utf8)); input = ""
    }
    func eof() { guard inputOpen, !eofSent else { return }; eofSent = true; inputOpen = false; worker?.eof() }
    private func prepare() {
        guard active, let document, !document.semanticIsClosed, let url = document.fileURL else { active = false; return }
        guard ["py", "java"].contains(url.pathExtension.lowercased()) else { fail("Unsupported"); return }
        guard url.pathExtension.lowercased() != "java" || document.fileEncoding.encoding == .utf8 else { fail("JavaUTF8"); return }
        do {
            let bytes = try Data(contentsOf: url)
            guard !document.isDocumentEdited, document.runSavedBytesMatch(bytes) else { fail("SourceChangedBeforeRun"); return }
            let source = RunSource(url: url, revision: revision, text: document.textStorage.string, diskBytes: bytes, modificationDate: try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            if url.pathExtension.lowercased() == "py" && pythonPath.isEmpty {
                choosePython(source: url)
                // Runtime selection is explicit; continuing from the completed
                // sheet re-saves/re-snapshots if the source changed meanwhile.
                return
            }
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("SemanticServers/jdk").path
            let plan = try RunPlanner.plan(source: source, python: pythonPath, jdk: jdkHome.isEmpty ? bundled : jdkHome, main: mainClass, temporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent("CompEditorRun"))
            ownedDirectory = plan.ownedDirectory
            guard let worker = RunWorker() else { throw CocoaError(.fileReadUnknown) }
            self.worker = worker
            let activity = RunActivity(worker: worker, ownedDirectory: plan.ownedDirectory)
            self.activity = activity
            let ownership = RunSessionRegistry.shared.retain(self)
            let id = UUID(), initial = Data(input.utf8), interactive = interactive
            result = RunResult(id: id, source: source, runtime: plan.execute.executable.path)
            message = ""
            refresh = Task { [weak self, worker] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, self.result?.id == id, self.active else { return }
                    self.inputOpen = self.interactive && !self.eofSent && self.result?.phase == .running && worker.acceptsInput
                    self.result?.stdout = worker.output(0, finished: false)
                    self.result?.stderr = worker.output(1, finished: false)
                }
            }
            let session = self
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = RunPipeline.perform(plan, input: initial, interactive: interactive, launcher: worker) { phase in
                    Task { @MainActor in
                        if session.active && session.result?.id == id && session.result?.phase != .stopping { session.result?.phase = phase }
                    }
                }
                activity.finish()
                let finalTermination = outcome.termination, finalCompileFailed = outcome.compilationFailed
                Task { @MainActor in
                    RunSessionRegistry.shared.release(ownership)
                    guard session.result?.id == id else { return }
                    let stopped = session.result?.phase == .stopping || finalTermination == .cancelled
                    session.result?.stdout = worker.output(0, finished: true)
                    session.result?.stderr = worker.output(1, finished: true)
                    session.diagnostics = RunDiagnostics.parse(session.result?.stderr.text ?? "", source: source)
                    session.result?.termination = stopped ? .cancelled : finalTermination
                    session.result?.compilationFailed = finalCompileFailed
                    session.result?.phase = stopped ? .cancelled : (finalTermination.succeeded ? .finished : .failed)
                    session.active = false; session.inputOpen = false; session.refresh?.cancel(); session.worker = nil; session.activity = nil; session.ownedDirectory = nil
                }
            }
        } catch RunPlanningError.invalidMain { fail("InvalidMain") }
        catch RunPlanningError.missingRuntime { fail("MissingRuntime") }
        catch { fail("PreparationFailed") }
    }
    private func fail(_ key: String.LocalizationValue) {
        if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory); self.ownedDirectory = nil }
        active = false; message = runText(key)
    }
    func choosePython(source: URL? = nil) {
        guard let window = document?.windowControllers.first?.window else { active = false; return }
        let candidates = source.map { RunPlanner.pythonCandidates(source: $0, explicit: nil) } ?? []
        let alert = NSAlert()
        alert.messageText = runText("ChoosePython")
        alert.informativeText = runText("PythonGuidance") + "\n" + candidates.joined(separator: "\n")
        if let first = candidates.first { alert.addButton(withTitle: runText("UseCandidate") + " “" + first + "”") }
        alert.addButton(withTitle: runText("ChooseExisting")); alert.addButton(withTitle: runText("Cancel"))
        preparingWithSheet = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.preparingWithSheet = false
            guard !self.cancelled, self.document?.semanticIsClosed == false else { self.active = false; return }
            let offset = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if !candidates.isEmpty && offset == 0 { self.active = false; self.inspectRuntime(path: candidates[0], python: true); return }
            if offset == (candidates.isEmpty ? 0 : 1) { self.active = false; self.selectRuntime(python: true) }
            else { self.active = false; self.message = runText("Cancelled") }
        }
    }
    func selectRuntime(python: Bool) {
        guard !active, let window = document?.windowControllers.first?.window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = !python; panel.canChooseFiles = python
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false; panel.message = runText(python ? "ChoosePython" : "ChooseJDK")
        cancelled = false; active = true; preparingWithSheet = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.preparingWithSheet = false; self.active = false
            guard !self.cancelled, self.document?.semanticIsClosed == false, response == .OK, let path = panel.url?.path else { return }
            self.inspectRuntime(path: path, python: python)
        }
    }
    private func inspectRuntime(path: String, python: Bool) {
        // Execute only the candidate the user just explicitly selected. Inspection
        // has a timeout and the same owned-process cleanup as a normal run.
        guard let document, let window = document.windowControllers.first?.window, let worker = RunWorker() else { return }
        let executable = python ? path : URL(fileURLWithPath: path).appendingPathComponent("bin/java").path
        let command = RunCommand(executable: URL(fileURLWithPath: executable), arguments: [python ? "--version" : "-version"], directory: URL(fileURLWithPath: NSTemporaryDirectory()), environment: RunPlanner.environment(ProcessInfo.processInfo.environment))
        cancelled = false; inspectingRuntime = true; active = true; self.worker = worker; message = runText("CheckingRuntime")
        let activity = RunActivity(worker: worker)
        self.activity = activity
        let ownership = RunSessionRegistry.shared.retain(self)
        DispatchQueue.global().async {
            let timeout = DispatchWorkItem { worker.stop() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
            var status = worker.execute(command, input: Data(), interactive: false)
            if status.succeeded && !python {
                let javac = RunCommand(executable: URL(fileURLWithPath: path).appendingPathComponent("bin/javac"), arguments: ["-version"], directory: command.directory, environment: command.environment)
                status = worker.execute(javac, input: Data(), interactive: false)
            }
            timeout.cancel()
            let finalStatus = status
            let text = worker.output(0, finished: true).text + worker.output(1, finished: true).text
            activity.finish()
            Task { @MainActor [weak self] in
                RunSessionRegistry.shared.release(ownership)
                guard let self else { return }
                let cancelled = self.cancelled
                self.active = false; self.worker = nil; self.activity = nil; self.inspectingRuntime = false
                guard finalStatus.succeeded, (!python || text.hasPrefix("Python 3.")), !cancelled, !document.semanticIsClosed else { self.message = runText("MissingRuntime"); return }
                let alert = NSAlert(); alert.messageText = runText("ConfirmRuntime"); alert.informativeText = path + "\n" + String(text.prefix(2048))
                alert.addButton(withTitle: runText("UseRuntime")); alert.addButton(withTitle: runText("Cancel"))
                self.active = true; self.preparingWithSheet = true
                alert.beginSheetModal(for: window) { response in
                    self.preparingWithSheet = false; self.active = false
                    guard !self.cancelled, !document.semanticIsClosed, response == .alertFirstButtonReturn else { return }
                    if python { self.pythonPath = path } else { self.jdkHome = path }
                    self.run()
                }
            }
        }
    }
    func navigate(_ diagnostic: RunDiagnostic, view: EditorTextView?) {
        guard !stale, let view, let result,
              (try? Data(contentsOf: result.source.url)) == result.source.diskBytes else { return }
        let lines = RunSourceLines.ranges(in: result.source.text)
        guard lines.indices.contains(diagnostic.line - 1) else { return }
        oldSelection = (view.selectedRange(), revision)
        let range = lines[diagnostic.line - 1]
        view.setSelectedRange(range); view.scrollRangeToVisible(range); view.window?.makeFirstResponder(view)
    }
    func back(view: EditorTextView?) {
        guard let (range, revision) = oldSelection, revision == self.revision, let view, NSMaxRange(range) <= view.string.utf16.count else { return }
        view.setSelectedRange(range); view.scrollRangeToVisible(range); view.window?.makeFirstResponder(view); oldSelection = nil
    }
}
