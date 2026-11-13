import Foundation
import OopsCore

extension ProviderStore {
    var capabilityResolver: CapabilityResolver { CapabilityResolver(catalog: features.catalog, feed: features.feed) }

    /// What a provider's model can do, or which slow step it still needs. Nothing here runs that step.
    func capabilities(_ choice: ModelSelection.Choice) -> CapabilityResolution {
        let key = CapabilityAnswers.key(choice)
        return capabilityResolver.resolve(modelID: choice.modelID, kind: provider(choice.providerID)?.kind,
                                          probe: features.answers.probes[key], answer: features.answers.user[key],
                                          canProbe: features.probe != nil)
    }

    /// Every switched-on model of every provider, with what it can do.
    var shownCapabilities: [ModelSelection.Choice: CapabilityResolution] {
        let choices = providers.flatMap { provider in provider.shownModels.map { ModelSelection.Choice(providerID: provider.id, modelID: $0) } }
        return Dictionary(choices.map { ($0, capabilities($0)) }, uniquingKeysWith: { first, _ in first })
    }
}
