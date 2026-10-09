// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A Sendable JSON value keeps protocol data out of AppKit and across actor boundaries.
enum LSPJSON: Codable, Sendable, Equatable {
    case object([String: LSPJSON]), array([LSPJSON]), string(String), number(Int), decimal(Double), bool(Bool), null
    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Int.self) { self = .number(v) }
        else if let v = try? value.decode(Double.self) { self = .decimal(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try value.decode([Self].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
            case .object(let v): try value.encode(v)
            case .array(let v): try value.encode(v)
            case .string(let v): try value.encode(v)
            case .number(let v): try value.encode(v)
            case .decimal(let v): try value.encode(v)
            case .bool(let v): try value.encode(v)
            case .null: try value.encodeNil()
        }
    }
    subscript(_ key: String) -> Self { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var int: Int? { if case .number(let v) = self { return v }; return nil }
    var array: [Self]? { if case .array(let v) = self { return v }; return nil }
    var object: [String: Self]? { if case .object(let v) = self { return v }; return nil }
}

enum LSPLanguage: String, Codable, CaseIterable, Sendable {
    case java, python
    var fileExtension: String { self == .java ? "java" : "py" }
}

struct LSPConfiguration: Codable, Sendable {
    struct Server: Codable, Sendable {
        let language: LSPLanguage
        let executable: String
        let arguments: [String]
    }
    let schemaVersion: Int
    let servers: [Server]
    func validate() throws {
        guard schemaVersion == 1, servers.count <= 2,
              Set(servers.map(\.language)).count == servers.count else { throw LSPError.invalidConfiguration }
        for server in servers {
            guard server.executable.hasPrefix("/"),
                  FileManager.default.isExecutableFile(atPath: server.executable),
                  server.arguments.count <= 128,
                  URL(fileURLWithPath: server.executable).lastPathComponent == (server.language == .java ? "java" : "node") else { throw LSPError.invalidConfiguration }
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: server.executable))
            defer { try? handle.close() }
            let magic = try handle.read(upToCount: 4) ?? Data()
            let machO: [Data] = [Data([0xCF, 0xFA, 0xED, 0xFE]), Data([0xCE, 0xFA, 0xED, 0xFE]), Data([0xCA, 0xFE, 0xBA, 0xBE]), Data([0xCA, 0xFE, 0xBA, 0xBF])]
            guard machO.contains(magic), server.executable != "/usr/bin/java" else { throw LSPError.invalidConfiguration }
        }
    }
}

enum LSPError: Error, LocalizedError {
    case invalidConfiguration, invalidFrame, stopped, timeout, server(String), unsupportedEdit
    var errorDescription: String? {
        switch self {
            case .invalidConfiguration: "Use schemaVersion 1, unique Java/Python descriptors, and absolute direct java/node executable paths (no launcher scripts)."
            case .invalidFrame: "The server sent an invalid or oversized protocol message."
            case .stopped: "The language server stopped."
            case .timeout: "The language server did not respond within 15 seconds."
            case .server(let message): message
            case .unsupportedEdit: "This completion requires an unsupported edit or command."
        }
    }
}

