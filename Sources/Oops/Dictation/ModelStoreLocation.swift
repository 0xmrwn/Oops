import Foundation

/// Where downloaded speech models live: `Application Support/oops/Models`, beside the app's other files.
enum ModelStoreLocation {
    /// The folder, whether or not it exists yet: a download creates it.
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("oops/Models", isDirectory: true)

    /// Created when first asked for, so a store can write into it at once.
    static func directory() throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
