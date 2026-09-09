import Foundation

/// Keeps an installed enterprise profile current when its signed transport policy allows it.
///
/// The app auto-updates through Sparkle; the profile that configures it did not update at all. Every
/// value in that document is operational config owned by someone else's schedule — an MCP registry
/// hostname, a Cloud Run marketplace URL that will rotate, a Vertex project and region, the model
/// list a deployment carries — so a stale profile is the normal case, not an edge case. A signed
/// profile may opt into an automatic launch check or retain the same feed for explicit checks only.
///
/// The security model needs nothing new to make this safe: the envelope is signed and
/// `TenantProfile.installSignedProfile` verifies BEFORE it touches the installed file. A fetched
/// document is therefore exactly as trustworthy as an imported one, and the transport does not have
/// to be. Every failure mode — unreachable feed, garbage body, bad signature, a document for some
/// other tenant — leaves the working profile exactly where it was.
///
/// Signing stays with us: the public key is embedded in the app, so a tenant cannot publish a
/// profile revision on their own. That is a deliberate trade — it keeps the trust root small at the
/// cost of a round trip whenever a tenant wants a change. Delegated (tenant-held) signing would
/// remove that round trip and is a separate security design.
@MainActor
final class TenantProfileUpdater: ObservableObject {
    static let shared = TenantProfileUpdater()

    enum Outcome: Equatable {
        /// The feed served the document we already have.
        case unchanged
        /// `retired` names the local edits this revision took back, already phrased for a reader.
        /// Empty is the ordinary case and must stay silent.
        case updated(tenantId: String, retired: [String] = [])
        /// Nothing to do: this profile declares no feed.
        case notConfigured
        /// The feed answered and was accepted, but what it served is not newer than what is
        /// installed, so nothing was replaced. Deliberately NOT a failure: the check worked, the
        /// answer was "nothing to install", and the user has nothing to fix. Reporting this as an
        /// error made the ordinary result of pressing Check for Updates look broken.
        case notNewer(installedRevision: Int?, servedRevision: Int?)
        /// Reached the feed but could not accept what it served, or could not reach it at all. The
        /// installed profile is untouched.
        case failed(String)
    }

    /// Injected so the whole policy is testable without a network.
    typealias Fetcher = @Sendable (URL) async throws -> Data

    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastOutcome: Outcome?
    @Published private(set) var isChecking = false

    private let fetch: Fetcher
    private let install: (Data) throws -> TenantProfile
    private let loadCandidate: (Data) throws -> TenantProfile
    private let currentProfile: () -> TenantProfile
    private let installedSignedProfile: () -> TenantProfile
    private let loadOverrides: () -> ManagedConfigurationOverrides
    private let saveOverrides: (ManagedConfigurationOverrides) -> Void
    private let recordRetirements: ([ManagedConfigurationOverrides.Retirement], Int?) -> Void
    private let isMDMManaged: () -> Bool

    /// `loadCandidate` is injected on the same terms as `install`, and for the same reason: the
    /// outcome classification below cannot be tested otherwise. Production always uses the default,
    /// which verifies against the embedded key, and `install` verifies again before it writes, so
    /// no shipped path reaches a profile that was not signed by us.
    init(
        fetch: @escaping Fetcher = TenantProfileUpdater.fetchViaURLSession,
        install: @escaping (Data) throws -> TenantProfile = { data in
            try TenantProfile.installSignedProfile(data)
        },
        loadCandidate: @escaping (Data) throws -> TenantProfile = { data in
            try TenantProfile.loadSignedProfile(
                data, publicKey: TenantProfile.profileSigningPublicKey)
        },
        currentProfile: @escaping () -> TenantProfile = { TenantProfile.current },
        installedSignedProfile: @escaping () -> TenantProfile = {
            TenantProfile.currentSignedProfile
        },
        loadOverrides: @escaping () -> ManagedConfigurationOverrides = {
            ManagedConfigurationOverrides.load()
        },
        saveOverrides: @escaping (ManagedConfigurationOverrides) -> Void = { overrides in
            // Best effort on purpose. Failing to prune a superseded override must not turn a
            // successful profile update into a failure — the profile is already installed by here.
            try? overrides.save()
        },
        recordRetirements: @escaping ([ManagedConfigurationOverrides.Retirement], Int?) -> Void = {
            TenantProfileUpdater.recordRetirementNote($0, revision: $1)
        },
        isMDMManaged: @escaping () -> Bool = {
            ManagedEnterprisePolicy.current?.signedProfile != nil
        }
    ) {
        self.fetch = fetch
        self.install = install
        self.loadCandidate = loadCandidate
        self.currentProfile = currentProfile
        self.installedSignedProfile = installedSignedProfile
        self.loadOverrides = loadOverrides
        self.saveOverrides = saveOverrides
        self.recordRetirements = recordRetirements
        self.isMDMManaged = isMDMManaged
    }

