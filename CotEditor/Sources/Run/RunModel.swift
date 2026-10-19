// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Reusable by expected-output comparison (#9). Incomplete/undecodable output
/// and anything except successful execution must never qualify as a match.
enum RunPhase: String, Sendable { case idle, preparing, compiling, running, stopping, finished, failed, cancelled }
enum RunTermination: Equatable, Sendable {
    case exit(Int32), signal(Int32), launchFailure(Int32), cancelled
    var succeeded: Bool { self == .exit(0) }
}
struct RunSource: Sendable {
    let url: URL
    let revision: UInt64
    let text: String
    let diskBytes: Data
    let modificationDate: Date?
    var directory: URL { url.deletingLastPathComponent() }
    func isCurrent(url: URL?, revision: UInt64, text: String, modificationDate: Date?, diskBytes: Data? = nil) -> Bool {
        self.url == url && self.revision == revision && self.text == text && self.modificationDate == modificationDate && (diskBytes == nil || self.diskBytes == diskBytes)
    }
}
struct RunOutput: Sendable {
    var bytes = Data()
    var omitted = 0
    var decodingError = false
    var rendered: String?
    var text: String { rendered ?? String(decoding: bytes, as: UTF8.self) }
    var complete: Bool { omitted == 0 && !decodingError }
}
struct RunResult: Sendable {
    let id: UUID
    let source: RunSource
    var phase: RunPhase = .preparing
    var runtime = ""
    var stdout = RunOutput()
    var stderr = RunOutput()
    var termination: RunTermination?
    var compilationFailed = false
    var failureKind: RunFailureKind? {
        guard phase == .failed else { return nil }
        if case .launchFailure = termination { return .launch }
        if source.url.pathExtension.lowercased() == "java" {
            let error = stderr.text
            if compilationFailed {
                if error.contains("should be declared in a file named") { return .javaFilename }
                if error.contains("does not exist") || error.contains("cannot find symbol") { return .javaDependency }
                return .javaCompile
            }
            if error.contains("Main method not found") || error.contains("Main method is not static") || error.contains("Main method must return") { return .javaMain }
            if error.contains("Could not find or load main class") || error.contains("Could not create the Java Virtual Machine") { return .launch }
            return .javaRuntime
        }
        return .program
    }
    var comparable: Bool { phase == .finished && termination?.succeeded == true && stdout.complete && stderr.complete }
}
struct RunCommand: Sendable {
    let executable: URL
    let arguments: [String]
    let directory: URL
    let environment: [String: String]
}
struct RunPlan: Sendable {
    let compile: RunCommand?
    let execute: RunCommand
    let ownedDirectory: URL?
}
enum RunPlanningError: Error { case missingRuntime, invalidMain, unsupportedSource }

nonisolated enum RunPlanner {
    // Never inspect ancestors, shell profiles, or inherited PATH.
    static let knownPython = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
    static func pythonCandidates(source: URL, explicit: String?, exists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> [String] {
        if let explicit, !explicit.isEmpty { return exists(explicit) ? [explicit] : [] }
        return ([source.deletingLastPathComponent().appendingPathComponent(".venv/bin/python").path] + knownPython).filter(exists)
    }
    static func environment(_ inherited: [String: String]) -> [String: String] {
        var env = inherited
        for key in ["JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS", "CLASSPATH", "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP"] { env[key] = nil }
        env["PYTHONIOENCODING"] = "utf-8"; env["PYTHONUTF8"] = "1"
        // Finder may supply no locale. A UTF-8 fallback also preserves Unicode
        // filesystem arguments when exercising the portable runner on Linux.
        #if os(macOS)
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        #else
        if env["LANG"] == nil { env["LANG"] = "C.UTF-8" }
        #endif
        return env
    }
    static func plan(source: RunSource, python: String?, jdk: String?, main: String, temporaryRoot: URL,
                     inherited: [String: String] = ProcessInfo.processInfo.environment) throws -> RunPlan {
        let env = environment(inherited)
        if source.url.pathExtension.lowercased() == "py" {
            guard let python, python.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: python) else { throw RunPlanningError.missingRuntime }
            return RunPlan(compile: nil, execute: RunCommand(executable: URL(fileURLWithPath: python), arguments: ["-u", source.url.path], directory: source.directory, environment: env), ownedDirectory: nil)
        }
        guard source.url.pathExtension.lowercased() == "java" else { throw RunPlanningError.unsupportedSource }
        guard let jdk, jdk.hasPrefix("/") else { throw RunPlanningError.missingRuntime }
        let home = URL(fileURLWithPath: jdk).resolvingSymlinksInPath()
        let javac = home.appendingPathComponent("bin/javac"), java = home.appendingPathComponent("bin/java")
        guard [javac, java].allSatisfy({ FileManager.default.isExecutableFile(atPath: $0.path) && $0.resolvingSymlinksInPath().path.hasPrefix(home.path + "/") }) else { throw RunPlanningError.missingRuntime }
        let info = JavaRunSource(source.text)
        let name = main.isEmpty ? info.defaultMain(filename: source.url.deletingPathExtension().lastPathComponent) : main
        guard info.mainNames.contains(name) else { throw RunPlanningError.invalidMain }
        let owned = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let classes = owned.appendingPathComponent("classes"), empty = owned.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: classes, withIntermediateDirectories: true)
        do { try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true) }
        catch { try? FileManager.default.removeItem(at: owned); throw error }
        return RunPlan(compile: RunCommand(executable: javac, arguments: ["-encoding", "UTF-8", "-proc:none", "-implicit:none", "-sourcepath", empty.path, "-classpath", classes.path, "-d", classes.path, source.url.path], directory: source.directory, environment: env), execute: RunCommand(executable: java, arguments: ["-Dfile.encoding=UTF-8", "-cp", classes.path, name], directory: source.directory, environment: env), ownedDirectory: owned)
    }
}

