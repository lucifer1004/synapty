import Foundation

/// Does the page an agent exposed actually answer?
///
/// THE OTHER HALF OF `expose`. Exposing was write-only: an agent could put
/// a page in front of a human and had no way to learn whether it loaded,
/// what it said, or that it had failed — so a dev server that died left
/// the agent confidently pointing at nothing.
///
/// WHAT IT REPORTS IS THE SERVICE, NOT THE HUMAN'S SCREEN, and the
/// distinction is deliberate. The web view is created only while someone
/// is looking at that panel, so "what is rendered" is unanswerable most of
/// the time and would make the reply depend on where the human happens to
/// be looking. Whether the forwarded address answers is a fact about the
/// agent's own service, always available and the one it can act on.
enum ViewProbe {

    /// Long enough for a local forward to a service that is up, short
    /// enough that a dead one is reported rather than waited on.
    private static let timeout: TimeInterval = 6

    static func check(_ target: [String: Any]) -> [String: Any] {
        var out = target
        out.removeValue(forKey: "title")
        guard let raw = target["url"] as? String, let url = URL(string: raw) else {
            out["reachable"] = false
            out["error"] = "no address"
            return out
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // A HEAD would be cheaper and would not answer the question: the
        // title is the one thing that tells an agent it reached ITS page
        // rather than some other service that took the port.
        request.httpMethod = "GET"

        let semaphore = DispatchSemaphore(value: 0)
        var status: Int?
        var title: String?
        var failure: String?
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { failure = error.localizedDescription; return }
            status = (response as? HTTPURLResponse)?.statusCode
            if let data { title = htmlTitle(in: data) }
        }.resume()
        // Bounded twice on purpose: URLSession's own timeout can be
        // outlived by a stalled connection, and a probe that hangs would
        // hang the tool call that asked for it.
        _ = semaphore.wait(timeout: .now() + timeout + 2)

        out["reachable"] = status != nil
        if let status { out["http_status"] = status }
        if let title, !title.isEmpty { out["title"] = title }
        if let failure { out["error"] = failure }
        return out
    }

    /// First `<title>`, decoded leniently: the page belongs to somebody
    /// else and does not promise UTF-8 or well-formed markup.
    static func htmlTitle(in data: Data) -> String? {
        let text = String(decoding: data.prefix(64 * 1024), as: UTF8.self).lowercased()
        guard let open = text.range(of: "<title"),
              let gt = text.range(of: ">", range: open.upperBound..<text.endIndex),
              let close = text.range(of: "</title>", range: gt.upperBound..<text.endIndex)
        else { return nil }
        // Sliced from the ORIGINAL, so the reported title keeps its case.
        let original = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        let start = original.index(original.startIndex,
                                   offsetBy: text.distance(from: text.startIndex, to: gt.upperBound))
        let end = original.index(original.startIndex,
                                 offsetBy: text.distance(from: text.startIndex, to: close.lowerBound))
        return String(original[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
