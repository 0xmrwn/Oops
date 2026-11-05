import Foundation

/// One entry of the signed-in account's model catalog (`GET /v1/models`, OpenAI's models-and-inference page).
public struct ChatGPTModel: Equatable, Sendable, Identifiable {
    public struct Effort: Equatable, Sendable { public let id: String, description: String }
    public struct ServiceTier: Equatable, Sendable { public let id: String, name: String, description: String }
    /// Sent as `model`.
    public let slug: String
    /// Shown in the picker.
    public let displayName: String
    public let description: String?
    /// `visibility: "list"`: meant for a picker.
    public let visible: Bool
    public let priority: Int
    public let efforts: [Effort]
    public let defaultEffort: String?
    public let serviceTiers: [ServiceTier]
    public var id: String { slug }
}

public enum ChatGPTModels {
    static let url = URL(string: "https://api.openai.com/v1/models")!

    /// The account's catalog, in the server's order, fetched with the same token inference uses.
    public static func list(using auth: ChatGPTAuth) async throws -> [ChatGPTModel] {
        try await auth.withAccessToken { token in
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let data: Data, response: URLResponse
            do { (data, response) = try await auth.session.data(for: request, delegate: NoRedirect.shared) } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch { throw ChatGPTError.network }
            guard let http = response as? HTTPURLResponse else { throw ChatGPTError.network }
            guard http.statusCode == 200 else { throw ChatGPTError.api(try? JSONSerialization.jsonObject(with: data), status: http.statusCode) }
            return try decode(data)
        }
    }

    /// Reads a `{"models": […]}` catalog. Entries without a slug are skipped; a catalog with no usable
    /// model is an error. `includeHidden` keeps entries not meant for a picker, for diagnostics.
    public static func decode(_ data: Data, includeHidden: Bool = false) throws -> [ChatGPTModel] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let entries = object["models"] as? [Any] else {
            throw ChatGPTError.named("models_unavailable")
        }
        let models = entries.compactMap { ($0 as? [String: Any]).flatMap(model) }.filter { includeHidden || $0.visible }
        guard !models.isEmpty else { throw ChatGPTError.named("models_unavailable") }
        return models
    }

    private static func model(_ entry: [String: Any]) -> ChatGPTModel? {
        guard let slug = entry["slug"] as? String, !slug.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let name = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug
        let efforts = (entry["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { level -> ChatGPTModel.Effort? in
            guard let id = level["effort"] as? String, !id.isEmpty else { return nil }
            return ChatGPTModel.Effort(id: id, description: level["description"] as? String ?? "")
        }
        let tiers = (entry["service_tiers"] as? [[String: Any]] ?? []).compactMap { tier -> ChatGPTModel.ServiceTier? in
            guard let id = tier["id"] as? String, !id.isEmpty else { return nil }
            return ChatGPTModel.ServiceTier(id: id, name: tier["name"] as? String ?? id, description: tier["description"] as? String ?? "")
        }
        return ChatGPTModel(slug: slug, displayName: name, description: entry["description"] as? String, visible: entry["visibility"] as? String == "list",
                            priority: (entry["priority"] as? NSNumber)?.intValue ?? Int.max, efforts: efforts,
                            defaultEffort: entry["default_reasoning_level"] as? String, serviceTiers: tiers)
    }

    /// The catalog's own shape, so a cached list reads back through `decode`.
    public static func encode(_ models: [ChatGPTModel]) throws -> Data {
        let entries: [[String: Any]] = models.map { model in
            var entry: [String: Any] = [
                "slug": model.slug, "display_name": model.displayName, "visibility": model.visible ? "list" : "hide", "priority": model.priority,
                "supported_reasoning_levels": model.efforts.map { ["effort": $0.id, "description": $0.description] },
                "service_tiers": model.serviceTiers.map { ["id": $0.id, "name": $0.name, "description": $0.description] },
            ]
            if let description = model.description { entry["description"] = description }
            if let effort = model.defaultEffort { entry["default_reasoning_level"] = effort }
            return entry
        }
        return try JSONSerialization.data(withJSONObject: ["models": entries])
    }
}
