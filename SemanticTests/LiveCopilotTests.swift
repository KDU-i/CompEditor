import Foundation
@main struct LiveCopilotTests {
    static func main() async {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let client = LSPClient(processes: .copilot)
        await client.setMessageHandler { method, value in
            if method == "didChangeStatus", let kind = value["kind"].string, ["Normal","Error","Warning","Inactive"].contains(kind) { print("STATUS: " + kind) }
            return .null
        }
        do {
            try await client.start(.init(language:.python, executable:CommandLine.arguments[1], arguments:["--stdio"]),workspace:root,copilot:true)
            print("START: official stdio initialized; no signIn or credential access by harness")
            if CommandLine.arguments.contains("--cancel-only") {
                let text = "# Fresh synthetic cancellation fixture only.\ndef subtract_one(number: int) -> int:\n    return "
                let uri = root.appendingPathComponent("Cancellation.py")
                let request = Task { () throws -> Date in
                    _ = try await client.inlineCompletion(uri:uri,language:.python,text:text,caret:text.utf16.count)
                    return Date()
                }
                try await Task.sleep(for:.milliseconds(1)); let cancelledAt=Date(); request.cancel()
                do { let returned = try await request.value; print(returned < cancelledAt ? "RACE: request completed before cancellation" : "FAIL: response returned after cancellation") }
                catch is CancellationError { print("PASS LIVE: pending official request cancelled after 1ms; no completion returned") }
                catch { report(error,stage:"cancel") }
                await client.stop(); LSPProcesses.copilot.stopAll(); return
            }
            for language in LSPLanguage.allCases {
                let text = language == .python ? "# Synthetic public arithmetic fixture only.\ndef sum_even_numbers(numbers: list[int]) -> int:\n    \"\"\"Return the sum of even numbers.\"\"\"\n    " : "public class SyntheticMath {\n    // Return the sum of the even integers in numbers.\n    public static int sumEvenNumbers(int[] numbers) {\n        "
                let uri = root.appendingPathComponent(language == .python ? "SyntheticMath.py" : "SyntheticMath.java")
                try text.write(to:uri,atomically:true,encoding:.utf8)
                do {
                    let value = try await client.inlineCompletion(uri:uri,language:language,text:text,caret:text.utf16.count)
                    let items = value["items"].array ?? []
                    print("RESULT: \(language.rawValue) items=\(items.count)")
                    for item in items.prefix(2) {
                        print("SHAPE: insertString=\(item["insertText"].string != nil) insertObject=\(item["insertText"].object != nil) objectKind=\(item["insertText"]["kind"].string ?? "none") rangeStart=\(item["range"]["start"]) rangeEnd=\(item["range"]["end"])")
                        do { let edit = try CopilotInline.edit(item,text:text,caret:text.utf16.count); print("EDIT: valid bytes=\(edit.text.utf8.count) range=\(edit.range)") }
                        catch { print("EDIT: rejected type=\(String(describing:type(of:error)))") }
                    }
                } catch { report(error,stage:language.rawValue); print("TRANSPORT: \(await client.stopReason)") }
            }
            let raceURI = root.appendingPathComponent("Race.py")
            let first = "# New non-confidential race fixture.\ndef add_one(number: int) -> int:\n    return "
            let revised = "# New non-confidential race fixture.\ndef add_two(number: int) -> int:\n    return "
            let stale = Task { () throws -> Date in
                _ = try await client.inlineCompletion(uri:raceURI,language:.python,text:first,caret:first.utf16.count)
                return Date()
            }
            try await Task.sleep(for:.milliseconds(40))
            let changed = Date()
            try await client.synchronizeDocument(uri:raceURI,language:.python,text:revised)
            do {
                let returned = try await stale.value
                if returned < changed { print("RACE: old request completed before mutation; no stale result displayed") }
                else { print("FAIL: stale completion returned after document mutation") }
            } catch is CancellationError { print("PASS LIVE: stale response suppressed after document mutation") }
            catch { print("PASS LIVE: server discarded superseded request; no stale result returned") }
            let cancelled = Task { () throws -> Date in
                _ = try await client.inlineCompletion(uri:raceURI,language:.python,text:first,caret:first.utf16.count)
                return Date()
            }
            try await Task.sleep(for:.milliseconds(40)); let cancelledAt=Date(); cancelled.cancel()
            do { let returned = try await cancelled.value; print(returned < cancelledAt ? "RACE: request completed before cancellation" : "FAIL: completion returned after cancellation") }
            catch is CancellationError { print("PASS LIVE: pending official inline request cancelled") }
            catch { print("PASS LIVE: cancelled request returned no completion") }
            await client.stop()
            do { _ = try await client.inlineCompletion(uri:raceURI,language:.python,text:first,caret:first.utf16.count); print("FAIL: stopped client synchronized document") }
            catch { print("PASS LIVE: OFF refuses document synchronization") }
        } catch { report(error,stage:"start"); print("TRANSPORT: \(await client.stopReason)") }
        await client.stop(); LSPProcesses.copilot.stopAll()
    }
    static func report(_ error:any Error,stage:String) {
        let reason:String
        switch error {
        case LSPError.timeout: reason="timeout"
        case LSPError.stopped: reason="stopped"
        case LSPError.unsupportedEdit: reason="unsupported-edit"
        case LSPError.invalidConfiguration: reason="invalid-configuration"
        case LSPError.server(let message):
            let lower=message.lowercased()
            if lower.contains("sign") || lower.contains("auth") { reason="authentication-required" }
            else if lower.contains("quota") || lower.contains("limit") { reason="quota-or-limit" }
            else if lower.contains("method") { reason="method-or-parameter-error" }
            else if lower.contains("sync") || lower.contains("encoding") { reason="synchronization-or-encoding" }
            else { reason="server-error" }
        default: reason=String(describing:type(of:error))
        }
        print("FAIL: \(stage) \(reason); no raw error/auth data logged")
    }
}