/// Lexical masking, not a Java compiler. Comments, strings, chars and text blocks
/// cannot invent package/class declarations. Ambiguous input requires correction.
nonisolated struct JavaRunSource {
    let package: String
    let classes: [String]
    let publicClasses: [String]
    var mainNames: [String] { classes.map { package.isEmpty ? $0 : package + "." + $0 } }
    init(_ source: String) {
        let pattern = #"(?s)/\*.*?\*/|//[^\r\n]*|\"\"\".*?\"\"\"|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let masked = regex.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source), withTemplate: " ")
        let tokens = masked.matches(of: /[\p{L}_$][\p{L}\p{N}_$]*|[{}.;]/).map { String($0.output) }
        var package = "", classes: [String] = [], publicClasses: [String] = [], depth = 0, i = 0, isPublic = false
        while i < tokens.count {
            let t = tokens[i]
            if depth == 0 && t == "public" { isPublic = true }
            if t == "{" { depth += 1; isPublic = false }; if t == "}" { depth -= 1 }
            if depth == 0 && t == ";" { isPublic = false }
            if depth == 0 && t == "package" {
                var parts: [String] = []; i += 1
                while i < tokens.count && tokens[i] != ";" { parts.append(tokens[i]); i += 1 }
                package = parts.joined()
            } else if depth == 0 && t == "class" && i + 1 < tokens.count && (i == 0 || tokens[i - 1] != ".") {
                classes.append(tokens[i + 1])
                if isPublic { publicClasses.append(tokens[i + 1]) }
            }
            i += 1
        }
        self.package = package; self.classes = classes; self.publicClasses = publicClasses
    }
    func defaultMain(filename: String) -> String {
        let name = classes.contains(filename) ? filename : (publicClasses.count == 1 ? publicClasses[0] : "")
        guard !name.isEmpty else { return "" }
        return package.isEmpty ? name : package + "." + name
    }
}

struct RunDiagnostic: Identifiable {
    let id = UUID()
    let line: Int
    let message: String
}
nonisolated enum RunDiagnostics {
    static func parse(_ stderr: String, source: RunSource) -> [RunDiagnostic] {
        let java = JavaRunSource(source.text)
        let maximumLine = source.text.components(separatedBy: "\n").count
        var found: [RunDiagnostic] = []
        for message in stderr.components(separatedBy: .newlines) {
            if found.count >= 200 { break }
            var number: Int?
            if let m = message.firstMatch(of: /File "([^"]+)", line ([0-9]+)/),
               URL(fileURLWithPath: String(m.1)).standardizedFileURL == source.url.standardizedFileURL { number = Int(m.2) }
            if message.hasPrefix(source.url.path + ":") {
                number = Int(message.dropFirst(source.url.path.count + 1).prefix(while: \.isNumber))
            }
            if let m = message.firstMatch(of: /\bat ([\p{L}\p{N}_.$]+)\([^():]+\.java:([0-9]+)\)/) {
                let frame = String(m.1)
                let filename = "(" + source.url.lastPathComponent + ":"
                if message.contains(filename), java.mainNames.contains(where: { frame.hasPrefix($0 + ".") || frame.hasPrefix($0 + "$") }) { number = Int(m.2) }
            }
            guard let line = number, line > 0, line <= maximumLine else { continue }
            found.append(RunDiagnostic(line: line, message: message))
        }
        return found
    }
}

nonisolated protocol RunLaunching: Sendable {
    func execute(_ command: RunCommand, input: Data, interactive: Bool) -> RunTermination
}
struct RunPipelineOutcome: Sendable {
    let termination: RunTermination
    let compilationFailed: Bool
}
nonisolated enum RunPipeline {
    static func perform(_ plan: RunPlan, input: Data, interactive: Bool, launcher: any RunLaunching,
                        phase: @Sendable (RunPhase) -> Void) -> RunPipelineOutcome {
        if let compile = plan.compile {
            phase(.compiling)
            let termination = launcher.execute(compile, input: Data(), interactive: false)
            if !termination.succeeded { return RunPipelineOutcome(termination: termination, compilationFailed: true) }
        }
        phase(.running)
        return RunPipelineOutcome(termination: launcher.execute(plan.execute, input: input, interactive: interactive), compilationFailed: false)
    }
}

/// Incremental UTF-8 reconstruction. Hold only a potentially valid trailing
/// partial scalar; malformed bytes elsewhere are replaced and flagged.
struct RunUTF8Decoder: Sendable {
    private var pending = Data()
    private(set) var text = ""
    private(set) var hadError = false
    mutating func append(_ data: Data, final: Bool = false, truncated: Bool = false) {
        pending.append(data)
        var held = 0
        if !final || truncated {
            let bytes = Array(pending.suffix(4))
            if let start = bytes.lastIndex(where: { $0 & 0xc0 != 0x80 }) {
                let first = bytes[start]
                let expected = (0xc2...0xdf).contains(first) ? 2 : ((0xe0...0xef).contains(first) ? 3 : ((0xf0...0xf4).contains(first) ? 4 : 1))
                let count = bytes.count - start
                if count < expected { held = count }
            }
        }
        let complete = pending.dropLast(held)
        if String(data: complete, encoding: .utf8) == nil { hadError = true }
        text += String(decoding: complete, as: UTF8.self)
        pending = Data(pending.suffix(held))
    }
}

enum RunFailureKind: Sendable {
    case launch, javaFilename, javaDependency, javaCompile, javaMain, javaRuntime, program
}
