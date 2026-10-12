// Modified for the unofficial CompEditor fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Bundled public configuration only. No credential discovery or unsigned fallback.
struct ForkUpdatePolicy {
    static let upstreamKey = "BouLWwqNvz1a8USmfRPmtooMFjc27w3JPrT/VTuZQaI="
    let feed: URL
    enum Failure: Error { case missingConfiguration, invalidConfiguration }

    init(info: [String: Any], identifier: String?) throws {
        guard identifier == "dev.local.SemanticEditor",
              let rawFeed = info["SUFeedURL"] as? String, !rawFeed.isEmpty,
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty else { throw Failure.missingConfiguration }
        guard key != Self.upstreamKey, let decoded = Data(base64Encoded: key), decoded.count == 32,
              decoded.contains(where: { $0 != 0 }), Self.allowedFeed(rawFeed),
              info["SURequireSignedFeed"] as? Bool == true,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              (info["SUSignedFeedFailureExpirationInterval"] as? NSNumber)?.doubleValue == 0,
              info["SUEnableAutomaticChecks"] as? Bool == false,
              info["SUAllowsAutomaticUpdates"] as? Bool == false,
              info["SUSendProfileInfo"] as? Bool == false else { throw Failure.invalidConfiguration }
        feed = URL(string: rawFeed)!
    }
    private static func secure(_ raw: String) -> URLComponents? {
        guard let c = URLComponents(string: raw), c.scheme == "https", c.user == nil, c.password == nil,
              c.port == nil || c.port == 443, c.query == nil, c.fragment == nil,
              !c.percentEncodedPath.contains("%"), !c.path.split(separator: "/").contains("..") else { return nil }
        return c
    }
    static func allowedFeed(_ raw: String) -> Bool {
        guard let c = secure(raw) else { return false }
        switch c.host?.lowercased() {
            case "kdu-i.github.io": return c.path == "/CompEditor/appcast.xml"
            case "github.com": return c.path == "/KDU-i/CompEditor/releases/latest/download/appcast.xml"
            case "raw.githubusercontent.com": return c.path == "/KDU-i/CompEditor/main/appcast.xml"
            default: return false
        }
    }
    static func allowedArchive(_ url: URL) -> Bool {
        guard let c = secure(url.absoluteString), c.host?.lowercased() == "github.com",
              c.path.hasPrefix("/KDU-i/CompEditor/releases/download/"), c.path.hasSuffix(".zip") else { return false }
        return c.path.split(separator: "/").count == 6
    }
    static func canInstall(hasUnsavedDocuments: Bool) -> Bool { !hasUnsavedDocuments }
}
