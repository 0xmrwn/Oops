import Foundation

public struct ClaudeAgentFolder: Sendable {
    public let url: URL

    public static func make(in parent: URL, skills: URL?) throws -> Self {
        let files = FileManager.default
        try files.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = parent.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            if let skills {
                let config = url.appendingPathComponent(".claude")
                try files.createDirectory(at: config, withIntermediateDirectories: false)
                try files.createSymbolicLink(at: config.appendingPathComponent("skills"), withDestinationURL: skills)
            }
            return Self(url: URL(fileURLWithPath: realPath(url)))
        } catch {
            try? files.removeItem(at: url)
            throw error
        }
    }

    public func remove() { try? FileManager.default.removeItem(at: url) }

    public static func sweep(_ parent: URL, olderThan: TimeInterval = 600) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let urls = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: Array(keys))
        for url in urls ?? [] where UUID(uuidString: url.lastPathComponent) != nil {
            guard let values = try? url.resourceValues(forKeys: keys), values.isDirectory == true, values.isSymbolicLink == false,
                  let date = values.contentModificationDate, date.timeIntervalSinceNow < -olderThan else { continue }
            Self(url: url).remove()
        }
    }

    public static func skillDirectories(_ skills: URL) -> [String] {
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(at: skills, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return [] }
        var paths = [realPath(skills)]
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            var directory: ObjCBool = false
            guard (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true,
                  files.fileExists(atPath: entry.path, isDirectory: &directory), directory.boolValue else { continue }
            let path = realPath(entry)
            if !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    static func realPath(_ url: URL) -> String {
        guard let path = realpath(url.path, nil) else { return url.path }
        defer { free(path) }
        return String(cString: path)
    }
}
