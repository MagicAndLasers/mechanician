import Foundation
import Security

/// Provider credentials are independent even before their runtimes are pooled. This store gives
/// onboarding and model discovery one provider-neutral source of truth without changing the active
/// conversation daemon merely to inspect another account.
@MainActor
final class ProviderAccountStore: ObservableObject {
    static let shared = ProviderAccountStore()
    static let onboardingPreferenceKey = "providerOnboarding.completed.v1"
    private static let legacyDisabledAccessesPreferenceKey = "providerAccounts.disabled.v1"
    private static let accountInstanceIDsPreferenceKey = "providerAccounts.instanceIDs.v1"

    enum State: Equatable {
        case checking
        /// The provider's own status surface confirmed an authenticated account.
        case connected(detail: String?)
        /// A credential exists locally but has not been validated against the provider yet.
        case configured
        /// A credential is supplied by the app's launch environment rather than Mechanician's
        /// Keychain. It can be used, but it cannot honestly be replaced or removed in the UI.
        /// `usable == nil` means the passive probe found an external credential but no provider
        /// runtime has validated it yet. A definitive runtime rejection preserves external ownership
        /// while preventing onboarding from offering a dead Use action.
        case managed(detail: String?, usable: Bool?)
        case disconnected
        case unavailable(String)

        /// A confirmed provider session or a locally configured API credential can power a
        /// workspace. Subscription credentials remain `configured` until their runtime verifies
        /// them, but are still a useful choice on the setup page.
        var isAvailable: Bool {
            switch self {
            case .connected, .configured: return true
            case .managed(_, let usable): return usable != false
            case .checking, .disconnected, .unavailable: return false
            }
        }

        /// Keep the same account language on onboarding, Settings, and transcript recovery. Provider
        /// detail (for example a ChatGPT plan) is metadata, not a different connection state.
        var statusLabel: String {
            switch self {
            case .checking: return "Checking…"
            case .connected: return "Connected"
            case .configured: return "Sign-in saved, verified when used"
            case .managed(let detail, let usable):
                let owner = detail ?? "Managed by launch environment"
                return usable == false ? "\(owner) — unavailable" : owner
            case .disconnected: return "Not connected"
            case .unavailable(let reason): return reason
            }
        }
    }

    enum SubscriptionConnectionAction: Equatable {
        case connect
        case reconnect

        var label: String { self == .connect ? "Connect" : "Reconnect" }
    }

    enum Operation: Equatable {
        case connecting
        case reconnecting
        case signingOut
        case savingCredential
        case removingCredential

        /// A user-initiated Connect/Reconnect should return the user to the app only after the
        /// provider's credential reload has verified the new account. Passive readiness has no
        /// operation, and sign-out/key mutations never pull focus from another app.
        var reactivatesAppAfterVerifiedCompletion: Bool {
            self == .connecting || self == .reconnecting
        }

        var progressLabel: String {
            switch self {
            case .connecting: return "Connecting…"
            case .reconnecting: return "Reconnecting…"
            case .signingOut: return "Disconnecting…"
            case .savingCredential: return "Saving…"
            case .removingCredential: return "Removing…"
            }
        }
    }

    static func shouldReactivateApp(
        afterVerifiedCompletionOf operation: Operation?
    ) -> Bool {
        operation?.reactivatesAppAfterVerifiedCompletion == true
    }

    @Published private(set) var states: [ModelAccess: State] = Dictionary(
        uniqueKeysWithValues: ModelAccess.allCases.map { ($0, .checking) })
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var operations: [ModelAccess: Operation] = [:]
    @Published private(set) var errors: [ModelAccess: String] = [:]
    /// Monotonic ownership boundary for provider-derived data. Runtime generations capture this
    /// value at launch; a reply from a process that predates a credential mutation is discarded.
    @Published private(set) var credentialEpochs: [ModelAccess: Int] = Dictionary(
        uniqueKeysWithValues: ModelAccess.allCases.map { ($0, 0) })
    /// Non-secret local identities for the credential/account instances captured by each route.
    /// These survive app restart but rotate at every credential epoch boundary.
    @Published private(set) var accountInstanceIDs: [ModelAccess: ProviderAccountInstanceID]

