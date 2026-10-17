// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

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
    case invalidConfiguration, invalidFrame, stopped, timeout, server(String), unsupportedEdit, methodNotFound
    var errorDescription: String? {
        switch self {
            case .invalidConfiguration: "Use schemaVersion 1, unique Java/Python descriptors, and absolute direct java/node executable paths (no launcher scripts)."
            case .invalidFrame: "The server sent an invalid or oversized protocol message."
            case .stopped: "The language server stopped."
            case .timeout: "The language server did not respond within 15 seconds."
            case .server(let message): message
            case .unsupportedEdit: "This completion requires an unsupported edit or command."
            case .methodNotFound: "The server does not support this public method."
        }
    }
}

/// LSP positions count UTF-16 code units, as does NSTextView. CRLF is one line break.
enum LSPText {
    /// Preserve the actual edit window for Copilot's recent-edit history.
    /// Boundaries never split a UTF-16 surrogate pair or CRLF sequence.
    /// Protocol ranges address UTF-16 code units. Swift's canonical String
    /// equality can hide a normalization edit and leave server offsets stale.
    static func sameText(_ snapshot: String?, _ text: String) -> Bool {
        snapshot?.utf16.elementsEqual(text.utf16) == true
    }

    static func incrementalChange(from previous: String, to current: String) throws -> LSPJSON {
        let old = Array(previous.utf16), new = Array(current.utf16)
        var start = 0
        while start < min(old.count, new.count), old[start] == new[start] { start += 1 }
        func boundary(_ units: [UInt16], _ index: Int) -> Bool {
            guard index > 0, index < units.count else { return true }
            return !(units[index - 1] == 13 && units[index] == 10) &&
                !((0xD800...0xDBFF).contains(units[index - 1]) && (0xDC00...0xDFFF).contains(units[index]))
        }
        while !boundary(old, start) || !boundary(new, start) { start -= 1 }
        var oldEnd = old.count, newEnd = new.count
        while oldEnd > start, newEnd > start, old[oldEnd - 1] == new[newEnd - 1] { oldEnd -= 1; newEnd -= 1 }
        while !boundary(old, oldEnd) || !boundary(new, newEnd) { oldEnd += 1; newEnd += 1 }
        let replacement = (current as NSString).substring(with: NSRange(location: start, length: newEnd - start))
        return .object(["text": .string(replacement), "range": .object([
            "start": try position(start, in: previous), "end": try position(oldEnd, in: previous)
        ])])
    }

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
        self.epoch == epoch && self.generation == generation && LSPText.sameText(self.snapshot, snapshot) && self.fileURL == fileURL && self.symbol == symbol
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

/// Diagnostic hit testing shares the underline's half-open UTF-16 range semantics.
enum LSPDiagnosticHover {
    static func target(_ items: [LSPAssistance.Diagnostic], at offset: Int, length: Int) -> (NSRange, String)? {
        let matches = items.filter { item in
            guard item.severity <= 2 else { return false }
            return item.range.length > 0 ? NSLocationInRange(offset, item.range) : offset == min(item.range.location, max(0, length - 1))
        }.sorted { $0.severity < $1.severity }
        guard let first = matches.first, length > 0 else { return nil }
        let range = first.range.length > 0 ? first.range : NSRange(location: min(first.range.location, length - 1), length: 1)
        let text = matches.map { item in
            let source = item.raw["source"].string.map { " [" + $0 + "]" } ?? ""
            let code = item.raw["code"].string ?? item.raw["code"].int.map(String.init)
            return (item.severity == 1 ? "Error" : "Warning") + source + (code.map { " (" + $0 + ")" } ?? "") + ": " + item.message
        }.joined(separator: "\n\n")
        return (range, text)
    }
}

/// Only validated plain-text inline edits and official completion commands are accepted.
// Observable behavior references and retained MIT notices: COPILOT_VSCODE_PARITY.md.
enum CopilotLanguage {
    static func resolve(url: URL?, syntax: String) -> String {
        let mode = syntax.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let names = ["python":"python", "java":"java", "javascript":"javascript", "typescript":"typescript", "javascript jsx":"javascriptreact", "typescript jsx":"typescriptreact", "jsx":"javascriptreact", "tsx":"typescriptreact", "c":"c", "c++":"cpp", "c#":"csharp", "objective-c":"objective-c", "swift":"swift", "rust":"rust", "go":"go", "ruby":"ruby", "php":"php", "html":"html", "css":"css", "scss":"scss", "json":"json", "json5":"jsonc", "yaml":"yaml", "toml":"toml", "markdown":"markdown", "shell script":"shellscript", "bash":"shellscript", "sql":"sql", "xml":"xml", "kotlin":"kotlin", "scala":"scala", "dart":"dart", "lua":"lua", "r":"r", "plain text":"plaintext", "none":"plaintext"]
        if let language = names[mode] { return language }
        let extensions = ["py":"python", "java":"java", "js":"javascript", "mjs":"javascript", "ts":"typescript", "jsx":"javascriptreact", "tsx":"typescriptreact", "c":"c", "h":"c", "cpp":"cpp", "cc":"cpp", "cs":"csharp", "swift":"swift", "rs":"rust", "go":"go", "rb":"ruby", "php":"php", "html":"html", "css":"css", "scss":"scss", "json":"json", "yaml":"yaml", "yml":"yaml", "toml":"toml", "md":"markdown", "sh":"shellscript", "sql":"sql", "xml":"xml", "kt":"kotlin", "scala":"scala", "dart":"dart", "lua":"lua", "r":"r"]
        if let language = url.flatMap({ extensions[$0.pathExtension.lowercased()] }) { return language }
        return mode.isEmpty ? "plaintext" : mode.replacingOccurrences(of: " ", with: "-")
    }
}

enum CopilotInline {
    struct Part: Sendable, Equatable { let offset: Int; let text: String }
    struct Plan: Sendable {
        let edit: LSPText.Edit
        let parts: [Part]
        var text: String { parts.map(\.text).joined() }
    }
    static func normalize(_ insert: String, in snapshot: String) -> String {
        let lf = insert.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if snapshot.contains("\r\n") { return lf.replacingOccurrences(of: "\n", with: "\r\n") }
        if snapshot.contains("\r"), !snapshot.contains("\n") { return lf.replacingOccurrences(of: "\n", with: "\r") }
        return lf
    }
    static func wordRange(in text: String, caret: Int) -> NSRange {
        let line = (text as NSString).lineRange(for: NSRange(location: caret, length: 0))
        let regex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}_$]+")
        return regex.matches(in: text, range: line).first(where: { $0.range.location <= caret && NSMaxRange($0.range) >= caret })?.range ?? NSRange(location: caret, length: 0)
    }
    static func edit(_ item: LSPJSON, text: String, caret: Int) throws -> LSPText.Edit { try plan(item, text: text, caret: caret).edit }
    static func plan(_ item: LSPJSON, text: String, caret: Int) throws -> Plan {
        guard let raw = item["insertText"].string, !raw.isEmpty, raw.utf16.count <= 100_000 else { throw LSPError.invalidConfiguration }
        _ = try LSPText.offset(LSPText.position(caret, in: text), in: text)
        let range = item["range"] == .null ? wordRange(in: text, caret: caret) : try LSPText.range(item["range"], in: text)
        guard range.location <= caret, caret <= NSMaxRange(range),
              try LSPText.position(NSMaxRange(range), in: text)["line"] == LSPText.position(caret, in: text)["line"] else { throw LSPError.invalidConfiguration }
        let insert = normalize(raw, in: text)
        let source = text as NSString
        let prefix = source.substring(with: NSRange(location: range.location, length: caret - range.location))
        guard insert.utf16.starts(with: prefix.utf16) else { throw LSPError.invalidConfiguration }
        let tail = source.substring(with: NSRange(location: caret, length: NSMaxRange(range) - caret))
        let proposed = Array((insert as NSString).substring(from: prefix.utf16.count).unicodeScalars)
        var scan = 0, offset = caret, parts: [Part] = []
        func string(_ slice: ArraySlice<UnicodeScalar>) -> String { var result = ""; result.unicodeScalars.append(contentsOf: slice); return result }
        // Existing suffix scalars must remain in order. Deletion/rewriting belongs to NES.
        for scalar in tail.unicodeScalars {
            guard let match = proposed[scan...].firstIndex(of: scalar) else { throw LSPError.unsupportedEdit }
            if match > scan { parts.append(Part(offset: offset, text: string(proposed[scan..<match]))) }
            scan = match + 1; offset += scalar.value > 0xffff ? 2 : 1
        }
        if scan < proposed.count { parts.append(Part(offset: offset, text: string(proposed[scan...]))) }
        return Plan(edit: LSPText.Edit(range: range, text: insert, primary: true), parts: parts)
    }
    enum NextEditTarget { case current, foreignDocument, staleVersion }
    static func nextEditTarget(_ item: LSPJSON, uri: URL, version: Int) -> NextEditTarget {
        guard item["textDocument"]["uri"].string == uri.absoluteString else { return .foreignDocument }
        guard item["textDocument"]["version"].int == version else { return .staleVersion }
        return .current
    }
    static func nextEdit(_ item: LSPJSON, text: String) throws -> LSPText.Edit {
        guard let value = item["insertText"].string ?? item["text"].string, value.utf16.count <= 100_000 else { throw LSPError.unsupportedEdit }
        let range = try LSPText.range(item["range"], in: text)
        let normalized = normalize(value, in: text)
        guard !(text as NSString).substring(with: range).utf16.elementsEqual(normalized.utf16) else { throw LSPError.unsupportedEdit }
        return LSPText.Edit(range: range, text: normalized, primary: true)
    }
    static func partialLength(_ text: String, line: Bool) -> Int {
        let value = text as NSString
        if line {
            let newline = value.rangeOfCharacter(from: .newlines)
            guard newline.location != NSNotFound else { return value.length }
            let extra = value.character(at: newline.location) == 13 && newline.location + 1 < value.length && value.character(at: newline.location + 1) == 10 ? 2 : 1
            return newline.location + extra
        }
        let range = NSRange(location: 0, length: value.length)
        let word = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}_$]+")
        let match = word.firstMatch(in: text, range: range)?.range
        var end = match.map { $0.location == 0 ? NSMaxRange($0) : $0.location } ?? value.length
        let whitespace = try! NSRegularExpression(pattern: "\\s+")
        if let space = whitespace.firstMatch(in: text, range: range)?.range, NSMaxRange(space) < end { end = NSMaxRange(space) }
        return max(1, end)
    }
    /// Maps accepted normalized text back to the original provider insertText UTF-16 prefix.
    static func acceptedLength(raw: String, normalizedPrefixLength: Int, snapshot: String) -> Int? {
        let units = Array(raw.utf16); var index = 0, count = 0
        let breakWidth = snapshot.contains("\r\n") ? 2 : 1
        while index < units.count && count < normalizedPrefixLength {
            if units[index] == 13 || units[index] == 10 {
                index += units[index] == 13 && index + 1 < units.count && units[index + 1] == 10 ? 2 : 1
                count += breakWidth
            } else { index += 1; count += 1 }
        }
        return count == normalizedPrefixLength ? index : nil
    }
    static func rangeJSON(_ range: NSRange, in text: String) throws -> LSPJSON {
        .object(["start": try LSPText.position(range.location, in: text), "end": try LSPText.position(NSMaxRange(range), in: text)])
    }
    static func extends(_ plan: Plan, selected: LSPText.Edit, snapshot: String) -> Bool {
        let source = snapshot as NSString
        guard NSMaxRange(selected.range) <= source.length else { return false }
        let proposal = source.replacingCharacters(in: plan.edit.range, with: plan.edit.text)
        let selectedPrefix = source.substring(to: selected.range.location) + selected.text
        return proposal.utf16.starts(with: selectedPrefix.utf16)
    }
    static func command(_ value: LSPJSON, name: String) -> LSPJSON? {
        guard value["command"].string == name, value["arguments"].array != nil else { return nil }
        return .object(["command": .string(name), "arguments": value["arguments"]])
    }
}

