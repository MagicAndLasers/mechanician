import Foundation

/// When a route offers the same model at more than one context window, default to the biggest one.
///
/// Several models ship both a bare id and a larger-window variant of the same family, and until now
/// which one you got depended on the route. First-party routes auto-upgrade bare Opus 4.8 to its
/// `[1m]` variant, but no third-party route does, so a managed Vertex deployment that genuinely
/// serves a 1M variant still defaulted new conversations to the 200K one. That difference is
/// invisible until a long conversation starts compacting every few minutes.
///
/// The rule is deliberately a SELECTION, never a synthesis. It can only choose an id the route
/// already published, whether that came from a provider catalog or a managed profile's declaration.
/// That is what keeps it safe on third-party routes: a 1M variant is enabled per project there, and
/// inventing the suffix for a project that lacks it would turn a working selection into a failing
/// one. If a deployment does not offer the variant, there is nothing here to pick and the behavior
/// is unchanged.
///
/// Only the DEFAULT for new conversations is affected. An existing conversation keeps its model, and
/// an explicit pick in the model picker is always honored; changing either would move a live
/// conversation across a session boundary behind the user's back.
enum LargestContextWindowVariant {
    /// The entry to use instead of `chosen`, when the same family is offered at a larger window.
    ///
    /// `window` is injected rather than computed here so this stays pure and so callers can feed it
    /// a MEASURED window where one exists. Ties keep `chosen`: an equal window is not an upgrade,
    /// and preferring the incumbent keeps a provider's own default meaningful.
    static func preferred(
        among entries: [ModelCatalogEntry],
        chosen: ModelCatalogEntry,
        family: (String) -> String,
        window: (ModelCatalogEntry) -> Int
    ) -> ModelCatalogEntry {
        let chosenFamily = family(chosen.resolvedModelID ?? chosen.selection.modelID)
        guard !chosenFamily.isEmpty else { return chosen }
        let chosenWindow = window(chosen)
        var best = chosen
        var bestWindow = chosenWindow
        for entry in entries {
            guard entry.selection.access == chosen.selection.access,
                  !entry.selection.modelID.isEmpty,
                  family(entry.resolvedModelID ?? entry.selection.modelID) == chosenFamily
            else { continue }
            let candidate = window(entry)
            if candidate > bestWindow {
                best = entry
                bestWindow = candidate
            }
        }
        return best
    }
}