/// LSP positions count UTF-16 code units, as does NSTextView. CRLF is one line break.
enum LSPText {
    static func lineRanges(_ text: String) -> [NSRange] {
        let source = text as NSString
        var result: [NSRange] = []
        var start = 0, index = 0
        while index < source.length {
            let c = source.character(at: index)
            if c == 10 || c == 13 {
                result.append(NSRange(location: start, length: index - start))
                if c == 13, index + 1 < source.length, source.character(at: index + 1) == 10 { index += 1 }
                start = index + 1
            }
            index += 1
        }
        result.append(NSRange(location: start, length: source.length - start))
        return result
    }
    static func position(_ offset: Int, in text: String, lines: [NSRange]? = nil) throws -> LSPJSON {
        for (line, range) in (lines ?? lineRanges(text)).enumerated() where NSLocationInRange(offset, range) || offset == NSMaxRange(range) {
            return .object(["line": .number(line), "character": .number(offset - range.location)])
        }
        throw LSPError.unsupportedEdit
    }
    static func offset(_ position: LSPJSON, in text: String, lines cached: [NSRange]? = nil) throws -> Int {
        let lines = cached ?? lineRanges(text)
        guard let line = position["line"].int, let column = position["character"].int,
              lines.indices.contains(line), column >= 0, column <= lines[line].length else { throw LSPError.unsupportedEdit }
        let offset = lines[line].location + column
        let source = text as NSString
        if offset > 0, offset < source.length,
           (0xD800...0xDBFF).contains(source.character(at: offset - 1)),
           (0xDC00...0xDFFF).contains(source.character(at: offset)) { throw LSPError.unsupportedEdit }
        return offset
    }
    static func range(_ value: LSPJSON, in text: String, lines: [NSRange]? = nil) throws -> NSRange {
        let start = try offset(value["start"], in: text, lines: lines), end = try offset(value["end"], in: text, lines: lines)
        guard end >= start else { throw LSPError.unsupportedEdit }
        return NSRange(location: start, length: end - start)
    }
    struct Edit: Sendable { let range: NSRange; let text: String; var primary = false }
    static func edits(_ item: LSPJSON, text: String, fallback: NSRange, caret: Int, lines cached: [NSRange]? = nil) throws -> [Edit] {
        // JDT LS attaches selection bookkeeping even with command support unadvertised.
        // Its plain text edit is independently usable; omit that command entirely.
        let ignorableSelectionCommand = item["command"]["command"].string == "java.completion.onDidSelect"
        guard item["insertTextFormat"].int != 2, item["command"] == .null || ignorableSelectionCommand else { throw LSPError.unsupportedEdit }
        let lines = cached ?? lineRanges(text)
        let main: Edit
        if item["textEdit"] != .null {
            let edit = item["textEdit"]
            let range = try range(edit["range"] == .null ? edit["replace"] : edit["range"], in: text, lines: lines)
            guard let replacement = edit["newText"].string,
                  range.location <= caret, NSMaxRange(range) >= caret,
                  try position(range.location, in: text, lines: lines)["line"] == position(caret, in: text, lines: lines)["line"],
                  try position(NSMaxRange(range), in: text, lines: lines)["line"] == position(caret, in: text, lines: lines)["line"] else { throw LSPError.unsupportedEdit }
            main = Edit(range: range, text: replacement, primary: true)
        } else {
            guard fallback.location >= 0, NSMaxRange(fallback) <= (text as NSString).length,
                  let replacement = item["insertText"].string ?? item["label"].string else { throw LSPError.unsupportedEdit }
            main = Edit(range: fallback, text: replacement, primary: true)
        }
        var edits = [main]
        for extra in item["additionalTextEdits"].array ?? [] {
            guard let replacement = extra["newText"].string else { throw LSPError.unsupportedEdit }
            edits.append(Edit(range: try range(extra["range"], in: text, lines: lines), text: replacement))
        }
        edits.sort { $0.range.location < $1.range.location }
        for pair in zip(edits, edits.dropFirst()) {
            guard NSMaxRange(pair.0.range) <= pair.1.range.location,
                  pair.0.range.location != pair.1.range.location else { throw LSPError.unsupportedEdit }
        }
        return edits
    }
}

/// Incremental bounded framing handles fragmented headers, UTF-8 and coalesced messages.
struct LSPFramer {
    private var buffer = Data()
    mutating func append(_ bytes: Data) throws -> [LSPJSON] {
        buffer.append(bytes)
        guard buffer.count <= 16 * 1024 * 1024 else { throw LSPError.invalidFrame }
        var messages: [LSPJSON] = []
        let delimiter = Data("\r\n\r\n".utf8)
        while let split = buffer.range(of: delimiter) {
            guard split.lowerBound <= 8192,
                  let header = String(data: buffer[..<split.lowerBound], encoding: .ascii) else { throw LSPError.invalidFrame }
            let lengths = header.components(separatedBy: "\r\n").compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
            guard lengths.count == 1, let length = lengths.first, length > 0, length <= 8 * 1024 * 1024 else { throw LSPError.invalidFrame }
            guard buffer.count >= split.upperBound + length else { break }
            messages.append(try JSONDecoder().decode(LSPJSON.self, from: buffer[split.upperBound..<(split.upperBound + length)]))
            buffer.removeSubrange(..<(split.upperBound + length))
        }
        if buffer.range(of: delimiter) == nil, buffer.count > 8192 { throw LSPError.invalidFrame }
        return messages
    }
    static func encode(_ message: LSPJSON) throws -> Data {
        let body = try JSONEncoder().encode(message)
        return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }
}