/// Host-side NES policy. Original implementation; VS Code is a behavioral reference only.
/// On-demand navigation authority from an explicitly opened project. This never
/// enumerates the project or gives its root to the provider. Only the named
/// normal source can be opened, then requested as the foreground document.
enum CopilotProjectTargetPolicy {
    struct Snapshot: Sendable { let uri: URL; let text: String }
    static func target(_ uri: URL, root: URL, otherLanguages: Bool = false) throws -> URL {
        guard uri.isFileURL, uri.host == nil || uri.host == "localhost", uri.query == nil, uri.fragment == nil,
              root.isFileURL, uri.standardizedFileURL.path == uri.path else { throw LSPError.unsupportedEdit }
        let original = root.standardizedFileURL, canonical = original.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let broad = ["/", home.path] + ["Desktop", "Documents", "Downloads", "Library"].map { home.appendingPathComponent($0).path }
        guard !broad.contains(canonical.path), !canonical.pathComponents.contains(where: { $0.hasPrefix(".") }) else { throw LSPError.unsupportedEdit }
        let prefix = uri.path.hasPrefix(original.path + "/") ? original : canonical
        guard uri.path.hasPrefix(prefix.path + "/") else { throw LSPError.unsupportedEdit }
        let parts = String(uri.path.dropFirst(prefix.path.count + 1)).split(separator: "/").map(String.init)
        let excluded = Set(["node_modules", "vendor", "venv", "__pycache__", "build", "dist", "target", "out", "coverage", "Pods", "Carthage", "DerivedData"])
        guard !parts.isEmpty, !parts.contains(where: { $0.hasPrefix(".") || excluded.contains($0) }),
              !parts.contains(where: { $0.range(of: #"(?i)(^|[_\-.])(secrets?|credentials?|passwords?|tokens?|private[_-]?keys?)([_\-.]|$)"#, options: .regularExpression) != nil }) else { throw LSPError.unsupportedEdit }
        let url = parts.reduce(canonical) { $0.appendingPathComponent($1) }
        let extensions = Set(["py", "java", "ts", "tsx", "js", "jsx", "swift", "c", "h", "cpp", "hpp", "cc", "cs", "go", "rs", "rb", "php", "kt", "kts", "scala", "m", "mm", "lua", "pl", "r", "dart", "vue", "svelte", "ex", "exs", "erl", "clj", "cljs", "fs", "fsx"])
        let language = CopilotLanguage.resolve(url: url, syntax: "")
        guard extensions.contains(url.pathExtension.lowercased()), otherLanguages || language == "python" || language == "java" else { throw LSPError.unsupportedEdit }
        // Check only exact ancestor metadata, never list directory contents.
        for depth in 1...parts.count {
            let item = parts.prefix(depth).reduce(canonical) { $0.appendingPathComponent($1) }
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, depth == parts.count ? values.isRegularFile == true : values.isDirectory == true else { throw LSPError.unsupportedEdit }
        }
        var exclusions = try GitExclusions(root: canonical, home: FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath())
        defer { exclusions.cleanup() }
        guard try exclusions.permits(parts) else { throw LSPError.unsupportedEdit }
        return url
    }
    static func snapshot(_ uri: URL, root: URL, otherLanguages: Bool = false) throws -> Snapshot {
        let url = try target(uri, root: root, otherLanguages: otherLanguages)
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        let parts = String(url.path.dropFirst(canonical.path.count + 1)).split(separator: "/").map(String.init)
        guard let data = try read(parts, root: canonical, limit: 4_000_000), let text = String(data: data, encoding: .utf8),
              !text.contains("\0"), !containsSecret(text) else { throw LSPError.unsupportedEdit }
        return Snapshot(uri: url, text: text)
    }
    static func containsSecret(_ text: String) -> Bool {
        text.range(of: #"(?m)BEGIN [A-Z ]*PRIVATE KEY|AKIA[A-Z0-9]{16}|(?i:(?:api[_-]?key|secret|password|access[_-]?token)\s*[:=]\s*["'][^"'\s]{8,}["'])"#, options: .regularExpression) != nil
    }
    /// Descriptor-relative reads reject symlinked ancestors, nonregular files,
    /// oversized metadata/source, and changes during the read.
    private static func read(_ parts: [String], root: URL, limit: Int) throws -> Data? {
        var fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LSPError.unsupportedEdit }
        defer { Darwin.close(fd) }
        for part in parts.dropLast() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT { return nil }
            guard next >= 0 else { throw LSPError.unsupportedEdit }
            Darwin.close(fd); fd = next
        }
        let file = openat(fd, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0, errno == ENOENT { return nil }
        guard file >= 0 else { throw LSPError.unsupportedEdit }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        var before = stat(), after = stat()
        guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size <= limit else { throw LSPError.unsupportedEdit }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count == before.st_size, data.count <= limit, fstat(file, &after) == 0, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw LSPError.unsupportedEdit }
        return data
    }
    /// Git owns pattern semantics. Only exclusion metadata is copied to a
    /// private shadow repository; Git never opens the user's repository/code.
    private struct GitExclusions {
        let root: URL
        let home: URL
        let shadow: URL
        let userConfigDirectory: URL
        var admin: URL?
        var common: URL?
        var aliases: [String] = []
        var branch: String?
        var ignoreCase = false
        var precomposeUnicode = false
        var worktreeConfig = false
        var excludesFile: URL?
        var allowedRoots: [URL]
        var exactFiles: [URL]
        var activeConfigs = Set<URL>()
        var metadataBytes = 0
        private let deadline = ContinuousClock.now.advanced(by: .seconds(5))

        init(root: URL, home: URL) throws {
            self.root = root; self.home = home
            let environment = ProcessInfo.processInfo.environment
            if let configuredHome = environment["HOME"] {
                guard URL(fileURLWithPath: configuredHome).standardizedFileURL == home.standardizedFileURL else { throw LSPError.unsupportedEdit }
            }
            guard environment["GIT_CONFIG_PARAMETERS"].map({ $0.isEmpty }) ?? true,
                  environment["GIT_CONFIG_COUNT"].map({ $0 == "0" }) ?? true else { throw LSPError.unsupportedEdit }
            if let directory = environment["XDG_CONFIG_HOME"] {
                guard directory.hasPrefix("/"), !directory.contains("\n"), !directory.contains("\0") else { throw LSPError.unsupportedEdit }
                self.userConfigDirectory = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("git").standardizedFileURL
            } else { self.userConfigDirectory = home.appendingPathComponent(".config/git") }
            self.shadow = URL.temporaryDirectory.appendingPathComponent("compeditor-ignore-" + UUID().uuidString)
            self.allowedRoots = [root, userConfigDirectory, home.appendingPathComponent(".config/git"), home.appendingPathComponent(".gitconfig.d"), URL(fileURLWithPath: "/etc/gitconfig.d").resolvingSymlinksInPath()]
            self.exactFiles = [home.appendingPathComponent(".gitconfig"), URL(fileURLWithPath: "/etc/gitconfig").resolvingSymlinksInPath()]
            do {
                try FileManager.default.createDirectory(at: shadow, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try FileManager.default.createDirectory(at: shadow.appendingPathComponent(".git/objects"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: shadow.appendingPathComponent(".git/refs"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: shadow.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
                try Data("ref: refs/heads/policy\n".utf8).write(to: shadow.appendingPathComponent(".git/HEAD"))
                try configure(caseSensitive: true)
            } catch { try? FileManager.default.removeItem(at: shadow); throw error }
        }
        func cleanup() { try? FileManager.default.removeItem(at: shadow) }
        private func configure(caseSensitive: Bool) throws {
            // Never carry hooks, helpers, remotes, fsmonitor, includes, attributes
            // or user environment/config into the Git process.
            let config = "[core]\nrepositoryformatversion = 0\nbare = false\nignorecase = \(caseSensitive ? "false" : "true")\nprecomposeunicode = \(precomposeUnicode ? "true" : "false")\nexcludesfile = \(quoted(shadow.appendingPathComponent("global-exclude").path))\n"
            try Data(config.utf8).write(to: shadow.appendingPathComponent(".git/config"))
        }
        private mutating func metadata(_ url: URL, required: Bool = false) throws -> Data? {
            let url = url.standardizedFileURL
            guard ContinuousClock.now < deadline else { throw LSPError.unsupportedEdit }
            guard !url.path.contains("\0"), !url.path.contains("\n"),
                  !url.pathComponents.contains(where: { [".env", ".aws", ".ssh", ".gnupg", "credentials", "passwords"].contains($0.lowercased()) }) else { throw LSPError.unsupportedEdit }
            let homeName = url.deletingLastPathComponent() == home && (url.lastPathComponent.hasPrefix(".gitconfig.") || url.lastPathComponent.hasPrefix(".gitconfig-") || url.lastPathComponent == ".gitignore" || url.lastPathComponent == ".gitignore_global")
            if homeName, !exactFiles.contains(url) { exactFiles.append(url) }
            let container = allowedRoots.filter { url.path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
            guard let base = container ?? (exactFiles.contains(url) ? url.deletingLastPathComponent() : nil) else { throw LSPError.unsupportedEdit }
            let parts = String(url.path.dropFirst(base.path.count + 1)).split(separator: "/").map(String.init)
            guard !parts.isEmpty,
                  !["py", "java", "js", "ts", "swift", "c", "cpp", "h", "rs", "go", "rb", "pem", "key", "p12", "pfx", "sqlite", "db"].contains(url.pathExtension.lowercased()) else { throw LSPError.unsupportedEdit }
            if base == admin || base == common {
                guard !parts.contains(where: { ["objects", "refs", "logs", "hooks", "modules", "worktrees"].contains($0) }),
                      !["index", "packed-refs", "FETCH_HEAD", "ORIG_HEAD", "COMMIT_EDITMSG", "MERGE_MSG"].contains(parts.last!) else { throw LSPError.unsupportedEdit }
            }
            var status = stat()
            if lstat(url.path, &status) != 0 {
                guard errno == ENOENT, !required else { throw LSPError.unsupportedEdit }
                return nil
            }
            let readRoot = container == nil ? base.resolvingSymlinksInPath() : base
            let data = try CopilotProjectTargetPolicy.read(parts, root: readRoot, limit: 65_536)
            if required, data == nil { throw LSPError.unsupportedEdit }
            if let data {
                metadataBytes += data.count
                guard metadataBytes <= 1_048_576, let text = String(data: data, encoding: .utf8), !data.contains(0), !CopilotProjectTargetPolicy.containsSecret(text) else { throw LSPError.unsupportedEdit }
            }
            return data
        }
        private func path(_ value: String, relativeTo directory: URL) throws -> URL {
            guard !value.isEmpty, !value.contains("\0"), !value.contains("\n"), !value.contains("%("),
                  !value.hasPrefix("~") || value.hasPrefix("~/") else { throw LSPError.unsupportedEdit }
            if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))).standardizedFileURL }
            return URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: directory.path, isDirectory: true)).standardizedFileURL
        }
        private func realPath(_ url: URL) throws -> String {
            guard let result = Darwin.realpath(url.path, nil) else { throw LSPError.unsupportedEdit }
            defer { free(result) }
            return String(cString: result)
        }
        private func directory(_ url: URL) throws -> Bool {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        mutating func discover() throws {
            let marker = root.appendingPathComponent(".git")
            var markerStatus = stat()
            if lstat(marker.path, &markerStatus) != 0 {
                guard errno == ENOENT else { throw LSPError.unsupportedEdit }; return
            }
            let values = try marker.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw LSPError.unsupportedEdit }
            var selected = marker
            if values.isDirectory != true {
                guard values.isRegularFile == true, let bytes = try metadata(marker, required: true),
                      let text = String(data: bytes, encoding: .utf8), text.hasPrefix("gitdir: ") else { throw LSPError.unsupportedEdit }
                let pointer = text.dropFirst(8).trimmingCharacters(in: .newlines)
                selected = try path(pointer, relativeTo: root)
            }
            // Auto-discovery uses getcwd/realpath, as Git -C does. A lexical
            // /var alias must not spuriously activate a different include.
            aliases = [try realPath(selected)]
            selected = selected.resolvingSymlinksInPath()
            guard try directory(selected) else { throw LSPError.unsupportedEdit }
            admin = selected
            // A linked worktree must have a reciprocal registration and the
            // conventional common-dir relation. Do not follow arbitrary pointers.
            if selected.deletingLastPathComponent().lastPathComponent == "worktrees" {
                let shared = selected.deletingLastPathComponent().deletingLastPathComponent()
                guard try directory(shared.appendingPathComponent("objects")),
                      FileManager.default.fileExists(atPath: shared.appendingPathComponent("HEAD").path) else { throw LSPError.unsupportedEdit }
                allowedRoots += [selected, shared]
                guard let registration = try metadata(selected.appendingPathComponent("gitdir"), required: true),
                      let registrationText = String(data: registration, encoding: .utf8),
                      try path(registrationText.trimmingCharacters(in: .newlines), relativeTo: selected).resolvingSymlinksInPath() == marker.resolvingSymlinksInPath(),
                      let relation = try metadata(selected.appendingPathComponent("commondir"), required: true),
                      let relationText = String(data: relation, encoding: .utf8),
                      try path(relationText.trimmingCharacters(in: .newlines), relativeTo: selected).resolvingSymlinksInPath() == shared else { throw LSPError.unsupportedEdit }
                common = shared
            } else {
                // Normal and --separate-git-dir repositories have their own
                // objects/HEAD. Only these fixed metadata names are inspected.
                guard try directory(selected.appendingPathComponent("objects")),
                      FileManager.default.fileExists(atPath: selected.appendingPathComponent("HEAD").path),
                      !FileManager.default.fileExists(atPath: selected.appendingPathComponent("commondir").path) else { throw LSPError.unsupportedEdit }
                allowedRoots.append(selected); common = selected
            }
            guard let bytes = try metadata(selected.appendingPathComponent("HEAD"), required: true), let head = String(data: bytes, encoding: .utf8) else { throw LSPError.unsupportedEdit }
            if head.hasPrefix("ref: refs/heads/") { branch = String(head.dropFirst(16)).trimmingCharacters(in: .newlines) }
            else { guard head.trimmingCharacters(in: .newlines).range(of: #"^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"#, options: .regularExpression) != nil else { throw LSPError.unsupportedEdit } }
        }
        private func boolean(_ value: String?) throws -> Bool {
            guard let value else { return true }
            let text = "[value]\nflag = \(quoted(value))\n"
            let result = try git(["config", "--file", "-", "--no-includes", "--type=bool", "--get", "value.flag"], input: Data(text.utf8))
            guard result.0 == 0 else { throw LSPError.unsupportedEdit }
            return result.1 == Data("true\n".utf8)
        }
        private func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\""
        }
        private func matches(_ pattern: String, candidate: String, folded: Bool) throws -> Bool {
            guard !pattern.contains("\n"), !pattern.contains("\0"), !pattern.hasSuffix("\\") else { throw LSPError.unsupportedEdit }
            try configure(caseSensitive: !folded)
            // An anchored ignore rule uses Git's native wildmatch. Explicitly
            // unignore every proper parent so a parent match cannot stand in
            // for an exact includeIf match; keep ** at its original boundary.
            let pieces = candidate.split(separator: "/", omittingEmptySubsequences: false)
            var rules = "/" + pattern + "\n"
            for count in 1..<pieces.count {
                var prefix = pieces.prefix(count).joined(separator: "/")
                for character in ["\\", "*", "?", "[", "]"] { prefix = prefix.replacingOccurrences(of: character, with: "\\" + character) }
                rules += "!/" + prefix + "/\n"
            }
            try Data(rules.utf8).write(to: shadow.appendingPathComponent(".gitignore"))
            let result = try git(["check-ignore", "--no-index", "--quiet", "--", candidate])
            guard result.0 == 0 || result.0 == 1 else { throw LSPError.unsupportedEdit }
            return result.0 == 0
        }
        private func includeMatches(_ condition: String, source: URL) throws -> Bool {
            if condition.hasPrefix("gitdir:") || condition.hasPrefix("gitdir/i:") {
                let folded = condition.hasPrefix("gitdir/i:")
                var pattern = String(condition.dropFirst(folded ? 9 : 7))
                if pattern.hasPrefix("~/") { pattern = home.path + "/" + pattern.dropFirst(2) }
                else if pattern.hasPrefix("./") { pattern = try realPath(source.deletingLastPathComponent()) + "/" + pattern.dropFirst(2) }
                else if !pattern.hasPrefix("/") { pattern = "**/" + pattern }
                if pattern.hasSuffix("/") { pattern += "**" }
                if pattern.hasPrefix("/") { pattern.removeFirst() }
                for candidate in aliases {
                    if try matches(pattern, candidate: String(candidate.dropFirst()), folded: folded) { return true }
                }
                return false
            }
            if condition.hasPrefix("onbranch:") {
                guard let branch else { return false }
                var pattern = String(condition.dropFirst(9)); if pattern.hasSuffix("/") { pattern += "**" }
                return try matches(pattern, candidate: branch, folded: false)
            }
            // Unknown conditional semantics must never omit a possible exclusion.
            throw LSPError.unsupportedEdit
        }
        mutating func configuration(_ url: URL, required: Bool = false) throws {
            guard !activeConfigs.contains(url), activeConfigs.count < 11 else { throw LSPError.unsupportedEdit }
            guard let bytes = try metadata(url, required: required) else { return }
            activeConfigs.insert(url); defer { activeConfigs.remove(url) }
            let result = try git(["config", "--file", "-", "--no-includes", "--null", "--get-regexp", #"^(core.ignorecase|core.precomposeunicode|core.excludesfile|extensions.worktreeconfig|include.path|includeif\..*\.path)$"#], input: bytes)
            guard result.0 == 0 || result.0 == 1, let text = String(data: result.1, encoding: .utf8) else { throw LSPError.unsupportedEdit }
            for entry in text.split(separator: "\0") {
                let fields = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(fields[0]), value = fields.count == 2 ? String(fields[1]) : nil
                switch key {
                    case "core.ignorecase": ignoreCase = try boolean(value)
                    case "core.precomposeunicode": precomposeUnicode = try boolean(value)
                    case "extensions.worktreeconfig": worktreeConfig = try boolean(value)
                    case "core.excludesfile":
                        guard let value else { throw LSPError.unsupportedEdit }
                        excludesFile = value.isEmpty ? nil : try path(value, relativeTo: root)
                    case "include.path":
                        guard let value else { throw LSPError.unsupportedEdit }
                        try configuration(path(value, relativeTo: url.deletingLastPathComponent()))
                    default:
                        guard key.hasPrefix("includeif."), key.hasSuffix(".path"), let value else { throw LSPError.unsupportedEdit }
                        let condition = String(key.dropFirst(10).dropLast(5))
                        if try includeMatches(condition, source: url) { try configuration(path(value, relativeTo: url.deletingLastPathComponent())) }
                }
            }
        }
        mutating func permits(_ parts: [String]) throws -> Bool {
            try discover()
            let environment = ProcessInfo.processInfo.environment
            for (name, expected) in [("GIT_DIR", admin), ("GIT_COMMON_DIR", common), ("GIT_WORK_TREE", Optional(root))] {
                if let value = environment[name] {
                    guard let expected, try path(value, relativeTo: root).resolvingSymlinksInPath() == expected else { throw LSPError.unsupportedEdit }
                }
            }
            excludesFile = userConfigDirectory.appendingPathComponent("ignore")
            if let value = environment["GIT_CONFIG_SYSTEM"] {
                if value != "/dev/null" { try configuration(path(value, relativeTo: root)) }
            } else if environment["GIT_CONFIG_NOSYSTEM"] == nil { try configuration(exactFiles[1]) }
            else if try !boolean(environment["GIT_CONFIG_NOSYSTEM"]) { try configuration(exactFiles[1]) }
            // Git reads XDG before ~/.gitconfig (which has the higher precedence).
            if let value = environment["GIT_CONFIG_GLOBAL"] {
                if value != "/dev/null" { try configuration(path(value, relativeTo: root)) }
            } else {
                try configuration(userConfigDirectory.appendingPathComponent("config"))
                try configuration(home.appendingPathComponent(".gitconfig"))
            }
            if let common { try configuration(common.appendingPathComponent("config"), required: true) }
            if worktreeConfig, let admin { try configuration(admin.appendingPathComponent("config.worktree")) }
            try configure(caseSensitive: !ignoreCase)
            try? FileManager.default.removeItem(at: shadow.appendingPathComponent(".gitignore"))
            if let excludesFile, excludesFile.path != "/dev/null", let bytes = try metadata(excludesFile) { try bytes.write(to: shadow.appendingPathComponent("global-exclude")) }
            if let common, let bytes = try metadata(common.appendingPathComponent("info/exclude")) { try bytes.write(to: shadow.appendingPathComponent(".git/info/exclude")) }
            // Git exclusions cannot be undone by a different .ignore layer.
            for kind in [".gitignore", ".ignore", ".copilotignore"] {
                for depth in 0..<parts.count {
                    let prefix = Array(parts.prefix(depth)), directory = prefix.reduce(shadow) { $0.appendingPathComponent($1) }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let destination = directory.appendingPathComponent(".gitignore")
                    if let bytes = try metadata((prefix + [kind]).reduce(root) { $0.appendingPathComponent($1) }) { try bytes.write(to: destination) }
                    else { try? FileManager.default.removeItem(at: destination) }
                }
                let result = try git(["check-ignore", "--no-index", "--quiet", "--", parts.joined(separator: "/")])
                guard result.0 == 0 || result.0 == 1 else { throw LSPError.unsupportedEdit }
                if result.0 == 0 { return false }
                // The subsequent independent layers do not inherit Git rules.
                try? FileManager.default.removeItem(at: shadow.appendingPathComponent("global-exclude"))
                try? FileManager.default.removeItem(at: shadow.appendingPathComponent(".git/info/exclude"))
            }
            return true
        }
        private final class Output: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
            var exceeded = false
        }
        private func git(_ arguments: [String], input: Data? = nil) throws -> (Int32, Data) {
            guard ContinuousClock.now < deadline else { throw LSPError.unsupportedEdit }
            let process = Process(), stdout = Pipe(), stdin = Pipe(), output = Output(), done = DispatchGroup()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["--no-optional-locks"] + arguments
            process.currentDirectoryURL = shadow
            process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": URL.temporaryDirectory.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0", "GIT_ATTR_NOSYSTEM": "1", "LC_ALL": "C"]
            process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
            process.standardInput = input == nil ? FileHandle.nullDevice : stdin
            if input != nil { guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw LSPError.unsupportedEdit } }
            try process.run()
            try? stdout.fileHandleForWriting.close()
            if input != nil { try? stdin.fileHandleForReading.close() }
            let timeout = DispatchWorkItem { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let seconds = max(0, min(3, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18))
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timeout)
            done.enter()
            DispatchQueue.global().async {
                defer { done.leave() }
                while let data = try? stdout.fileHandleForReading.read(upToCount: 65_536), !data.isEmpty {
                    output.lock.lock()
                    if output.data.count + data.count > 262_144 { output.exceeded = true; output.lock.unlock(); if process.isRunning { process.terminate() }; return }
                    output.data.append(data); output.lock.unlock()
                }
            }
            if let input {
                done.enter()
                DispatchQueue.global().async { defer { try? stdin.fileHandleForWriting.close(); done.leave() }; try? stdin.fileHandleForWriting.write(contentsOf: input) }
            }
            process.waitUntilExit(); timeout.cancel()
            guard done.wait(timeout: .now() + 1) == .success, process.terminationReason == .exit else { throw LSPError.unsupportedEdit }
            output.lock.lock(); defer { output.lock.unlock() }
            guard !output.exceeded else { throw LSPError.unsupportedEdit }
            return (process.terminationStatus, output.data)
        }
    }

}

enum CopilotNextEditPolicy {
    /// Derive independent changes from the public API's single outer range.
    /// Tokens compare exact UTF-16 (Swift Character equality normalizes accents).
    /// Like the reference editor, bound actual diff exploration by time rather
    /// than declaring long, otherwise simple edits unsupported by their size.
    static func hunks(_ edit: LSPText.Edit, in snapshot: String, budget: Duration = .milliseconds(50)) -> [LSPText.Edit] {
        let edit = minimized(edit, in: snapshot)
        guard edit.range.length > 0 || !edit.text.isEmpty else { return [] }
        guard edit.range.length > 0, !edit.text.isEmpty else { return [edit] }
        guard budget > .zero else { return [edit] }
        let old = (snapshot as NSString).substring(with: edit.range)
        let a = old.map { Array(String($0).utf16) }, b = edit.text.map { Array(String($0).utf16) }
        // A complete rewrite has no unchanged island to preserve.
        guard !Set(a).isDisjoint(with: Set(b)) else { return [edit] }
        guard let (removed, inserted) = diffChanges(a, b, budget: budget) else { return [edit] }
        let units = Array(edit.text.utf16)
        var result: [LSPText.Edit] = [], i = 0, j = 0, oldOffset = 0, newOffset = 0
        while i < a.count || j < b.count {
            let start = oldOffset, replacementStart = newOffset
            while i < a.count, removed.contains(i) { oldOffset += a[i].count; i += 1 }
            while j < b.count, inserted.contains(j) { newOffset += b[j].count; j += 1 }
            if start != oldOffset || replacementStart != newOffset {
                result.append(.init(range: NSRange(location: edit.range.location + start, length: oldOffset - start),
                                    text: String(decoding: units[replacementStart..<newOffset], as: UTF16.self), primary: false))
            } else if i < a.count, j < b.count {
                oldOffset += a[i].count; newOffset += b[j].count; i += 1; j += 1
            } else { return [edit] }
        }
        // Keep small word replacements readable; an unchanged letter inside a
        // word must not split Hello→Goodbye into several tiny colored fragments.
        var grouped: [LSPText.Edit] = []
        for next in result {
            if let previous = grouped.last {
                let gap = (snapshot as NSString).substring(with: NSRange(location: NSMaxRange(previous.range), length: next.range.location - NSMaxRange(previous.range)))
                if gap.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) {
                    grouped.removeLast()
                    grouped.append(.init(range: NSRange(location: previous.range.location, length: NSMaxRange(next.range) - previous.range.location), text: previous.text + gap + next.text, primary: false))
                    continue
                }
            }
            grouped.append(next)
        }
        if let last = grouped.popLast() { grouped.append(.init(range: last.range, text: last.text, primary: edit.primary)) }
        return grouped
    }
    /// Myers' shortest edit path. Sparse changes cost O((N+M)D), allowing long
    /// unchanged islands without an N*M matrix. The frontier trace stores only
    /// explored diagonals and time is checked during both exploration and snakes.
    private static func diffChanges(_ a: [[UInt16]], _ b: [[UInt16]], budget: Duration) -> (Set<Int>, Set<Int>)? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget)
        var frontier = [1: 0], trace: [[Int: Int]] = []
        for distance in 0...(a.count + b.count) {
            guard clock.now < deadline else { return nil }
            trace.append(frontier)
            for diagonal in stride(from: -distance, through: distance, by: 2) {
                if diagonal.isMultiple(of: 32), clock.now >= deadline { return nil }
                let down = diagonal == -distance || (diagonal != distance && frontier[diagonal - 1, default: -1] < frontier[diagonal + 1, default: -1])
                var x = down ? frontier[diagonal + 1, default: 0] : frontier[diagonal - 1, default: 0] + 1
                var y = x - diagonal
                while x < a.count, y < b.count, a[x] == b[y] {
                    x += 1; y += 1
                    if x.isMultiple(of: 256), clock.now >= deadline { return nil }
                }
                frontier[diagonal] = x
                guard x == a.count, y == b.count else { continue }
                var removed = Set<Int>(), inserted = Set<Int>()
                for step in stride(from: distance, through: 0, by: -1) {
                    let previous = trace[step], k = x - y
                    let cameDown = k == -step || (k != step && previous[k - 1, default: -1] < previous[k + 1, default: -1])
                    let previousK = cameDown ? k + 1 : k - 1
                    let previousX = previous[previousK, default: 0], previousY = previousX - previousK
                    while x > previousX, y > previousY { x -= 1; y -= 1 }
                    if step > 0 {
                        if x == previousX { y -= 1; inserted.insert(y) }
                        else { x -= 1; removed.insert(x) }
                    }
                }
                return (removed, inserted)
            }
        }
        return nil
    }
    static func combined(_ edits: [LSPText.Edit], in snapshot: String) -> LSPText.Edit? {
        guard let first = edits.first, let last = edits.last else { return nil }
        let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        var replacement = (snapshot as NSString).substring(with: range)
        for edit in edits.reversed() {
            replacement = (replacement as NSString).replacingCharacters(in: NSRange(location: edit.range.location - range.location, length: edit.range.length), with: edit.text)
        }
        return .init(range: range, text: replacement, primary: true)
    }
    static func rebasedHunks(_ edits: [LSPText.Edit], from before: String, to after: String) -> [LSPText.Edit]? {
        var result = edits, intermediate = before
        let observed = hunks(.init(range: NSRange(location: 0, length: before.utf16.count), text: after, primary: true), in: before)
        // Apply an observed multi-range transaction from the end so its original
        // offsets remain valid. Unrelated changes must not become one artificial
        // overlapping range around an otherwise unchanged proposed hunk.
        for change in observed.reversed() {
            let updated = (intermediate as NSString).replacingCharacters(in: change.range, with: change.text)
            var remaining: [LSPText.Edit] = []
            for edit in result {
                if let rebased = rebase(edit, from: intermediate, to: updated) { remaining.append(rebased) }
                else if !LSPText.sameText((intermediate as NSString).replacingCharacters(in: edit.range, with: edit.text), updated) { return nil }
            }
            result = remaining; intermediate = updated
        }
        guard !result.isEmpty, LSPText.sameText(intermediate, after) else { return nil }
        return result.enumerated().map { index, edit in .init(range: edit.range, text: edit.text, primary: index == result.count - 1) }
    }
    static func minimized(_ edit: LSPText.Edit, in snapshot: String) -> LSPText.Edit {
        let old = (snapshot as NSString).substring(with: edit.range)
        var a = old.startIndex, b = edit.text.startIndex, aEnd = old.endIndex, bEnd = edit.text.endIndex
        while a < aEnd, b < bEnd, String(old[a]).utf16.elementsEqual(String(edit.text[b]).utf16) {
            old.formIndex(after: &a); edit.text.formIndex(after: &b)
        }
        while a < aEnd, b < bEnd {
            let previousA = old.index(before: aEnd), previousB = edit.text.index(before: bEnd)
            guard String(old[previousA]).utf16.elementsEqual(String(edit.text[previousB]).utf16) else { break }
            aEnd = previousA; bEnd = previousB
        }
        let removedPrefix = old[..<a].utf16.count, removedSuffix = old[aEnd...].utf16.count
        return .init(range: NSRange(location: edit.range.location + removedPrefix, length: edit.range.length - removedPrefix - removedSuffix),
                     text: String(edit.text[b..<bEnd]), primary: edit.primary)
    }
    static func directAccept(snapshot: String, caret: Int, range: NSRange, continuing: Bool, visible: Bool) -> Bool {
        let source = snapshot as NSString
        guard caret >= 0, range.location >= 0, range.length >= 0, caret <= source.length, NSMaxRange(range) <= source.length else { return false }
        let caretLine = (try? LSPText.position(caret, in: snapshot)["line"].int) ?? 0
        let startLine = (try? LSPText.position(range.location, in: snapshot)["line"].int) ?? 0
        let endLine = (try? LSPText.position(NSMaxRange(range), in: snapshot)["line"].int) ?? 0
        return (caretLine >= startLine - 1 && caretLine <= endLine + 1) || (continuing && visible)
    }
    /// Rebase one contiguous user edit. Overlapping conflicts are rejected; matching typed
    /// prefixes consume the proposal. Never interprets an old server response as a new one.
    static func rebase(_ edit: LSPText.Edit, from before: String, to after: String) -> LSPText.Edit? {
        guard !before.utf16.elementsEqual(after.utf16) else { return edit }
        let change = minimized(.init(range: NSRange(location: 0, length: before.utf16.count), text: after, primary: true), in: before)
        let delta = change.text.utf16.count - change.range.length
        if NSMaxRange(change.range) <= edit.range.location, !(change.range.length == 0 && change.range.location == edit.range.location) {
            return .init(range: NSRange(location: edit.range.location + delta, length: edit.range.length), text: edit.text, primary: edit.primary)
        }
        if change.range.location >= NSMaxRange(edit.range), !(change.range.length == 0 && change.range.location == edit.range.location) { return edit }
        if change.range.location == edit.range.location, change.range.length <= edit.range.length, edit.text.utf16.starts(with: change.text.utf16), !change.text.isEmpty {
            let text = (edit.text as NSString).substring(from: change.text.utf16.count)
            let range = NSRange(location: edit.range.location + change.text.utf16.count, length: edit.range.length - change.range.length)
            guard range.length > 0 || !text.isEmpty else { return nil }
            return .init(range: range, text: text, primary: edit.primary)
        }
        return nil
    }
}
