import Foundation

/// Check an API key against its provider before it is stored.
///
/// Without this, a bad key is accepted silently and only fails much later — at the next turn, or
/// worse, in an unattended scheduled run where nobody sees it. That gap is exactly how a truncated
/// OpenAI key survived long enough to look like the provider's fault rather than ours.
///
/// The distinction that matters is REJECTED vs UNVERIFIED. A provider saying "this key is not
/// valid" is a fact worth refusing the save over. Being offline is not — refusing then would strand
/// a user who is holding a perfectly good key, so an unreachable provider stores the key and says
/// so.
enum ProviderKeyValidation {
    enum Outcome: Equatable {
        /// The provider accepted the key.
        case valid
        /// The provider actively rejected it — do not store.
        case rejected(String)
        /// The check could not be completed (offline, timeout, unexpected status). Store anyway.
        case unverified(String)
        /// This lane has no cheap credential check.
        case unsupported
    }

    /// A read-only, negligible-cost endpoint per provider. Listing models bills nothing and
    /// exercises exactly the credential path a real turn will use.
    static func request(for access: ModelAccess, key: String) -> URLRequest? {
        switch access {
        case .openAIAPI:
            guard let url = URL(string: "https://api.openai.com/v1/models") else { return nil }
            var r = URLRequest(url: url)
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            r.timeoutInterval = 15
            return r
        case .anthropicAPI:
            guard let url = URL(string: "https://api.anthropic.com/v1/models?limit=1") else { return nil }
            var r = URLRequest(url: url)
            r.setValue(key, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            r.timeoutInterval = 15
            return r
        default:
            return nil
        }
    }

    /// Map a provider response to an outcome. Split out so the mapping is testable without a network.
    static func outcome(status: Int, provider: String) -> Outcome {
        switch status {
        case 200...299:
            return .valid
        case 401, 403:
            return .rejected(
                "\(provider) rejected this key. Check that it was copied in full and hasn't been revoked.")
        case 429:
            // The credential is real; the account is just rate limited or out of quota.
            return .valid
        default:
            return .unverified("Couldn't verify the key with \(provider) (HTTP \(status)).")
        }
    }

    static func providerName(for access: ModelAccess) -> String {
        access == .openAIAPI ? "OpenAI" : "Anthropic"
    }

    static func check(_ key: String, for access: ModelAccess,
                      session: URLSession = .shared) async -> Outcome {
        guard let request = request(for: access, key: key) else { return .unsupported }
        let provider = providerName(for: access)
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unverified("Couldn't verify the key with \(provider).")
            }
            return outcome(status: http.statusCode, provider: provider)
        } catch {
            // The engine's words are not the user's situation: this used to show URLError text
            // beside a key that had in fact been saved. Detail goes to the log.
            NSLog("[providers] key verification could not reach %@: %@",
                  provider, error.localizedDescription)
            return .unverified(
                "Couldn't reach \(provider) to verify the key. It is saved, and Mechanician "
                + "checks it the next time you use it.")
        }
    }
}