/// Automatic eligibility is independent of UI and protocol transport.
enum LSPAutomaticContext {
    struct Trigger { let character: String? }
    static func trigger(text: String, caret: Int, characters: Set<String>) -> Trigger? {
        let units = text as NSString
        guard caret > 0, caret <= units.length else { return nil }
        // Eligibility runs on the UI actor: inspect a bounded suffix, not a copy
        // of the entire document. Extremely long numeric tails conservatively wait.
        let before = units.substring(with: NSRange(location: max(0, caret - 256), length: min(caret, 256)))
        guard let last = before.last else { return nil }
        if characters.contains(String(last)) {
            // A trigger on its own in a blank buffer has no receiver/context.
            guard before.dropLast().contains(where: { !$0.isWhitespace }) else { return nil }
            return Trigger(character: String(last))
        }
        let prefix = before.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        guard let first = prefix.last, first.isLetter || first == "_" else { return nil }
        return Trigger(character: nil)
    }
}

/// Bounded, stable client filtering. Server sortText and preselect break relevance ties.
enum LSPPresentation {
    struct Candidate: Sendable { let item: LSPJSON; let ghost: String? }
    static func candidates(_ items: [LSPJSON], text: String, fallback: NSRange, caret: Int) -> [Candidate] {
        let source = text as NSString
        guard fallback.location >= 0, fallback.location <= caret, caret <= source.length else { return [] }
        let prefix = source.substring(with: NSRange(location: fallback.location, length: caret - fallback.location))
        let lines = LSPText.lineRanges(text)
        let foldedPrefix = prefix.lowercased()
        var scored: [(LSPJSON, Int, Int, String, Int)] = []
        for (index, item) in items.prefix(5000).enumerated() {
            if Task.isCancelled { return [] }
            let filter = item["filterText"].string ?? item["textEdit"]["newText"].string ?? item["insertText"].string ?? item["label"].string ?? ""
            let match: Int
            if prefix.isEmpty { match = 1 }
            else if filter == prefix { match = 0 }
            else if filter.hasPrefix(prefix) { match = 1 }
            else if filter.lowercased().hasPrefix(foldedPrefix) { match = 2 }
            else {
                var remaining = filter.lowercased()[...]
                var fits = true
                for letter in foldedPrefix {
                    guard let next = remaining.firstIndex(of: letter) else { fits = false; break }
                    remaining = remaining[remaining.index(after: next)...]
                }
                guard fits else { continue }; match = 3
            }
            scored.append((item, match, item["preselect"] == .bool(true) ? 0 : 1, item["sortText"].string ?? item["label"].string ?? "", index))
        }
        scored.sort { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.2 != b.2 { return a.2 < b.2 }
            if a.3 != b.3 { return a.3 < b.3 }
            return a.4 < b.4
        }
        var result: [Candidate] = []
        for ranked in scored.prefix(1000) {
            if Task.isCancelled { return [] }
            guard let edits = try? LSPText.edits(ranked.0, text: text, fallback: fallback, caret: caret, lines: lines) else { continue }
            result.append(Candidate(item: ranked.0, ghost: ghost(edits: edits, text: text, caret: caret)))
            if result.count == 100 { break }
        }
        return result
    }
    /// Only an append at a line end can be drawn without moving or covering real text.
    static func ghost(edits: [LSPText.Edit], text: String, caret: Int) -> String? {
        guard edits.count == 1, let edit = edits.first, edit.primary,
              NSMaxRange(edit.range) == caret, edit.range.location >= 0, edit.range.location <= caret else { return nil }
        let source = text as NSString, replacement = edit.text as NSString
        guard caret <= source.length, edit.range.length <= replacement.length else { return nil }
        if edit.range.length > 0, edit.range.length < replacement.length,
           (0xD800...0xDBFF).contains(replacement.character(at: edit.range.length - 1)),
           (0xDC00...0xDFFF).contains(replacement.character(at: edit.range.length)) { return nil }
        let typed = source.substring(with: edit.range)
        let replacementPrefix = replacement.substring(to: edit.range.length)
        guard typed.utf16.elementsEqual(replacementPrefix.utf16) else { return nil }
        let suffix = replacement.substring(from: edit.range.length)
        var start = 0, end = 0, contentsEnd = 0
        source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: caret, length: 0))
        guard contentsEnd >= caret, contentsEnd - caret <= 256 else { return nil }
        let tail = source.substring(with: NSRange(location: caret, length: contentsEnd - caret))
        guard !suffix.isEmpty, suffix.utf16.count <= 256,
              !edit.text.contains(where: { $0.isNewline || $0 == "\t" }),
              tail.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        return suffix
    }
}

