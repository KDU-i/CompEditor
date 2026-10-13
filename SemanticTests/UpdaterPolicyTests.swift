import Foundation
@main struct UpdaterPolicyTests {
 static func main() throws {
  func check(_ value: @autoclosure () -> Bool, _ name: String) { guard value() else { fatalError(name) }; print("PASS: " + name) }
  // Synthetic public-key-shaped bytes are used only to test policy parsing; never installed in a bundle.
  let key=Data(repeating:1,count:32).base64EncodedString()
  let info:[String:Any] = ["SUFeedURL":"https://github.com/KDU-i/CompEditor/releases/latest/download/appcast.xml","SUPublicEDKey":key,"SURequireSignedFeed":true,"SUVerifyUpdateBeforeExtraction":true,"SUSignedFeedFailureExpirationInterval":0,"SUEnableAutomaticChecks":false,"SUAllowsAutomaticUpdates":false,"SUSendProfileInfo":false]
  check((try? ForkUpdatePolicy(info:info,identifier:"dev.local.SemanticEditor")) != nil,"explicit fork-only HTTPS signed-feed policy accepted")
  check((try? ForkUpdatePolicy(info:[:],identifier:"dev.local.SemanticEditor")) == nil,"missing config fails before updater startup")
  check((try? ForkUpdatePolicy(info:info,identifier:"com.coteditor.CotEditor")) == nil,"upstream bundle cannot use fork updater")
  for value in [ForkUpdatePolicy.upstreamKey,"placeholder",Data(repeating:0,count:32).base64EncodedString()] {
   var bad=info;bad["SUPublicEDKey"]=value;check((try? ForkUpdatePolicy(info:bad,identifier:"dev.local.SemanticEditor")) == nil,"upstream/invalid/zero key refused")
  }
  for flag in ["SURequireSignedFeed","SUVerifyUpdateBeforeExtraction","SUEnableAutomaticChecks","SUAllowsAutomaticUpdates","SUSendProfileInfo"] {
   var bad=info;bad[flag] = !(info[flag] as! Bool);check((try? ForkUpdatePolicy(info:bad,identifier:"dev.local.SemanticEditor")) == nil,"unsafe signature/automatic/profile flag refused: " + flag)
  }
  var fallback=info;fallback["SUSignedFeedFailureExpirationInterval"]=1;check((try? ForkUpdatePolicy(info:fallback,identifier:"dev.local.SemanticEditor")) == nil,"expired signature fallback refused")
  for url in ["http://github.com/KDU-i/CompEditor/releases/latest/download/appcast.xml","https://coteditor.com/appcast.xml","https://github.com/other/CompEditor/releases/latest/download/appcast.xml","https://github.com/KDU-i/CompEditor/releases/latest/download/appcast.xml?device=x","https://" + "synthetic:synthetic@" + "github.com/KDU-i/CompEditor/releases/latest/download/appcast.xml","https://github.com/KDU-i/CompEditor/%2E%2E/appcast.xml"] { check(!ForkUpdatePolicy.allowedFeed(url),"insecure/foreign/identifier feed refused") }
  check(ForkUpdatePolicy.allowedArchive(URL(string:"https://github.com/KDU-i/CompEditor/releases/download/v0.2.1/CompEditor-macos-arm64.zip")!),"version-fixed release ZIP allowed")
  check(!ForkUpdatePolicy.allowedArchive(URL(string:"https://github.com/KDU-i/CompEditor/releases/latest/download/CompEditor.zip")!),"mutable archive URL refused")
  check(!ForkUpdatePolicy.allowedArchive(URL(string:"https://example.invalid/update.zip")!),"foreign archive refused")
  check(!ForkUpdatePolicy.canInstall(hasUnsavedDocuments:true),"unsaved documents postpone installation")
  check(ForkUpdatePolicy.canInstall(hasUnsavedDocuments:false),"saved document state permits standard installer")
  check(!ForkUpdatePolicy.allowedFeed("file:///tmp/compeditor-signed-update-qa/feed/appcast.xml"),"distribution policy refuses local file feed")
  check((try? ForkUpdatePolicy(info:info,identifier:"dev.local.SemanticEditor.UpdaterTest")) == nil,"distribution policy refuses isolated-test bundle identity")
  print("Offline updater policy checks complete; no key generation, network or installation.")
 }
}
