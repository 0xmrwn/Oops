import Foundation

/// Fetches models.dev's transcription feed at run time and keeps the last good copy on disk. It is never
/// bundled: the feed changes as providers add models, and a stale bundled copy would hide them.
public struct ModelsDevClient: Sendable {
    public static let feedURL = URL(string: "https://models.dev/api.json?type=transcription")!

    let session: URLSession
    let directory: URL
    var feedFile: URL { directory.appendingPathComponent("transcription.json") }
    var tagFile: URL { directory.appendingPathComponent("transcription.etag") }

    public init(session: URLSession = .shared, directory: URL) { self.session = session; self.directory = directory }

    /// The copy on disk, without the network; nil when there is none or it doesn't decode.
    public func cached() -> ModelsDevFeed? {
        (try? Data(contentsOf: feedFile)).flatMap { try? ModelsDevFeed.decode($0) }
    }

    /// Revalidates with the stored ETag: a 304 keeps the copy on disk, a 200 that decodes replaces it, and
    /// anything else (offline, an error status, a body that doesn't decode) falls back to it. Never throws:
    /// nil only when there is neither an answer nor a copy.
    public func load() async -> ModelsDevFeed? {
        let cached = cached()
        // The system cache would turn a 304 into its own 200; the ETag here is the only cache.
        var request = URLRequest(url: Self.feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if cached != nil, let tag = try? String(contentsOf: tagFile, encoding: .utf8), !tag.isEmpty {
            request.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return cached }
        guard http.statusCode == 200, let feed = try? ModelsDevFeed.decode(data) else { return cached }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: feedFile, options: .atomic)
        let tag = http.value(forHTTPHeaderField: "ETag") ?? ""
        try? Data(tag.utf8).write(to: tagFile, options: .atomic)
        return feed
    }
}
