import Foundation
import OopsCore

extension ProviderStore {
    /// Lists the endpoint's models with this key: the check behind Add and Save. Saves nothing.
    func check(endpoint: String, key: String) async throws -> [CatalogModel] {
        guard let url = URL(string: endpoint), url.scheme != nil, url.host != nil else {
            throw CorrectionError.message("Enter the endpoint’s full address, like https://api.example.com/v1.")
        }
        if preview { return [CatalogModel(id: "preview-model", name: "preview-model")] }
        return try await OpenAICompatibleModels.list(baseURL: url, apiKey: key).map(CatalogModel.init)
    }
}
