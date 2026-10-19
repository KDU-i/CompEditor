// SPDX-License-Identifier: Apache-2.0
import Foundation

nonisolated final class FakeLauncher: RunLaunching, @unchecked Sendable {
    var responses: [RunTermination]
    var commands: [RunCommand] = []
    var inputs: [Data] = []
    init(_ responses: [RunTermination]) { self.responses = responses }
    func execute(_ command: RunCommand, input: Data, interactive: Bool) -> RunTermination {
        commands.append(command); inputs.append(input); return responses.removeFirst()
    }
}
nonisolated final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var phases: [RunPhase] = []
    func append(_ phase: RunPhase) { lock.lock(); phases.append(phase); lock.unlock() }
}
@MainActor final class ClosedDocumentSession: RunOwnedSession {
    let activity: RunActivity
    init(_ activity: RunActivity) { self.activity = activity }
    func close() { activity.worker.stop() }
    func waitForStop() { activity.stopAndWait() }
}
@main struct RunCoreTests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("実行 tests " + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let py = ProcessInfo.processInfo.environment["RUN_TEST_PYTHON"] ?? "/usr/bin/python3"
        let home = ProcessInfo.processInfo.environment["RUN_TEST_JDK"] ?? "/usr/lib/jvm/java-21-openjdk-amd64"
        let url = root.appendingPathComponent("Main.java")
        let source = RunSource(url: url, revision: 4, text: "package p; public class Main { static class Inner {} } class Helper {}", diskBytes: Data(), modificationDate: nil)
        precondition(source.isCurrent(url: source.url, revision: 4, text: source.text, modificationDate: nil))
        precondition(!source.isCurrent(url: source.url, revision: 5, text: source.text, modificationDate: nil))
        precondition(!source.isCurrent(url: root.appendingPathComponent("Other.java"), revision: 4, text: source.text, modificationDate: nil))
        precondition(!source.isCurrent(url: source.url, revision: 4, text: source.text + "x", modificationDate: nil))
        precondition(!source.isCurrent(url: source.url, revision: 4, text: source.text, modificationDate: Date()))
        precondition(!source.isCurrent(url: source.url, revision: 4, text: source.text, modificationDate: nil, diskBytes: Data([1])))
        var decoder = RunUTF8Decoder()
        for byte in "日本語😀".utf8 { decoder.append(Data([byte])) }
        decoder.append(Data(), final: true)
        precondition(decoder.text == "日本語😀" && !decoder.hadError)
        decoder.append(Data([0xff]), final: true)
        precondition(decoder.hadError && decoder.text.hasSuffix("�"))
        var partial = RunUTF8Decoder(); partial.append(Data([0xf0, 0x9f])); partial.append(Data(), final: true)
        precondition(partial.hadError)
        var truncated = RunUTF8Decoder(); truncated.append(Data([0xf0, 0x9f])); truncated.append(Data(), final: true, truncated: true)
        precondition(!truncated.hadError)
        let candidates = RunPlanner.pythonCandidates(source: root.appendingPathComponent("a.py"), explicit: nil, exists: { _ in true })
        precondition(candidates == [root.appendingPathComponent(".venv/bin/python").path] + RunPlanner.knownPython)
        precondition(RunPlanner.pythonCandidates(source: url, explicit: "/broken", exists: { _ in false }).isEmpty)
        precondition(RunPlanner.pythonCandidates(source: url, explicit: "/selected", exists: { _ in true }) == ["/selected"])
        let env = RunPlanner.environment(["PATH":"/untrusted", "JAVA_TOOL_OPTIONS":"bad", "JDK_JAVAC_OPTIONS":"injected.java", "CLASSPATH":"bad", "PYTHONHOME":"bad"])
        precondition(env["JDK_JAVAC_OPTIONS"] == nil && env["JAVA_TOOL_OPTIONS"] == nil && env["CLASSPATH"] == nil && env["PYTHONHOME"] == nil && env["PYTHONIOENCODING"] == "utf-8")
        let lexical = JavaRunSource(#"""
        /* package fake; class Fake {} */
        package 実例;
        public class Main {
            String s = "package wrong; class Wrong {}";
            String t = """
                package textblock; class Nope {}
                """;
            class Inner {}
        }
        // class Comment {}
        class Helper {}
        """#)
        precondition(lexical.package == "実例" && lexical.classes == ["Main", "Helper"])
        precondition(lexical.defaultMain(filename: "Main") == "実例.Main")
        precondition(JavaRunSource("class Other {}").defaultMain(filename: "Missing").isEmpty)
        precondition(RunDiagnostics.parse("at p.Main$Inner.f(Main.java:1)\nat p.Helper.f(Main.java:1)\nat other.Main.f(Main.java:1)\n\(url.path):1: error", source: source).count == 3)
        precondition(RunDiagnostics.parse("File \"/unverified.py\", line 1", source: source).isEmpty)
        for separator in ["\r", "\r\n", "\n"] {
            let text = "一😀" + separator + "二" + separator
            let snapshot = RunSource(url: root.appendingPathComponent("lines.py"), revision: 1, text: text, diskBytes: Data(text.utf8), modificationDate: nil)
            let ranges = RunSourceLines.ranges(in: text)
            precondition(ranges.count == 3)
            precondition((text as NSString).substring(with: ranges[1]) == "二" + separator)
            precondition(ranges[2] == NSRange(location: text.utf16.count, length: 0))
            let error = "File \"\(snapshot.url.path)\", line 2\nFile \"\(snapshot.url.path)\", line 3\nFile \"\(snapshot.url.path)\", line 4"
            precondition(RunDiagnostics.parse(error, source: snapshot).map(\.line) == [2, 3])
        }
        precondition(RunSourceLines.ranges(in: "").count == 1)
        precondition(RunSourceLines.ranges(in: "a\rb").count == 2)
        let pythonSource = RunSource(url: root.appendingPathComponent("空 白.py"), revision: 5, text: "print(1)", diskBytes: Data(), modificationDate: nil)
        let plan = try RunPlanner.plan(source: pythonSource, python: py, jdk: nil, main: "", temporaryRoot: root)
        precondition(plan.execute.arguments == ["-u", pythonSource.url.path] && plan.execute.directory.path == root.path)
        precondition(plan.compile == nil && plan.ownedDirectory == nil)
        let command = plan.execute
        let javaPlan = RunPlan(compile: command, execute: command, ownedDirectory: nil)
        let failed = FakeLauncher([.exit(1)])
        let failPhases = PhaseRecorder()
        let failResult = RunPipeline.perform(javaPlan, input: Data("hello".utf8), interactive: false, launcher: failed, phase: { failPhases.append($0) })
        precondition(failPhases.phases == [.compiling])
        precondition(failResult.compilationFailed && failed.commands.count == 1 && failed.inputs == [Data()])
        let cancelled = FakeLauncher([.cancelled])
        precondition(RunPipeline.perform(javaPlan, input: Data(), interactive: false, launcher: cancelled, phase: { _ in }).termination == .cancelled)
        precondition(cancelled.commands.count == 1)
        let success = FakeLauncher([.exit(0), .exit(0)])
        let input = Data("日本語😀".utf8)
        let successPhases = PhaseRecorder()
        precondition(RunPipeline.perform(javaPlan, input: input, interactive: false, launcher: success, phase: { successPhases.append($0) }).termination.succeeded)
        precondition(successPhases.phases == [.compiling, .running])
        precondition(success.inputs == [Data(), input])
        var result = RunResult(id: UUID(), source: source)
        result.phase = .finished; result.termination = .exit(0)
        precondition(result.comparable)
        result.stdout.omitted = 1; precondition(!result.comparable)
        result.stdout.omitted = 0; result.stdout.decodingError = true; precondition(!result.comparable)
        result.stdout.decodingError = false; result.phase = .failed; precondition(!result.comparable)
        let pythonFixtures = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Scripts/Fixtures/Run/Python")
        try Data("relative 日本語😀".utf8).write(to: root.appendingPathComponent("fixture-data.txt"))
        for name in ["Echo", "Relative", "SyntaxError", "Exception"] {
            let file = root.appendingPathComponent(name + " 日本語.py")
            try fm.copyItem(at: pythonFixtures.appendingPathComponent(name + ".py"), to: file)
            let snapshot = RunSource(url: file, revision: 1, text: try String(contentsOf: file, encoding: .utf8), diskBytes: try Data(contentsOf: file), modificationDate: nil)
            let plan = try RunPlanner.plan(source: snapshot, python: py, jdk: nil, main: "", temporaryRoot: root, inherited: ["PATH": "/finder/no/interpreters"])
            let worker = RunWorker()!
            let outcome = RunPipeline.perform(plan, input: input, interactive: false, launcher: worker, phase: { _ in })
            let out = worker.output(0, finished: true), err = worker.output(1, finished: true)
            precondition(outcome.termination.succeeded == ["Echo", "Relative"].contains(name))
            if name == "Echo" { precondition(out.bytes == input && !err.text.isEmpty && !err.decodingError) }
            if name == "Relative" { precondition(out.text == "relative 日本語😀") }
            if name == "SyntaxError" || name == "Exception" { precondition(!RunDiagnostics.parse(err.text, source: snapshot).isEmpty) }
            print("PASS Python fixture: \(name)")
        }
        // Exercise Java argv isolation against a real JDK when one is available.
        if fm.isExecutableFile(atPath: home + "/bin/javac") {
            let java = try RunPlanner.plan(source: source, python: nil, jdk: home, main: "p.Helper", temporaryRoot: root)
            defer { if let owned = java.ownedDirectory { try? fm.removeItem(at: owned) } }
            precondition(java.execute.arguments.last == "p.Helper")
            let args = java.compile!.arguments
            precondition(args.contains("-proc:none") && args.contains("-implicit:none") && args.contains("-sourcepath") && args.contains("-classpath"))
            precondition(!args.contains(root.path))
            let fixtureRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Scripts/Fixtures/Run/Java")
            // A sibling source and an unrelated existing class must be preserved.
            try fm.copyItem(at: fixtureRoot.appendingPathComponent("External.java"), to: root.appendingPathComponent("External.java"))
            let existing = root.appendingPathComponent("unrelated.class")
            try Data("preserve".utf8).write(to: existing)
            let processorFile = root.appendingPathComponent("Processor.java")
            try fm.copyItem(at: fixtureRoot.appendingPathComponent("Processor.java"), to: processorFile)
            let processorSource = RunSource(url: processorFile, revision: 1, text: try String(contentsOf: processorFile, encoding: .utf8), diskBytes: try Data(contentsOf: processorFile), modificationDate: nil)
            let processorPlan = try RunPlanner.plan(source: processorSource, python: nil, jdk: home, main: "", temporaryRoot: root)
            let processorWorker = RunWorker()!
            precondition(processorWorker.execute(processorPlan.compile!, input: Data(), interactive: false).succeeded)
            try fm.copyItem(at: processorPlan.ownedDirectory!.appendingPathComponent("classes/Processor.class"), to: root.appendingPathComponent("Processor.class"))
            try fm.removeItem(at: processorPlan.ownedDirectory!)
            let services = root.appendingPathComponent("META-INF/services")
            try fm.createDirectory(at: services, withIntermediateDirectories: true)
            try Data("Processor".utf8).write(to: services.appendingPathComponent("javax.annotation.processing.Processor"))
            let fixtures: [(String, String, Bool, String?)] = [
                ("LocaleOutput", "", true, "ja-JP|10月"),
                ("Plain", "", true, "input😀"), ("Packaged", "", true, "helper:日本語😀"),
                ("Alternate", "Other", true, "other"), ("Mismatch", "", false, nil),
                ("NoMain", "", false, nil), ("ExceptionMain", "", false, nil),
                ("CompileError", "", false, nil), ("ExternalDependency", "", false, nil)
            ]
            for (name, main, succeeded, expected) in fixtures {
                let file = root.appendingPathComponent(name + ".java")
                try fm.copyItem(at: fixtureRoot.appendingPathComponent(name + ".java"), to: file)
                let snapshot = RunSource(url: file, revision: 1, text: try String(contentsOf: file, encoding: .utf8), diskBytes: try Data(contentsOf: file), modificationDate: nil)
                let fixturePlan = try RunPlanner.plan(source: snapshot, python: nil, jdk: home, main: main, temporaryRoot: root,
                    inherited: ["JAVA_TOOL_OPTIONS": "invalid-injection", "JDK_JAVAC_OPTIONS": "\"" + root.appendingPathComponent("External.java").path + "\"", "CLASSPATH": root.path])
                precondition(fixturePlan.compile!.arguments.contains("-J-Duser.language=en"))
                precondition(!fixturePlan.execute.arguments.contains(where: { $0.hasPrefix("-Duser.language=") || $0.hasPrefix("-Duser.country=") }))
                let japaneseCompile = RunCommand(executable: fixturePlan.compile!.executable,
                    arguments: ["-J-Duser.language=ja", "-J-Duser.country=JP"] + fixturePlan.compile!.arguments,
                    directory: fixturePlan.compile!.directory, environment: fixturePlan.compile!.environment)
                let japaneseExecute = RunCommand(executable: fixturePlan.execute.executable,
                    arguments: ["-Duser.language=ja", "-Duser.country=JP"] + fixturePlan.execute.arguments,
                    directory: fixturePlan.execute.directory, environment: fixturePlan.execute.environment)
                let localizedRuntimePlan = RunPlan(compile: japaneseCompile, execute: japaneseExecute, ownedDirectory: fixturePlan.ownedDirectory)
                let worker = RunWorker()!
                let outcome = RunPipeline.perform(localizedRuntimePlan, input: Data("input😀".utf8), interactive: false, launcher: worker, phase: { _ in })
                let out = worker.output(0, finished: true), err = worker.output(1, finished: true)
                precondition(outcome.termination.succeeded == succeeded, "\(name): \(err.text)")
                if let expected { precondition(out.text == expected, "\(name): \(out.text)") }
                if name == "Plain" { precondition(!err.text.isEmpty && outcome.termination.succeeded) }
                var fixtureResult = RunResult(id: UUID(), source: snapshot)
                fixtureResult.phase = outcome.termination.succeeded ? .finished : .failed
                fixtureResult.termination = outcome.termination; fixtureResult.compilationFailed = outcome.compilationFailed; fixtureResult.stderr = err
                if name == "Mismatch" { precondition(fixtureResult.failureKind == .javaFilename) }
                if name == "NoMain" {
                    precondition(err.text.contains("メイン・メソッド") && fixtureResult.failureKind == .javaMain)
                    for (language, country) in [("en", "US"), ("ja", "JP"), ("de", "DE"), ("zh", "CN")] {
                        let localized = RunCommand(executable: fixturePlan.execute.executable,
                            arguments: ["-Duser.language=" + language, "-Duser.country=" + country] + fixturePlan.execute.arguments,
                            directory: fixturePlan.execute.directory, environment: fixturePlan.execute.environment)
                        let localizedWorker = RunWorker()!
                        precondition(!localizedWorker.execute(localized, input: Data(), interactive: false).succeeded)
                        let originalError = localizedWorker.output(1, finished: true)
                        precondition(JavaLauncherDiagnostic.classify(originalError.text) == .javaMain, "\(language): \(originalError.text)")
                        precondition(originalError.bytes == Data(originalError.text.utf8), "launcher diagnostics were rewritten")
                        let missing = RunCommand(executable: localized.executable, arguments: Array(localized.arguments.dropLast()) + ["NoSuchFixtureClass"], directory: localized.directory, environment: localized.environment)
                        let missingWorker = RunWorker()!
                        precondition(!missingWorker.execute(missing, input: Data(), interactive: false).succeeded)
                        precondition(JavaLauncherDiagnostic.classify(missingWorker.output(1, finished: true).text) == .launch)
                    }
                }
                if name == "LocaleOutput" {
                    let direct = RunCommand(executable: fixturePlan.execute.executable,
                        arguments: ["-Duser.language=ja", "-Duser.country=JP", "-Dfile.encoding=UTF-8", "-cp", fixturePlan.ownedDirectory!.appendingPathComponent("classes").path, "LocaleOutput"],
                        directory: fixturePlan.execute.directory, environment: fixturePlan.execute.environment)
                    let directWorker = RunWorker()!
                    precondition(directWorker.execute(direct, input: Data(), interactive: false).succeeded)
                    precondition(out.bytes == directWorker.output(0, finished: true).bytes && out.text == "ja-JP|10月", "planned execution changed program locale/output")
                }
                if name == "ExternalDependency" { precondition(fixtureResult.failureKind == .javaDependency) }
                if ["Mismatch", "CompileError", "ExternalDependency"].contains(name) { precondition(outcome.compilationFailed) }
                if ["NoMain", "ExceptionMain"].contains(name) { precondition(!outcome.compilationFailed && !err.text.isEmpty) }
                if name == "ExceptionMain" { precondition(!RunDiagnostics.parse(err.text, source: snapshot).isEmpty) }
                precondition(!fm.fileExists(atPath: root.appendingPathComponent("processor-ran").path))
                if name == "Plain" {
                    let oldClass = root.appendingPathComponent("Plain.class")
                    try fm.copyItem(at: fixturePlan.ownedDirectory!.appendingPathComponent("classes/Plain.class"), to: oldClass)
                    let oldBytes = try Data(contentsOf: oldClass)
                    let invalid = "public class Plain { invalid }"
                    try invalid.write(to: file, atomically: true, encoding: .utf8)
                    let badSource = RunSource(url: file, revision: 2, text: invalid, diskBytes: Data(invalid.utf8), modificationDate: nil)
                    let nextPlan = try RunPlanner.plan(source: badSource, python: nil, jdk: home, main: "", temporaryRoot: root)
                    precondition(nextPlan.ownedDirectory != fixturePlan.ownedDirectory)
                    let nextWorker = RunWorker()!
                    let failed = RunPipeline.perform(nextPlan, input: Data(), interactive: false, launcher: nextWorker, phase: { _ in })
                    precondition(failed.compilationFailed && !failed.termination.succeeded && nextWorker.output(0, finished: true).bytes.isEmpty)
                    let preservedClass = try Data(contentsOf: oldClass)
                    precondition(preservedClass == oldBytes)
                    try fm.removeItem(at: nextPlan.ownedDirectory!)
                }
                if let owned = fixturePlan.ownedDirectory { try fm.removeItem(at: owned) }
                let preserved = try Data(contentsOf: existing)
                precondition(preserved == Data("preserve".utf8))
                print("PASS Java fixture: \(name)")
            }
        } else { print("SKIP Java plan executable checks: set RUN_TEST_JDK to an installed JDK") }
        let cleanup = root.appendingPathComponent("closed-document-output")
        try fm.createDirectory(at: cleanup, withIntermediateDirectories: true)
        try Data("owned".utf8).write(to: cleanup.appendingPathComponent("marker"))
        let cleanupWorker = RunWorker()!
        let activity = RunActivity(worker: cleanupWorker, ownedDirectory: cleanup)
        let registry = RunSessionRegistry()
        var closed: ClosedDocumentSession? = ClosedDocumentSession(activity)
        weak var retainedSession = closed
        _ = registry.retain(closed!)
        let fixture = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Scripts/Fixtures/Run/process.py")
        let commandForClose = RunCommand(executable: URL(fileURLWithPath: py), arguments: ["-u", fixture.path, "ignore-term"], directory: root, environment: RunPlanner.environment([:]))
        DispatchQueue.global().async {
            _ = cleanupWorker.execute(commandForClose, input: Data(), interactive: true)
            activity.finish()
        }
        let readyDeadline = Date().addingTimeInterval(3)
        while cleanupWorker.output(0, finished: false).bytes.isEmpty && Date() < readyDeadline { Thread.sleep(forTimeInterval: 0.01) }
        precondition(!cleanupWorker.output(0, finished: false).bytes.isEmpty)
        closed!.close(); closed = nil
        precondition(retainedSession != nil, "closed document's stopping session lost ownership")
        registry.shutdown()
        precondition(!fm.fileExists(atPath: cleanup.path), "quit returned before owned-directory cleanup")
        precondition(retainedSession == nil, "completed closed-document session was retained")
        print("PASS ownership: closed document retained through Stop/KILL and background cleanup at quit")
        print("PASS RunCore: runtime precedence, argv/cwd/environment, Java lexical masking, diagnostics, fake pipeline, result completeness")
    }
}
