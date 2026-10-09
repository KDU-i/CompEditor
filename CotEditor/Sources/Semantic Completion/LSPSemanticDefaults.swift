// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Ordinary preferences belong to the isolated fork domain, never the installed editor.
struct LSPSemanticPreferences {
    let defaults: UserDefaults
    init(defaults: UserDefaults) {
        self.defaults = defaults
        // One-time migration from the earlier explicit-setup prototype.
        if defaults.integer(forKey: "semanticZeroSetupVersion") < 1 {
            for key in ["semanticEnabled", "semanticJavaEnabled", "semanticPythonEnabled", "semanticAutomaticCompletion"] where defaults.object(forKey: key) == nil { defaults.set(true, forKey: key) }
            defaults.set(1, forKey: "semanticZeroSetupVersion")
        }
    }
    var globallyEnabled: Bool {
        get { defaults.bool(forKey: "semanticEnabled") }
        nonmutating set { defaults.set(newValue, forKey: "semanticEnabled") }
    }
    var automatic: Bool {
        get { defaults.bool(forKey: "semanticAutomaticCompletion") }
        nonmutating set { defaults.set(newValue, forKey: "semanticAutomaticCompletion") }
    }
    func isEnabled(_ language: LSPLanguage) -> Bool { defaults.bool(forKey: "semantic\(language.rawValue.capitalized)Enabled") }
    func setEnabled(_ value: Bool, for language: LSPLanguage) { defaults.set(value, forKey: "semantic\(language.rawValue.capitalized)Enabled") }
}

/// Fixed app-owned layouts; no project config, PATH executable search or shell wrappers.
enum LSPBundledServers {
    static func server(_ language: LSPLanguage, resources: URL, storage: URL) throws -> LSPConfiguration.Server {
        let root = resources.appendingPathComponent("SemanticServers", isDirectory: true)
        guard root.resolvingSymlinksInPath().standardizedFileURL.path == resources.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("SemanticServers").path else { throw unavailable(language) }
        let manifestURL = try contained("manifest.json", root: root)
        guard let size = try? manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096 else { throw unavailable(language) }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        guard manifest?["schemaVersion"] as? Int == 1 else { throw unavailable(language) }
        let server: LSPConfiguration.Server
        switch language {
            case .python:
                let script = try contained("pyright/pyright/langserver.index.js", root: root)
                server = .init(language: language, executable: try contained("node", root: root).path, arguments: [script.path, "--stdio"])
            case .java:
                guard let launcher = manifest?["launcher"] as? String,
                      launcher.hasPrefix("org.eclipse.equinox.launcher_"), launcher.hasSuffix(".jar"),
                      !launcher.contains("/"), !launcher.contains("..") else { throw unavailable(language) }
                let jar = try contained("jdtls/plugins/\(launcher)", root: root)
                let sourceConfig = try contained("jdtls/config_mac", root: root)
                let config = storage.appendingPathComponent("configuration", isDirectory: true)
                try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: config.path) { try FileManager.default.copyItem(at: sourceConfig, to: config) }
                server = .init(language: language, executable: try contained("jdk/bin/java", root: root).path, arguments: [
                    "-Declipse.application=org.eclipse.jdt.ls.core.id1", "-Dosgi.bundles.defaultStartLevel=4",
                    "-Declipse.product=org.eclipse.jdt.ls.core.product", "-Xmx1G", "--add-modules=ALL-SYSTEM",
                    "--add-opens", "java.base/java.util=ALL-UNNAMED", "--add-opens", "java.base/java.lang=ALL-UNNAMED",
                    "-jar", jar.path, "-configuration", config.path, "-data", storage.appendingPathComponent("data").path
                ])
        }
        try LSPConfiguration(schemaVersion: 1, servers: [server]).validate()
        return server
    }
    private static func contained(_ path: String, root: URL) throws -> URL {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/"), FileManager.default.fileExists(atPath: url.path) else { throw LSPError.server("Bundled language-server resources are missing or invalid. Rebuild using Scripts/build-semantic-editor.sh; no automatic download occurs.") }
        return url
    }
    private static func unavailable(_ language: LSPLanguage) -> LSPError { .server("The bundled \(language.rawValue.capitalized) server is unavailable. Rebuild with the approved server resources. No project commands or automatic downloads will be used.") }
}

struct LSPWorkspaceRoute: Sendable {
    let workspace: URL
    let uri: URL
    let storage: URL
    let isolated: Bool
}

/// Bounded ancestor discovery reads marker metadata only. Broad/sensitive folders are never roots.
enum LSPWorkspaceRouter {
    static func route(fileURL: URL?, bufferID: UUID, language: LSPLanguage, cache: URL, home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) throws -> LSPWorkspaceRoute {
        let fm = FileManager.default
        let file = fileURL?.resolvingSymlinksInPath().standardizedFileURL
        let home = home.resolvingSymlinksInPath().standardizedFileURL
        let broad = Set(["/", "/Users", "/Library", "/System", "/Applications", "/Volumes", "/private", "/private/tmp", "/tmp", "/usr", "/opt", "/bin", "/sbin", "/dev", home.path] + ["Desktop", "Documents", "Downloads", "Library", "Pictures", "Movies", "Music"].map { home.appendingPathComponent($0).path })
        func forbidden(_ directory: URL) -> Bool {
            broad.contains(directory.path) || directory.pathComponents.contains(where: { $0.hasPrefix(".") }) ||
            (directory.path.hasPrefix("/Volumes/") && directory.pathComponents.count <= 3) ||
            directory.path.hasPrefix(home.appendingPathComponent("Library").path + "/") ||
            ["/System/", "/Library/", "/usr/", "/opt/", "/private/", "/Applications/", "/bin/", "/sbin/", "/dev/"].contains(where: { directory.path.hasPrefix($0) })
        }
        var project: URL?
        if let file, file.isFileURL, file.path == fileURL?.standardizedFileURL.path {
            let parent = file.deletingLastPathComponent()
            if !forbidden(parent) {
                project = parent
                var candidate = parent
                let markers = language == .python ? ["pyproject.toml", "setup.cfg", ".git"] : ["pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", ".project", ".git"]
                for _ in 0..<6 {
                    if forbidden(candidate) { break }
                    if markers.contains(where: { marker in
                        let url = candidate.appendingPathComponent(marker)
                        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]), values.isSymbolicLink != true else { return false }
                        return values.isRegularFile == true || (marker == ".git" && values.isDirectory == true)
                    }) { project = candidate; break }
                    let next = candidate.deletingLastPathComponent()
                    if next == candidate { break }; candidate = next
                }
            }
        }
        let identity = project?.absoluteString ?? file?.absoluteString ?? bufferID.uuidString
        let key = identity.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let storage = cache.appendingPathComponent("\(language.rawValue)/\(String(key, radix: 16))", isDirectory: true)
        let workspace = project ?? storage.appendingPathComponent("buffer", isDirectory: true)
        if project == nil { try fm.createDirectory(at: workspace, withIntermediateDirectories: true) }
        let uri = project != nil ? file! : workspace.appendingPathComponent(file?.lastPathComponent ?? "Untitled-\(bufferID.uuidString).\(language.fileExtension)")
        return LSPWorkspaceRoute(workspace: workspace, uri: uri, storage: storage, isolated: project == nil)
    }
}
