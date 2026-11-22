import Foundation

/// The model picker's search: every word typed appears in the model's name or its provider's, in any case.
public enum ModelSearch {
    public static func matches(_ query: String, _ texts: String...) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { word in texts.contains { $0.lowercased().contains(word) } }
    }

    /// The row that has the highlight: the current one while it is still among `items`, else the first, so Return
    /// always acts on a row the person can see, even after a search that found nothing.
    public static func highlight<Item: Equatable>(_ current: Item?, in items: [Item]) -> Item? {
        current.flatMap { items.contains($0) ? $0 : nil } ?? items.first
    }

    /// The groups with only the models that match, and no empty group.
    public static func filter<Provider>(_ groups: [(provider: Provider, models: [CatalogModel])], query: String,
                                        name: (Provider) -> String) -> [(provider: Provider, models: [CatalogModel])] {
        groups.map { group in (group.provider, group.models.filter { matches(query, $0.name, name(group.provider)) }) }
            .filter { !$0.models.isEmpty }
    }
}