/// Shorter warm-service delay; rapid typing raises it to bound requests without starving pauses.
struct LSPDebouncePolicy {
    private var lastEdit: TimeInterval?
    mutating func delay(now: TimeInterval, warm: Bool) -> Int {
        defer { lastEdit = now }
        guard warm else { return 120 }
        if let previous = lastEdit, now - previous < 0.09 { return 110 }
        return 60
    }
}

/// Hover is metadata only. Bounds also apply to untrusted project documentation.
enum LSPHoverPresentation {
    static func symbol(in text: String, at offset: Int) -> NSRange? {
        let source = text as NSString
        guard offset >= 0, offset < source.length else { return nil }
        func identifier(_ range: NSRange) -> Bool {
            let part = source.substring(with: range)
            return part.count == 1 && part.first.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" } == true
        }
        var range = source.rangeOfComposedCharacterSequence(at: offset)
        guard identifier(range) else { return nil }
        while range.location > 0 {
            let previous = source.rangeOfComposedCharacterSequence(at: range.location - 1)
            guard identifier(previous) else { break }
            range = NSUnionRange(previous, range)
            guard range.length <= 256 else { return nil }
        }
        while NSMaxRange(range) < source.length {
            let next = source.rangeOfComposedCharacterSequence(at: NSMaxRange(range))
            guard identifier(next) else { break }
            range = NSUnionRange(range, next)
            guard range.length <= 256 else { return nil }
        }
        guard source.substring(with: range).first.map({ $0.isLetter || $0 == "_" || $0 == "$" }) == true else { return nil }
        return range
    }
    static func callOffset(in text: String, symbol: NSRange) -> Int? {
        let source = text as NSString
        var offset = NSMaxRange(symbol)
        guard symbol.location >= 0, offset <= source.length else { return nil }
        for _ in 0..<64 {
            guard offset < source.length else { return nil }
            let unit = source.character(at: offset)
            if unit == 40 { return offset + 1 }
            guard unit == 32 || unit == 9 else { return nil }
            offset += 1
        }
        return nil
    }
    static func text(hover: LSPJSON, signatures: LSPJSON = .null) -> String? {
        func content(_ value: LSPJSON, depth: Int = 0) -> String {
            guard depth < 4 else { return "" }
            if let string = value.string { return String(decoding: string.utf16.prefix(4096), as: UTF16.self) }
            if let array = value.array { return array.prefix(8).map { content($0, depth: depth + 1) }.filter { !$0.isEmpty }.joined(separator: "\n\n") }
            if value["value"].string != nil { return content(value["value"], depth: depth + 1) }
            return ""
        }
        let labels = (signatures["signatures"].array ?? []).prefix(6).compactMap { $0["label"].string }.map { String(decoding: $0.utf16.prefix(512), as: UTF16.self) }
        var parts = Array(NSOrderedSet(array: labels)) as? [String] ?? []
        let documentation = content(hover["contents"])
        if !documentation.isEmpty { parts.append(documentation) }
        if let first = signatures["signatures"].array?.first {
            let docs = content(first["documentation"])
            if !docs.isEmpty && !documentation.contains(docs) { parts.append(docs) }
        }
        let bounded = String(decoding: parts.joined(separator: "\n\n").utf16.prefix(4096), as: UTF16.self)
        let safe = String(String.UnicodeScalarView(bounded.unicodeScalars.filter {
            !((0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)) &&
            ($0.value >= 32 || $0 == "\n" || $0 == "\r" || $0 == "\t")
        }))
        // Plain text only: no Markdown/HTML interpreter, link attributes or image fetches.
        let visible = safe.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return visible.isEmpty ? nil : visible
    }
}

struct LSPHoverStamp: Sendable {
    let epoch: Int
    let generation: Int
    let snapshot: String
    let fileURL: URL?
    let symbol: NSRange
    func matches(epoch: Int, generation: Int, snapshot: String, fileURL: URL?, symbol: NSRange?) -> Bool {
        self.epoch == epoch && self.generation == generation && self.snapshot == snapshot && self.fileURL == fileURL && self.symbol == symbol
    }
}

struct LSPDiagnosticBatch: Sendable {
    let uri: URL
    let version: Int
    let snapshot: String
    let items: [LSPJSON]
}