    private var generation = 0
    /// Passive probes run off-main and can finish after an explicit account mutation. Revisions
    /// make their results access-scoped: changing Codex invalidates only Codex's captured result,
    /// without leaving unrelated providers stuck in `checking`.
    private var stateRevisions: [ModelAccess: Int] = Dictionary(
        uniqueKeysWithValues: ModelAccess.allCases.map { ($0, 0) })
    private var verifiedConnections: [ModelAccess: State] = [:]
    private var verifiedManagedUsability: [ModelAccess: Bool] = [:]
    /// A passive CLI status probe can see a cached OAuth file even after the provider has rejected
    /// its refresh token. Keep the runtime's stronger rejection authoritative until a later runtime
    /// confirms a successful reconnect.
    private var runtimeAuthenticationRejections: [ModelAccess: String] = [:]
    /// The app uses `shared`. This is reachable so state-transition rules can be exercised on a
    /// throwaway instance instead of mutating the singleton every other test reads.
    init() {
        // Claude and Codex now both own app-scoped credentials and support real logout. Retire the
        // old Claude-only local opt-out so an upgrade cannot leave a valid account permanently
        // hidden behind MECHANICIAN_ACCOUNT_DISABLED.
        UserDefaults.standard.removeObject(forKey: Self.legacyDisabledAccessesPreferenceKey)
        accountInstanceIDs = Self.decodeAccountInstanceIDs(
            UserDefaults.standard.dictionary(forKey: Self.accountInstanceIDsPreferenceKey))
        persistAccountInstanceIDs()
        refresh()
    }

    func state(for access: ModelAccess) -> State { states[access] ?? .checking }
    var hasCompletedInitialCheck: Bool { lastCheckedAt != nil }
    func operation(for access: ModelAccess) -> Operation? { operations[access] }
    func error(for access: ModelAccess) -> String? { errors[access] }
    func credentialEpoch(for access: ModelAccess) -> Int { credentialEpochs[access] ?? 0 }
    func accountInstanceID(for access: ModelAccess) -> ProviderAccountInstanceID {
        // Initialization fills all current routes. Keep a defensive fallback for a future route
        // decoded by a newer binary without turning provider state into a credential-derived id.
        accountInstanceIDs[access] ?? ProviderAccountInstanceID()
    }

    /// Call only after a credential/local-account boundary has actually occurred (or become
    /// ambiguous after reaching the provider). Failed preflight must not rotate this epoch.
    @discardableResult
    func advanceCredentialEpoch(for access: ModelAccess) -> Int {
        let next = credentialEpoch(for: access) + 1
        credentialEpochs[access] = next
        let accountInstanceID = rotateAccountInstanceID(for: access)
        ModelCatalogStore.shared.invalidate(access: access, credentialEpoch: next)
        _ = ProviderCapabilityStore.shared.setCurrentOwner(
            access: access,
            accountInstanceID: accountInstanceID,
            credentialEpoch: next)
        return next
    }

    /// Rotate only a non-secret UUID; never derive identity from a token, API key, email, or
    /// provider subject. Credential epochs can represent ambiguous provider mutations, so rotating
    /// conservatively is safer than allowing old capability evidence to cross that boundary.
    @discardableResult
    private func rotateAccountInstanceID(for access: ModelAccess) -> ProviderAccountInstanceID {
        let replacement = ProviderAccountInstanceID()
        accountInstanceIDs[access] = replacement
        persistAccountInstanceIDs()
        return replacement
    }

    private func persistAccountInstanceIDs() {
        UserDefaults.standard.set(
            Self.encodeAccountInstanceIDs(accountInstanceIDs),
            forKey: Self.accountInstanceIDsPreferenceKey)
    }

    static func decodeAccountInstanceIDs(
        _ persisted: [String: Any]?,
        makeID: () -> ProviderAccountInstanceID = { ProviderAccountInstanceID() }
    ) -> [ModelAccess: ProviderAccountInstanceID] {
        Dictionary(uniqueKeysWithValues: ModelAccess.allCases.map { access in
            if let rawValue = persisted?[access.rawValue] as? String,
               let uuid = UUID(uuidString: rawValue) {
                return (access, ProviderAccountInstanceID(rawValue: uuid))
            }
            return (access, makeID())
        })
    }

