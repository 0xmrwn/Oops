import Foundation

/// UserDefaults supports concurrent access to its individual reads and writes.
public struct ActionStore: @unchecked Sendable {
    public static let key = "Actions"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// A missing library is the starters; an emptied one stays empty. One this build cannot read is set aside
    /// rather than overwritten, and the starters stand in.
    public func load() -> ActionLibrary {
        guard let stored = defaults.object(forKey: Self.key) else { return .starters }
        guard let data = stored as? Data, var library = try? JSONDecoder().decode(ActionLibrary.self, from: data), library.version == 1 else {
            defaults.set(stored, forKey: Self.key + ".unreadable")
            return .starters
        }
        var places = Set<ActionPlace>(), ids = Set<UUID>()
        library.actions = library.actions.filter { !ids.contains($0.id) && places.insert($0.place).inserted && ids.insert($0.id).inserted }.map { $0.normalized() }
        return library
    }

    public func save(_ library: ActionLibrary) {
        if let data = try? JSONEncoder().encode(library) { defaults.set(data, forKey: Self.key) }
    }
}
