import Foundation
@main struct CopilotParityTests {
    static func main() async throws {
        func check(_ value: @autoclosure () -> Bool, _ name: String) { guard value() else { fatalError(name) }; print("PASS: " + name) }
        func item(_ text: String, _ range: NSRange, _ insert: String) throws -> LSPJSON { .object(["range": try CopilotInline.rangeJSON(range, in: text), "insertText": .string(insert)]) }
        let url = "requests.post(\"https://exam\")", caret = "requests.post(\"https://exam".utf16.count
        let proposed = "requests.post(\"https://example.invalid/path\")"
        let middle = try CopilotInline.plan(item(url, NSRange(location:0,length:url.utf16.count),proposed),text:url,caret:caret)
        check(middle.parts.count == 1 && middle.parts[0].text == "ple.invalid/path", "middle-of-string suffix preserved, no duplicate quotes/brackets")
        check((url as NSString).replacingCharacters(in:middle.edit.range,with:middle.edit.text)==proposed,"original provider range applied exactly once")
        do { _ = try CopilotInline.plan(item("abc",NSRange(location:0,length:3),"ax"),text:"abc",caret:1); fatalError("deletion shown as ghost") } catch { print("PASS: deletion/rewriting refused as thin ghost") }
        let parts = try CopilotInline.plan(item("f()",NSRange(location:0,length:3),"f(x) + y"),text:"f()",caret:2)
        check(parts.parts.count==2 && parts.parts[0].offset==2 && parts.parts[1].offset==3,"multiple insertion gaps retain existing suffix scalars")
        let emoji = try CopilotInline.plan(item("😀\"",NSRange(location:0,length:3),"😀alpha\""),text:"😀\"",caret:2)
        check(emoji.parts.first?.text=="alpha","non-BMP UTF-16 prefix and suffix preserved")
        check(CopilotInline.partialLength("sum(numbers)",line:false)==3,"word acceptance stops at identifier boundary")
        check(CopilotInline.partialLength("  sum",line:false)==2,"leading whitespace partial accept follows VS Code boundary behavior")
        check(CopilotInline.partialLength(".filter",line:false)==1,"punctuation before next word accepted separately")
        check(CopilotInline.partialLength("one\r\nnext",line:true)==5,"line acceptance includes complete CRLF")
        check(CopilotInline.acceptedLength(raw:"a\nb",normalizedPrefixLength:3,snapshot:"x\r\n")==2,"normalized CRLF accepted prefix maps to provider UTF-16")
        check(CopilotInline.acceptedLength(raw:"😀sum",normalizedPrefixLength:5,snapshot:"")==5,"partial feedback counts cumulative UTF-16 including non-BMP prefix")
        let fallback = try CopilotInline.plan(.object(["insertText":.string("print")]),text:"pri",caret:3)
        check(fallback.edit.range==NSRange(location:0,length:3)&&fallback.text=="nt","omitted provider range uses word range")
        check(CopilotLanguage.resolve(url:URL(fileURLWithPath:"/synthetic/notes.txt"),syntax:"Python")=="python","saved nonmatching extension respects language mode")
        check(CopilotLanguage.resolve(url:URL(fileURLWithPath:"/synthetic/Test.java"),syntax:"Python")=="python","syntax controls request and preview identity consistently")
        check(CopilotLanguage.resolve(url:nil,syntax:"TypeScript")=="typescript","unsaved other-language mode has consistent languageId")
        let selected=LSPText.Edit(range:NSRange(location:0,length:3),text:"print",primary:true)
        let extended=try CopilotInline.plan(item("pri",NSRange(location:0,length:3),"print(value)"),text:"pri",caret:3)
        check(CopilotInline.extends(extended,selected:selected,snapshot:"pri"),"AI extension compatible with selected normal suggestion")
        check(!CopilotInline.extends(extended,selected:.init(range:selected.range,text:"private",primary:true),snapshot:"pri"),"incompatible selected normal suggestion hides AI")
        let rewrite=try CopilotInline.nextEdit(item("abc",NSRange(location:0,length:3),"xyz"),text:"abc")
        check(rewrite.text=="xyz"&&rewrite.range.length==3,"NES supports explicit rewrite range separately")
        let root=URL(fileURLWithPath:CommandLine.arguments[1]);let peer=root.appendingPathComponent("SemanticTests/copilot_mock.py")
        let client=LSPClient(processes:.copilot)
        try await client.start(.init(language:.python,executable:"/usr/bin/python3",arguments:[peer.path]),workspace:root,copilot:true)
        let uri=root.appendingPathComponent("SemanticTests/ParitySynthetic.py")
        let automatic=try await client.inlineCompletion(uri:uri,languageId:"python",text:"x",caret:1,triggerKind:2)
        check(automatic["items"].array?.count==1,"automatic LSP triggerKind=2")
        let manual=try await client.inlineCompletion(uri:uri,languageId:"python",text:"x",caret:1,triggerKind:1)
        check(manual["items"].array?.count==2,"manual LSP triggerKind=1 retrieves alternatives")
        _=try await client.inlineCompletion(uri:uri,languageId:"javascript",text:"x",caret:1,triggerKind:1)
        let mode=try await client.request("test/parity",.object([:]))
        check(mode["languageId"].string=="javascript"&&mode["trigger"].int==1,"language change closes/reopens same document with current languageId")
        try await client.notify("textDocument/didPartiallyAcceptCompletion",.object(["item":manual["items"].array![0],"acceptedLength":.number(3)]))
        try await client.notify("textDocument/didPartiallyAcceptCompletion",.object(["item":manual["items"].array![0],"acceptedLength":.number(8)]))
        _=try await client.inlineCompletion(uri:uri,languageId:"javascript",text:"x",caret:1,triggerKind:1,tabSize:2,insertSpaces:false)
        let formatting=try await client.request("test/parity",.object([:]))
        check(formatting["formatting"]["tabSize"].int==2 && formatting["formatting"]["insertSpaces"] == .bool(false),"request uses current document indentation preferences")
        let nes=try await client.nextEdit(uri:uri,languageId:"python",text:"x",caret:1)
        let next=nes["edits"].array![0];try await client.notify("textDocument/didShowInlineEdit",.object(["item":next]))
        let events=try await client.request("test/parity",.object([:]))
        check(events["partials"].array==[.number(3),.number(8)],"partial feedback is cumulative, not per-action delta")
        check(events["shownNext"].int==1,"NES API and separate actual-show notification")
        do { _=try await client.nextEdit(uri:uri,languageId:"python",text:"NO_NES",caret:6);fatalError("method not found ignored") } catch LSPError.methodNotFound { print("PASS: public NES method-not-found distinct from empty result") }
        await client.stop();LSPProcesses.copilot.stopAll()
        print("All parity model/protocol checks passed. Offline fixtures only; no OAuth or network.")
    }
}