struct LSPDiagnosticStamp: Sendable {
    let uri: URL; let revision: Int; let version: Int
    func matches(batch: LSPDiagnosticBatch, revision: Int) -> Bool { uri == batch.uri && version == batch.version && self.revision == revision }
}

/// Safe read-only locations and single-document edits. No resource operations or commands run.
enum LSPAssistance {
    struct Diagnostic: Sendable { let range: NSRange; let severity: Int; let message: String; let raw: LSPJSON }
    static func diagnostics(_ batch: LSPDiagnosticBatch) -> [Diagnostic] {
        let lines = LSPText.lineRanges(batch.snapshot)
        return batch.items.compactMap { item in
            guard let severity = item["severity"].int, (1...4).contains(severity),
                  let range = try? LSPText.range(item["range"], in: batch.snapshot, lines: lines),
                  let message = item["message"].string else { return nil }
            return Diagnostic(range: range, severity: severity, message: String(message.prefix(1000)), raw: item)
        }
    }
    struct Location: Sendable { let uri: URL; let range: LSPJSON }
    static func locations(_ value: LSPJSON) -> [Location] {
        let values = value.array ?? (value == .null ? [] : [value])
        return values.prefix(100).compactMap { item in
            guard let raw = item["uri"].string ?? item["targetUri"].string,
                  let uri = URL(string: raw), uri.isFileURL, uri.host == nil || uri.host == "localhost",
                  [LSPLanguage.java.fileExtension, LSPLanguage.python.fileExtension].contains(uri.pathExtension.lowercased()) else { return nil }
            let range = item["targetSelectionRange"] == .null ? item["range"] : item["targetSelectionRange"]
            guard range["start"]["line"].int != nil, range["end"]["line"].int != nil else { return nil }
            return Location(uri: uri, range: range)
        }
    }
    static func safeDefinitionFile(_ uri: URL, workspace: URL) -> URL? {
        let url = uri.standardizedFileURL, root = workspace.standardizedFileURL
        guard uri.isFileURL, uri.host == nil || uri.host == "localhost",
              url.path.hasPrefix(root.path + "/"), url.resolvingSymlinksInPath() == url,
              !url.path.dropFirst(root.path.count + 1).split(separator: "/").contains(where: { $0.hasPrefix(".") }),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              (values.fileSize ?? Int.max) <= 4_000_000 else { return nil }
        return url
    }
    /// Only current document edits; reject multi-file edits atomically instead of partially applying.
    static func actionEdits(_ action: LSPJSON, uri: URL, version: Int?, text: String) throws -> [LSPText.Edit] {
        guard action["disabled"] == .null else { throw LSPError.unsupportedEdit }
        var edit = action["edit"]
        if action["command"] != .null {
            let command = action["command"].object != nil ? action["command"] : action
            // JDT represents an edit as this command. Unwrap its data; never execute it.
            guard command["command"].string == "java.apply.workspaceEdit", let args = command["arguments"].array, args.count == 1, edit == .null else { throw LSPError.unsupportedEdit }
            edit = args[0]
        }
        guard edit.object != nil, edit["changeAnnotations"] == .null else { throw LSPError.unsupportedEdit }
        var values: [LSPJSON] = []
        if let changes = edit["changes"].object {
            guard changes.count == 1, let current = changes[uri.absoluteString]?.array else { throw LSPError.unsupportedEdit }
            values += current
        }
        if let changes = edit["documentChanges"].array {
            guard edit["changes"] == .null, changes.count == 1 else { throw LSPError.unsupportedEdit }
            let change = changes[0]
            guard change["kind"] == .null, change["textDocument"]["uri"].string == uri.absoluteString,
                  change["textDocument"]["version"] == .null || (version != nil && change["textDocument"]["version"].int != nil && change["textDocument"]["version"].int == version),
                  let edits = change["edits"].array else { throw LSPError.unsupportedEdit }
            values += edits
        }
        guard !values.isEmpty, values.count <= 100 else { throw LSPError.unsupportedEdit }
        let lines = LSPText.lineRanges(text)
        let edits = try values.map { value -> LSPText.Edit in
            guard let replacement = value["newText"].string, replacement.utf16.count <= 1_000_000, value["annotationId"] == .null else { throw LSPError.unsupportedEdit }
            return LSPText.Edit(range: try LSPText.range(value["range"], in: text, lines: lines), text: replacement)
        }.sorted { $0.range.location < $1.range.location }
        for (a, b) in zip(edits, edits.dropFirst()) where NSMaxRange(a.range) > b.range.location || a.range.location == b.range.location { throw LSPError.unsupportedEdit }
        return edits
    }
    static func importEdits(_ item: LSPJSON, uri: URL, version: Int?, text: String, symbol: NSRange, caret: Int) throws -> [LSPText.Edit] {
        guard var value = item.object, let extras = value.removeValue(forKey: "additionalTextEdits")?.array, !extras.isEmpty else { throw LSPError.unsupportedEdit }
        let primary = try LSPText.edits(.object(value), text: text, fallback: symbol, caret: caret)
        guard primary.count == 1, primary[0].text.utf16.elementsEqual((text as NSString).substring(with: primary[0].range).utf16) else { throw LSPError.unsupportedEdit }
        // Validate only the actual server's additional edits. The unchanged primary edit is
        // omitted; an import at offset0 can share the original identifier's boundary safely.
        let action = LSPJSON.object(["edit": .object(["documentChanges": .array([.object([
            "textDocument": .object(["uri": .string(uri.absoluteString), "version": version.map(LSPJSON.number) ?? .null]), "edits": .array(extras)
        ])])])])
        return try actionEdits(action, uri: uri, version: version, text: text)
    }
    static func caret(after edits: [LSPText.Edit], original: Int, textLength: Int) -> Int {
        var shift = 0, caret = original
        for edit in edits {
            let count = (edit.text as NSString).length
            if NSMaxRange(edit.range) <= original { shift += count - edit.range.length; caret = original + shift }
            else if edit.range.location <= original { caret = edit.range.location + shift + count; break }
        }
        let length = textLength + edits.reduce(0) { $0 + ($1.text as NSString).length - $1.range.length }
        return min(max(0, caret), max(0, length))
    }
    struct Signature: Sendable { let label: String; let active: NSRange?; let documentation: String? }
    static func signature(_ value: LSPJSON) -> Signature? {
        guard let signatures = value["signatures"].array, !signatures.isEmpty else { return nil }
        let index = value["activeSignature"].int ?? 0
        guard signatures.indices.contains(index), let label = signatures[index]["label"].string, label.utf16.count <= 2048 else { return nil }
        let parameters = signatures[index]["parameters"].array ?? []
        let selected = signatures[index]["activeParameter"].int ?? value["activeParameter"].int ?? 0
        var active: NSRange?
        if parameters.indices.contains(selected) {
            let parameter = parameters[selected]["label"]
            if let offsets = parameter.array, offsets.count == 2, let start = offsets[0].int, let end = offsets[1].int,
               start >= 0, end >= start, end <= (label as NSString).length { active = NSRange(location: start, length: end - start) }
            else if let name = parameter.string {
                var next = (label as NSString).range(of: "(").location
                if next == NSNotFound { next = 0 } else { next += 1 }
                for item in parameters.prefix(selected + 1) {
                    guard let name = item["label"].string else { break }
                    let range = (label as NSString).range(of: name, range: NSRange(location: next, length: (label as NSString).length - next))
                    guard range.location != NSNotFound else { break }
                    active = range; next = NSMaxRange(range)
                }
                if active?.length != (name as NSString).length { active = nil }
            }
        }
        if let range = active {
            let units = label as NSString
            func boundary(_ offset: Int) -> Bool {
                offset <= 0 || offset >= units.length || !((0xD800...0xDBFF).contains(units.character(at: offset - 1)) && (0xDC00...0xDFFF).contains(units.character(at: offset)))
            }
            if !boundary(range.location) || !boundary(NSMaxRange(range)) { active = nil }
        }
        return Signature(label: label, active: active, documentation: LSPHoverPresentation.text(hover: .object(["contents": signatures[index]["documentation"]])))
    }
    /// Bounded eligibility only. Server decides the real call/signature/active parameter.
    static func isInCall(_ text: String, caret: Int) -> Bool {
        let source = text as NSString
        guard caret > 0, caret <= source.length else { return false }
        let start = max(0, caret - 2048)
        let suffix = source.substring(with: NSRange(location: start, length: caret - start))
        var depth = 0
        for char in suffix.reversed() {
            if char == ")" { depth += 1 }
            if char == "(" { if depth == 0 { return true }; depth -= 1 }
            if depth == 0 && (char == ";" || char == "{" || char == "}") { return false }
        }
        return false
    }
}