    static func encodeAccountInstanceIDs(
        _ identities: [ModelAccess: ProviderAccountInstanceID]
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: identities.map { access, identity in
            (access.rawValue, identity.rawValue.uuidString)
        })
    }

    /// Disable selections while an exact account operation is in flight without claiming that the
    /// credentials changed. Successful/ambiguous operations advance the epoch separately.
    func disableCatalog(for access: ModelAccess, message: String? = nil) {
        ModelCatalogStore.shared.disable(
            access: access, credentialEpoch: credentialEpoch(for: access), message: message)
    }
    func requiresReconnect(_ access: ModelAccess) -> Bool {
        runtimeAuthenticationRejections[access] != nil
    }

    func subscriptionConnectionAction(for access: ModelAccess) -> SubscriptionConnectionAction? {
        guard access.usesInteractiveAccountFlow else { return nil }
        return Self.subscriptionConnectionAction(
            state: state(for: access), requiresReconnect: requiresReconnect(access))
    }

    /// User-facing account action shared by Settings, the composer recovery banner, and preserved
    /// provider-work cards. Vertex has a more precise recovery than generic Reconnect once its
    /// saved Google grant has been rejected, so say exactly what the browser flow will do.
    func subscriptionConnectionLabel(
        for access: ModelAccess,
        includingProviderName: Bool = false
    ) -> String? {
        guard let action = subscriptionConnectionAction(for: access) else { return nil }
        if access == .claudeVertex, requiresReconnect(access) {
            return ProviderFailure.googleReauthenticationActionLabel
        }
        return includingProviderName ? "\(action.label) \(access.displayName)" : action.label
    }

    static func subscriptionConnectionAction(
        state: State,
        requiresReconnect: Bool
    ) -> SubscriptionConnectionAction {
        if requiresReconnect { return .reconnect }
        switch state {
        case .connected, .configured, .managed:
            return .reconnect
        case .checking, .disconnected, .unavailable:
            return .connect
        }
    }
    func isEnvironmentManaged(_ access: ModelAccess) -> Bool {
        if case .managed = state(for: access) { return true }
        return false
    }

    @discardableResult
    func begin(_ operation: Operation, for access: ModelAccess) -> Bool {
        guard operations[access] == nil else { return false }
        stateRevisions[access, default: 0] += 1
        operations[access] = operation
        errors[access] = nil
        return true
    }

    func finish(_ access: ModelAccess, error: String? = nil) {
        operations[access] = nil
        errors[access] = error
        if error != nil { refresh() }
    }

    func clearError(for access: ModelAccess) { errors[access] = nil }

    /// Existing installations should not be interrupted by a new first-run screen. Run this before
    /// any stores create their directories: a prior settings file or durable workspace data proves
    /// the user has already been through the legacy setup path. A genuinely clean store leaves the
    /// preference absent (and therefore false) until the user chooses Continue.
    static func prepareOnboardingPreference() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: onboardingPreferenceKey) == nil else { return }

        let base = MechanicianEnvironment.currentSupportRoot()
        let fm = FileManager.default
        let hasSettings = fm.fileExists(atPath: base.appendingPathComponent("settings.json").path)
        let hasDurableData = ["conversations", "workspaces", "projects"].contains { directory in
            let url = base.appendingPathComponent(directory, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            else { return false }
            return files.contains { $0.pathExtension.lowercased() == "json" }
        }
        if hasSettings || hasDurableData {
            defaults.set(true, forKey: onboardingPreferenceKey)
        }
    }

    /// Re-read provider-owned local status. This is intentionally side-effect-free: it never logs
    /// in, logs out, reads a secret value, or starts/restarts a conversation runtime.
    func refresh() {
        generation += 1
        let requestedGeneration = generation
        let requestedRevisions = stateRevisions
        for access in ModelAccess.allCases where operations[access] == nil {
            states[access] = .checking
        }

        let environment = ProcessInfo.processInfo.environment
        let fixtureDirectory = Bundle.main.bundleIdentifier == "ai.mechanician.app.dev"
            ? environment["MECHANICIAN_ACCOUNT_FIXTURE_DIR"] : nil
        DispatchQueue.global(qos: .utility).async {
            let snapshot = Self.probe(
                environment: environment, fixtureDirectory: fixtureDirectory)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.generation == requestedGeneration else { return }
                    for access in ModelAccess.allCases {
                        guard self.operations[access] == nil,
                              self.stateRevisions[access] == requestedRevisions[access],
                              var candidate = snapshot[access] else { continue }
                        // Provider runtimes own subscription truth. A passive refresh must not
                        // overwrite a stronger connected snapshot or a definitive rejection.
                        if self.runtimeAuthenticationRejections[access] != nil {
                            candidate = .disconnected
                        } else if access.usesInteractiveAccountFlow,
                           case .connected = self.verifiedConnections[access],
                           candidate == .checking {
                            candidate = self.verifiedConnections[access] ?? candidate
                        } else if case .managed(let detail, nil) = candidate,
                                  let usable = self.verifiedManagedUsability[access] {
                            candidate = .managed(detail: detail, usable: usable)
                        } else if candidate == .disconnected {
                            self.verifiedConnections[access] = nil
                            self.verifiedManagedUsability[access] = nil
                        }
                        self.states[access] = candidate
                    }
                    self.lastCheckedAt = Date()
                }
            }
        }
    }

    /// The active daemon knows more than a passive credential probe. Fold its authoritative account
    /// reading into the matching route without disturbing the independently probed routes.
    func report(access: ModelAccess, connected: Bool, detail: String? = nil) {
        stateRevisions[access, default: 0] += 1
        if connected {
            runtimeAuthenticationRejections[access] = nil
            errors[access] = nil
        }
        if let environmentKey = Self.environmentManagedCredentialKey(
            for: access, environment: ProcessInfo.processInfo.environment) {
            states[access] = .managed(
                detail: "Managed by \(environmentKey)", usable: connected)
            verifiedConnections[access] = nil
            verifiedManagedUsability[access] = connected
            lastCheckedAt = Date()
            return
        }
        let state: State = connected ? .connected(detail: detail) : .disconnected
        states[access] = state
        verifiedConnections[access] = connected ? state : nil
        verifiedManagedUsability[access] = nil
        lastCheckedAt = Date()
    }

    /// Fold a provider runtime's ready snapshot into account state. A Vertex daemon first reports
    /// an on-disk ADC credential as present, then verifies it with Google. Demoting that same ready
    /// runtime from logged in to disconnected is therefore a rejected saved sign-in, not a
    /// first-time Connect state. Transient verification failures stay logged in/deferred in agentd.
    @discardableResult
    func reportRuntimeAccountState(
        access: ModelAccess,
        connected: Bool,
        detail: String? = nil,
        previousRuntimeReady: Bool,
        previousRuntimeLoggedIn: Bool,
        accountStatus: String?,
        authenticationRejectionMessage: String? = nil
    ) -> String? {
        let rejection = Self.runtimeAuthenticationRejectionMessage(
            access: access,
            previousRuntimeReady: previousRuntimeReady,
            previousRuntimeLoggedIn: previousRuntimeLoggedIn,
            reportedLoggedIn: connected,
            accountStatus: accountStatus,
            accountOperationInFlight: operation(for: access) != nil,
            authenticationRejectionMessage: authenticationRejectionMessage)
        if let rejection {
            reportAuthenticationRejected(access: access, message: rejection)
            return rejection
        }
        // Startup publishes the presence of an ADC file before Google's asynchronous verification
        // finishes. That weak `checking` snapshot must not clear a definitive rejection already
        // reported by another live lane; only verified provider evidence or a completed reconnect
        // may do that.
        if connected,
           accountStatus?.lowercased() == "checking",
           let existing = runtimeAuthenticationRejections[access] {
            return existing
        }
        report(access: access, connected: connected, detail: detail)
        return nil
    }

    static func runtimeAuthenticationRejectionMessage(
        access: ModelAccess,
        previousRuntimeReady: Bool,
        previousRuntimeLoggedIn: Bool,
        reportedLoggedIn: Bool,
        accountStatus: String?,
        accountOperationInFlight: Bool,
        authenticationRejectionMessage: String? = nil
    ) -> String? {
        guard access == .claudeVertex,
              !accountOperationInFlight,
              !reportedLoggedIn,
              accountStatus?.lowercased() == "disconnected" else { return nil }
        if let explicit = authenticationRejectionMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        guard previousRuntimeReady, previousRuntimeLoggedIn else { return nil }
        return ProviderFailure.googleVertexRejectedSignInMessage
    }

    /// Record a definitive provider rejection without deleting provider-owned credentials. The
    /// user can reconnect in place, while passive cached-file probes cannot falsely restore the row.
    func reportAuthenticationRejected(access: ModelAccess, message: String) {
        stateRevisions[access, default: 0] += 1
        runtimeAuthenticationRejections[access] = message
        states[access] = .disconnected
        verifiedConnections[access] = nil
        errors[access] = message
        lastCheckedAt = Date()
    }

    /// Settle a lane whose probe could not reach its provider at all.
    ///
    /// `checking` is the state that *causes* a probe: `prepareModelCatalog` launches the lane's
    /// daemon whenever it sees one. A probe that fails without answering therefore leaves behind
    /// exactly the condition that starts another, so a provider the app cannot reach gets a fresh
    /// daemon on every picker projection for as long as the app is in use.
    ///
    /// Only `checking` is settled here. A lane that has already answered keeps its answer, so a
    /// single transient catalog failure can never demote a working account.
    func reportProbeUnavailable(access: ModelAccess, message: String) {
        guard states[access] == nil || states[access] == .checking else { return }
        stateRevisions[access, default: 0] += 1
        states[access] = .unavailable(message)
        verifiedConnections[access] = nil
        errors[access] = message
        lastCheckedAt = Date()
    }

    func reportConfigured(access: ModelAccess, configured: Bool) {
        stateRevisions[access, default: 0] += 1
        // A ready runtime proves usability, but it does not change who owns the credential. Keep an
        // environment-backed key visibly external so Settings never offers a dishonest Remove.
        if case .managed(let detail, _) = states[access] {
            states[access] = .managed(detail: detail, usable: configured)
            verifiedManagedUsability[access] = configured
            lastCheckedAt = Date()
            return
        }
        if let environmentKey = Self.environmentManagedCredentialKey(
            for: access, environment: ProcessInfo.processInfo.environment) {
            states[access] = .managed(
                detail: "Managed by \(environmentKey)", usable: configured)
            verifiedManagedUsability[access] = configured
            lastCheckedAt = Date()
            return
        }
        states[access] = configured ? .configured : .disconnected
        verifiedManagedUsability[access] = nil
        lastCheckedAt = Date()
    }

    private nonisolated static func probe(
        environment: [String: String],
        fixtureDirectory: String?
    ) -> [ModelAccess: State] {
        if let fixtureDirectory {
            return fixtureSnapshot(directory: fixtureDirectory)
        }
        var result: [ModelAccess: State] = [:]

        // Interactive-account credential records are provider-owned and deliberately opaque to Swift.
        // Each runtime asks its bundled engine for authoritative structured account status; this
        // passive store stays neutral until that snapshot arrives. Keeping the policy identical for
        // Claude and Codex prevents a second process from racing or overwriting the live lane.
        if let environmentKey = environmentManagedCredentialKey(
            for: .claudeSubscription, environment: environment) {
            result[.claudeSubscription] = .managed(
                detail: "Managed by \(environmentKey)", usable: nil)
        } else {
            result[.claudeSubscription] = .checking
        }
        result[.codexSubscription] = .checking
        if ModelAccess.allCases.contains(.claudeVertex) {
            result[.claudeVertex] = .checking
        }
        result[.anthropicAPI] = apiCredentialState(
            environmentKey: "ANTHROPIC_API_KEY",
            service: MechanicianEnvironment.currentCredentialServices.anthropicAPIKey,
            environment: environment)
        result[.openAIAPI] = apiCredentialState(
            environmentKey: "OPENAI_API_KEY",
            service: MechanicianEnvironment.currentCredentialServices.openAIAPIKey,
            environment: environment)

        return result
    }

    private nonisolated static func apiCredentialState(
        environmentKey: String,
        service: String,
        environment: [String: String]
    ) -> State {
        if environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return .managed(detail: "Managed by \(environmentKey)", usable: nil)
        }
        return keychainContains(service: service, account: "mechanician")
            ? .configured : .disconnected
    }

    private nonisolated static func environmentManagedCredentialKey(
        for access: ModelAccess,
        environment: [String: String]
    ) -> String? {
        let key: String?
        switch access {
        case .claudeSubscription: key = "CLAUDE_CODE_OAUTH_TOKEN"
        case .anthropicAPI: key = "ANTHROPIC_API_KEY"
        case .openAIAPI: key = "OPENAI_API_KEY"
        // Vertex authenticates with Google ADC (a credentials file), not an env-managed key.
        // Vertex authenticates with Google ADC and Bedrock with the ordinary AWS chain — neither
        // is a single env-managed key Mechanician can name here.
        case .codexSubscription, .claudeVertex, .claudeBedrock: key = nil
        }
        guard let key,
              environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return nil }
        return key
    }

    private struct FixtureAccount: Decodable {
        var loggedIn: Bool?
        var configured: Bool?
        var detail: String?
        var unavailable: String?
    }

    /// Deterministic account state for the explicitly opted-in Dev fixture. Release bundles never
    /// consult this path, and a normal isolated support directory still probes the real providers.
    private nonisolated static func fixtureSnapshot(
        directory: String
    ) -> [ModelAccess: State] {
        let decoder = JSONDecoder()
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        return Dictionary(uniqueKeysWithValues: ModelAccess.allCases.map { access in
            let file = root.appendingPathComponent("\(access.rawValue).json")
            guard let data = try? Data(contentsOf: file),
                  let account = try? decoder.decode(FixtureAccount.self, from: data) else {
                return (access, .disconnected)
            }
            if let unavailable = account.unavailable { return (access, .unavailable(unavailable)) }
            if account.loggedIn == true { return (access, .connected(detail: account.detail)) }
            if account.configured == true { return (access, .configured) }
            return (access, .disconnected)
        })
    }

    private nonisolated static func keychainContains(service: String, account: String? = nil) -> Bool {
        var arguments = ["find-generic-password"]
        if let account { arguments += ["-a", account] }
        arguments += ["-s", service]
        return runSecurity(arguments).exitCode == 0
    }

    private nonisolated static func apiKeyDescriptor(
        for access: ModelAccess
    ) -> (service: String, environmentKey: String)? {
        switch access {
        case .anthropicAPI:
            return (MechanicianEnvironment.currentCredentialServices.anthropicAPIKey, "ANTHROPIC_API_KEY")
        case .openAIAPI:
            return (MechanicianEnvironment.currentCredentialServices.openAIAPIKey, "OPENAI_API_KEY")
        case .claudeSubscription, .codexSubscription, .claudeVertex, .claudeBedrock: return nil
        }
    }

    /// Write the key straight to the Keychain through the Security framework.
    ///
    /// This used to shell out to `security add-generic-password … -w` with the value on stdin,
    /// chosen because passing `-w <value>` would expose the secret in the process list. That form
    /// **silently truncates at 128 characters** — measured: writing 212 characters read back 128,
    /// with no error and a zero exit code. Anthropic keys are shorter than the limit, so it only
    /// surfaced with an OpenAI project key (`sk-proj-…`), which is longer: the stored value was a
    /// valid-looking prefix that the provider then rejected as an incorrect key, pointing suspicion
    /// at the user's key rather than at us.
    ///
    /// SecItemAdd/SecItemUpdate has no such limit and never puts the secret in argv. The item shape
    /// is unchanged — a generic password under account `mechanician` and the same service — so
    /// agentd and ambientd keep reading it with `find-generic-password`, whose read path was
    /// verified lossless at 212 characters.
    nonisolated static func storeAPIKey(_ key: String, for access: ModelAccess) -> String? {
        guard let descriptor = apiKeyDescriptor(for: access) else {
            return "That account does not use an API key."
        }
        guard let data = key.data(using: .utf8) else { return "That key isn't valid text." }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "mechanician",
            kSecAttrService as String: descriptor.service,
        ]
        // Update in place when the item exists; the CLI's `-U` did this implicitly.
        let updateStatus = SecItemUpdate(query as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return nil }
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            return addStatus == errSecSuccess ? nil : keychainError(addStatus)
        }
        return keychainError(updateStatus)
    }

    /// These reach the composer's provider banner and the model picker, not a diagnostics pane, so
    /// they say what happened to the person's key. The status code and the system's own wording go
    /// to the log, where they are useful and where they were previously not recorded at all.
    nonisolated private static func keychainError(_ status: OSStatus) -> String {
        let detail = SecCopyErrorMessageString(status, nil) as String?
        NSLog("[keychain] item operation failed with %d: %@", status, detail ?? "no detail")
        return "macOS wouldn’t let Mechanician store your key in the Keychain. "
            + "Check Keychain Access, then try again."
    }

    nonisolated static func removeAPIKey(for access: ModelAccess) -> String? {
        guard let descriptor = apiKeyDescriptor(for: access) else {
            return "That account does not use an API key."
        }
        let result = runSecurity([
            "delete-generic-password", "-a", "mechanician", "-s", descriptor.service,
        ])
        if result.exitCode == 0 || result.output.localizedCaseInsensitiveContains("could not be found") {
            return nil
        }
        return securityError(result)
    }

    private nonisolated static func securityError(
        _ result: (exitCode: Int32, output: String)
    ) -> String {
        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Was pasting raw `/usr/bin/security` stdout into the banner.
        NSLog("[keychain] security(1) exited %d: %@", result.exitCode, detail)
        return "macOS wouldn’t let Mechanician change your Keychain entry. "
            + "Check Keychain Access, then try again."
    }

    private nonisolated static func runSecurity(
        _ arguments: [String], input: String? = nil
    ) -> (exitCode: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        let inputPipe = input == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        process.standardInput = inputPipe
        do { try process.run() }
        catch { return (-1, error.localizedDescription) }
        if let input, let inputPipe {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

}

extension ModelAccess: CaseIterable {
    /// The four routes present in every build. Enterprise routes are added on top, per profile.
    static let builtInCases: [ModelAccess] = [.claudeSubscription, .anthropicAPI, .codexSubscription, .openAIAPI]

    /// The active route lanes for this process: the built-ins plus any enterprise routes the current
    /// signed tenant profile activates (FR-103). A standard install starts with no profile and exactly
    /// the four built-ins; an imported or MDM-delivered profile can add `.claudeVertex` or
    /// `.claudeBedrock` without requiring a different app build.
    static var allCases: [ModelAccess] {
        builtInCases + TenantProfile.current.enterpriseAccesses.filter { !builtInCases.contains($0) }
    }

    /// Routes a person may choose for new work under the forced enterprise policy. `allCases`
    /// deliberately remains the complete configured inventory so persisted conversations and
    /// preferences on a newly prohibited route can be preserved rather than silently rewritten.
    static var selectableCases: [ModelAccess] {
        guard let policy = ManagedEnterprisePolicy.current else { return allCases }
        return policy.filteredProviderAccesses(allCases)
    }

    var isAllowedByEnterprisePolicy: Bool {
        ManagedEnterprisePolicy.current?.allows(self) ?? true
    }

    var displayName: String {
        switch self {
        case .claudeSubscription: return "Claude subscription"
        case .anthropicAPI: return "Anthropic API"
        case .codexSubscription: return "Codex subscription"
        case .openAIAPI: return "OpenAI API"
        case .claudeVertex:
            return TenantProfile.current.routes.first(where: { $0.adapter == "claude-vertex" })?
                .displayName ?? "Claude (Vertex)"
        case .claudeBedrock:
            return TenantProfile.current.routes.first(where: { $0.adapter == "claude-bedrock" })?
                .displayName ?? "Claude (Bedrock)"
        }
    }

    var makerName: String { maker == .anthropic ? "Anthropic" : "OpenAI" }

    var accountChoice: String {
        switch self {
        case .claudeSubscription: return "subscription"
        case .anthropicAPI: return "apikey"
        case .codexSubscription: return "codex"
        case .openAIAPI: return "openai"
        case .claudeVertex: return "vertex"
        case .claudeBedrock: return "bedrock"
        }
    }
}