    /// A short timeout on purpose: a tenant's feed is commonly VPN-only, so being off the VPN is an
    /// ordinary condition that must cost the user nothing.
    nonisolated private static let fetchViaURLSession: Fetcher = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.badStatus(http.statusCode)
        }
        return data
    }

    /// Only genuine faults live here. A document that is merely not newer is `Outcome.notNewer`,
    /// because describing it as an error is what made a healthy check read as a failure.
    enum UpdateError: LocalizedError, Equatable {
        case badStatus(Int)
        case wrongTenant(expected: String, received: String)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code):
                return "The profile feed answered HTTP \(code)."
            case .wrongTenant(let expected, let received):
                return "The profile feed served tenant “\(received)”, but this Mac is configured "
                     + "for “\(expected)”."
            }
        }
    }

    /// Profiles imported before revisions existed may accept one signed migration. Once a profile
    /// has a revision, every content change must advance it. This leaves manual import available as
    /// an explicit recovery path while making unattended updates replay-resistant.
    nonisolated static func revisionAdvances(current: Int?, candidate: Int?) -> Bool {
        guard let current else { return candidate.map { $0 > 0 } ?? false }
        guard let candidate else { return false }
        return candidate > current
    }

    /// Launch-time checks honor the signed profile's transport policy. A person pressing Check uses
    /// ``check()`` directly, so manual mode removes ambient network traffic without removing the
    /// explicit recovery/update path. An absent mode retains the historical automatic behavior,
    /// which lets an already-installed profile fetch one newer revision that switches to manual.
    @discardableResult
    func checkAutomaticallyIfNeeded() async -> Outcome? {
        guard !isMDMManaged(),
              currentProfile().update?.effectiveProfileUpdateMode == .automatic else {
            return nil
        }
        return await check()
    }

    @discardableResult
    func check() async -> Outcome {
        guard !isMDMManaged() else {
            let outcome = Outcome.notConfigured
            lastOutcome = outcome
            return outcome
        }
        let profile = currentProfile()
        guard let raw = profile.update?.profileFeedURL,
              let url = URL(string: raw), url.scheme == "https" else {
            let outcome = Outcome.notConfigured
            lastOutcome = outcome
            return outcome
        }

        isChecking = true
        defer { isChecking = false; lastCheckedAt = Date() }

        let outcome: Outcome
        do {
            let data = try await fetch(url)
            let installedTenant = profile.tenantId
            // Verify-then-compare: decode through the signed path so an unsigned or tampered
            // document is rejected before its tenantId is believed.
            let candidate = try loadCandidate(data)
            guard candidate.tenantId == installedTenant else {
                throw UpdateError.wrongTenant(
                    expected: installedTenant, received: candidate.tenantId)
            }
            // Compare against the profile AS SIGNED, never the effective one. `TenantProfile.current`
            // is the signed document with this install's local overrides applied, so on any machine
            // that has overridden anything it can never equal a freshly signed document, `unchanged`
            // could never fire, and every check fell through to the revision comparison and reported
            // that the organization had published unmarked changes. It had not: the difference was
            // the user's own local edits. Overrides deliberately omit `update`, so the revision and
            // the feed URL read the same from either.
            let signed = installedSignedProfile()
            if candidate == signed {
                outcome = .unchanged
            } else {
                let currentRevision = signed.update?.revision
                let candidateRevision = candidate.update?.revision
                if !Self.revisionAdvances(
                    current: currentRevision,
                    candidate: candidateRevision
                ) {
                    // Refusing is still correct, but it is an ANSWER, not an error. The document
                    // was fetched, verified, and found not to be newer.
                    outcome = .notNewer(
                        installedRevision: currentRevision, servedRevision: candidateRevision)
                } else {
                    let installed = try install(data)
                    // Strictly after a successful install: a throw above must leave this Mac's
                    // local edits exactly as they were, or a failed update would silently cost the
                    // user configuration it never managed to replace.
                    let retired = retireSupersededOverrides(previous: signed, next: candidate)
                    outcome = .updated(
                        tenantId: installed.tenantId, retired: retired.map(\.sentence))
                }
            }
        } catch {
            // Deliberately terminal-but-harmless: the installed profile still governs this launch.
            outcome = .failed(error.localizedDescription)
        }
        lastOutcome = outcome
        return outcome
    }

    /// Three-way merge against the revision being replaced. The rule, and why it is the rule, is on
    /// ``ManagedConfigurationOverrides/retiringSuperseded(previous:next:)``.
    private func retireSupersededOverrides(
        previous: TenantProfile, next: TenantProfile
    ) -> [ManagedConfigurationOverrides.Retirement] {
        let overrides = loadOverrides()
        let (reduced, retired) = overrides.retiringSuperseded(previous: previous, next: next)
        guard !retired.isEmpty else { return [] }
        saveOverrides(reduced)
        recordRetirements(retired, next.update?.revision)
        return retired
    }

    // MARK: The note a retirement leaves behind

    /// A profile installs in the background at launch and governs the NEXT launch, so the launch
    /// that retires an override is never the launch where the user sees the list change. Told only
    /// in the moment, the explanation would always arrive one launch before the surprise it
    /// explains, so it has to outlive the process.
    nonisolated static let retirementNoteKey = "managedConfiguration.retiredOverrides"
    nonisolated static let retirementNoteRevisionKey =
        "managedConfiguration.retiredOverridesRevision"

    /// `nonisolated` because these only read and write `UserDefaults`, which is its own synchronized
    /// store, and the default `init` argument that installs this runs outside the main actor.
    nonisolated static func recordRetirementNote(
        _ retired: [ManagedConfigurationOverrides.Retirement],
        revision: Int?,
        defaults: UserDefaults = .standard
    ) {
        guard !retired.isEmpty else { return }
        // Accumulate rather than replace: two revisions can land before the user opens Settings,
        // and the earlier explanation is not less true for having been overtaken.
        let existing = defaults.stringArray(forKey: retirementNoteKey) ?? []
        var merged = existing
        for sentence in retired.map(\.sentence) where !merged.contains(sentence) {
            merged.append(sentence)
        }
        defaults.set(merged, forKey: retirementNoteKey)
        if let revision { defaults.set(revision, forKey: retirementNoteRevisionKey) }
    }

    nonisolated static func pendingRetirementNote(
        defaults: UserDefaults = .standard
    ) -> (sentences: [String], revision: Int?)? {
        let sentences = defaults.stringArray(forKey: retirementNoteKey) ?? []
        guard !sentences.isEmpty else { return nil }
        let revision = defaults.object(forKey: retirementNoteRevisionKey) as? Int
        return (sentences, revision)
    }

    nonisolated static func clearRetirementNote(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: retirementNoteKey)
        defaults.removeObject(forKey: retirementNoteRevisionKey)
    }
}
