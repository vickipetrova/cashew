import Foundation
import CashewShared

struct Release: Equatable {
    let version: [Int]
    let tag: String
    let url: URL
}

/// Once a day, asks GitHub whether a newer Cashew has been published.
///
/// Cashew's second network destination, and the only one besides the usage endpoint (hard rule 5).
/// It sends no identifiers, can be turned off, and never downloads anything: it only puts a menu item
/// up that opens the release page.
///
/// `releases/latest` returns the newest release that is neither a draft nor a pre-release, and 404
/// when there is none (GitHub REST docs) — which is the normal answer until the first release, and is
/// treated as "no update", silently.
enum UpdateCheck {
    static let endpoint = URL(string: "https://api.github.com/repos/vickipetrova/cashew/releases/latest")!
    static let releasePathPrefix = "/vickipetrova/cashew/"
    /// Not at launch: the first seconds belong to the usage poll and the menu bar appearing.
    static let launchDelay: TimeInterval = 60
    static let interval: TimeInterval = 24 * 3600

    /// "Automatically" is dropped: it said when but never what, and a once-a-day check is what
    /// anyone assumes this means anyway. The README covers the detail.
    static let settingsTitle = "Check for Updates"

    static func menuTitle(_ release: Release) -> String { "Update Available: \(release.tag)…" }

    /// `v0.2.0` → `[0, 2, 0]`. Anything with a suffix (`-beta.1`) is nil: `latest` excludes
    /// pre-releases already, and an odd tag is safer ignored than misread.
    static func version(_ string: String) -> [Int]? {
        var text = Substring(string)
        if text.hasPrefix("v") || text.hasPrefix("V") { text = text.dropFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard (1...6).contains(part.count), part.allSatisfy({ ("0"..."9").contains($0) }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    /// Component-wise, missing components count as zero, so `0.1` equals `0.1.0`.
    static func isNewer(_ candidate: [Int], than current: [Int]) -> Bool {
        for index in 0..<max(candidate.count, current.count) {
            let left = index < candidate.count ? candidate[index] : 0
            let right = index < current.count ? current[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    static func release(in object: [String: Any]) -> Release? {
        guard let tag = object["tag_name"] as? String, let version = version(tag),
              let raw = object["html_url"] as? String, let url = URL(string: raw),
              url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix(releasePathPrefix) else { return nil }
        for flag in ["draft", "prerelease"] {
            if let value = object[flag], isJSONBoolean(value), (value as? Bool) == true { return nil }
        }
        return Release(version: version, tag: tag, url: url)
    }

    /// Everything between the socket and the menu, pure — the same split as `ClaudeProvider.result`.
    static func available(data: Data?, response: URLResponse?, error: Error?,
                          currentVersion: String) -> Release? {
        guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let release = release(in: object) else { return nil }
        return pending(known: release, currentVersion: currentVersion)
    }

    static func pending(known: Release?, currentVersion: String) -> Release? {
        guard let known, let current = version(currentVersion),
              isNewer(known.version, than: current) else { return nil }
        return known
    }

    static func isDue(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed >= interval || elapsed < 0
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// Real network. Never call from a test.
    static func fetch(currentVersion: String, completion: @escaping (Release?) -> Void) {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Required: GitHub rejects API requests without a User-Agent.
        request.setValue("Cashew/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            completion(available(data: data, response: response, error: error, currentVersion: currentVersion))
        }.resume()
    }
}
