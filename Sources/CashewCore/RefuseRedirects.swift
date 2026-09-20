import Foundation

/// Refuses every redirect, on every session Cashew makes.
///
/// For the usage request this is the load-bearing half of a promise SECURITY.md makes: the bearer
/// token goes to exactly one host. Without it that promise rests on CFNetwork's uncontracted
/// behaviour for `Authorization` across a cross-host hop, for an endpoint we already expect to
/// drift. A 3xx instead surfaces as an ordinary `UsageError.http`.
///
/// The update check carries no token, so the stakes there are far lower — but it does send
/// `User-Agent: Cashew/<version>`, and a GitHub 301 (a repo rename or transfer) would forward it to
/// whatever host the `Location` names. It was left following redirects when this type was private to
/// `ClaudeProvider`, which is the whole reason the type now lives in its own file: one policy, both
/// sessions, and a security document that can state one rule instead of describing an asymmetry.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
