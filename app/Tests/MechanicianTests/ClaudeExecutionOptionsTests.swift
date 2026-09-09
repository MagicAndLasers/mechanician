import XCTest
@testable import Mechanician

/// Claude Opus 5 adoption, plan Phase 0 (O5-003/O5-004): conversation-scoped preferences, the dev
/// gate, and the request payload they produce.
///
/// The contract under test is mostly about what is NOT sent. Every path that cannot honor a
/// preference must withhold it from the request while leaving the persisted intent alone.
final class ClaudeExecutionOptionsTests: XCTestCase {
    private let allFeatures = ClaudeExperiments(enabled: Set(ClaudeExperimentalFeature.allCases))

    // MARK: The no-op default

    func testDefaultPreferencesContributeNoRequestPayload() {
        // Byte-equivalence with the release that predates this type: no `claude` key at all.
        let preferences = ClaudeSessionPreferences()
        XCTAssertTrue(preferences.isDefault)
        for access in [ModelAccess.claudeSubscription, .anthropicAPI, .claudeVertex] {
            XCTAssertNil(preferences.requestPayload(for: access, experiments: allFeatures),
                         "default preferences must send nothing on \(access.rawValue)")
        }
    }

    func testAbsentAndAllDefaultPreferencesAreEquivalent() {
        var conversation = Self.conversation()
        XCTAssertNil(conversation.claudePreferences)
        XCTAssertEqual(conversation.claudeSessionPreferences, ClaudeSessionPreferences())

        conversation.claudePreferences = ClaudeSessionPreferences()
        XCTAssertEqual(conversation.claudeSessionPreferences, ClaudeSessionPreferences())
        XCTAssertNil(conversation.claudeSessionPreferences.requestPayload(
            for: .anthropicAPI, experiments: allFeatures))
    }

    // MARK: The dev gate

    func testAnUngatedPreferenceIsWithheldButNotErased() {
        let preferences = ClaudeSessionPreferences(
            advisor: .automatic, speed: .fast, refusalFallback: .providerDefault)

        // A release build (or any build without the gate) must not send a preference the daemon
        // would reject — that would cost the user their turn.
        XCTAssertNil(preferences.requestPayload(for: .anthropicAPI, experiments: .none))

        // The persisted intent is untouched, so re-enabling the gate restores the choice.
        XCTAssertEqual(preferences.advisor, .automatic)
        XCTAssertEqual(preferences.speed, .fast)
        XCTAssertEqual(preferences.refusalFallback, .providerDefault)
    }

    func testEachFeatureIsGatedIndependently() {
        let preferences = ClaudeSessionPreferences(
            advisor: .automatic, speed: .fast, refusalFallback: .providerDefault)
        let onlyFast = ClaudeExperiments(enabled: [.fast])

        let payload = preferences.requestPayload(for: .anthropicAPI, experiments: onlyFast)
        XCTAssertEqual(payload?["speed"] as? String, "fast")
        XCTAssertNil(payload?["advisor"], "advisor must stay off when only Fast is enabled")
        XCTAssertNil(payload?["refusalFallback"])
    }

    func testGateParsingIgnoresUnknownNamesAndEmptyInput() {
        XCTAssertEqual(ClaudeExperiments.parse(nil), [])
        XCTAssertEqual(ClaudeExperiments.parse(""), [])
        XCTAssertEqual(ClaudeExperiments.parse("advisor, fast"), [.advisor, .fast])
        XCTAssertEqual(ClaudeExperiments.parse("advisor,managedAgents"), [.advisor])
        XCTAssertEqual(ClaudeExperiments.parse("nonsense"), [])
    }

    func testDaemonEnvironmentValueIsOmittedWhenNothingIsEnabled() {
        XCTAssertNil(ClaudeExperiments.none.daemonEnvironmentValue)
        XCTAssertEqual(
            ClaudeExperiments(enabled: [.fast, .advisor]).daemonEnvironmentValue,
            // Declaration order, so the value is stable rather than set-iteration dependent.
            "advisor,fast")
    }

    func testReleaseBuildsIgnoreAnInheritedGateValue() {
        let inherited = [ClaudeExperiments.environmentKey: "advisor,fast,refusalFallback"]
        let resolved = ClaudeExperiments(environment: inherited)
        #if DEBUG
        // A dev build is allowed to opt in explicitly.
        XCTAssertEqual(resolved.enabled, Set(ClaudeExperimentalFeature.allCases))
        #else
        // A release build must resolve empty regardless of what it inherited: the gate is
        // compile-time, so a developer shell cannot switch on a billed preview.
        XCTAssertTrue(resolved.enabled.isEmpty)
        #endif
    }

    // MARK: Route exclusion

    func testVertexAndNonClaudeRoutesNeverReceivePreviewPreferences() {
        let preferences = ClaudeSessionPreferences(
            advisor: .automatic, speed: .fast, refusalFallback: .providerDefault)
        for access in [ModelAccess.claudeVertex, .codexSubscription, .openAIAPI] {
            XCTAssertNil(preferences.requestPayload(for: access, experiments: allFeatures),
                         "\(access.rawValue) must never receive a Claude preview setting")
            XCTAssertEqual(
                preferences.effective(for: access, experiments: allFeatures),
                ClaudeSessionPreferences())
        }
        XCTAssertFalse(ClaudeSessionPreferences.routeSupportsPreviewSurfaces(.claudeVertex))
        XCTAssertTrue(ClaudeSessionPreferences.routeSupportsPreviewSurfaces(.claudeSubscription))
        XCTAssertTrue(ClaudeSessionPreferences.routeSupportsPreviewSurfaces(.anthropicAPI))
    }

    // MARK: Payload shape (must match agentd's validator)

    func testPayloadMatchesTheDaemonRequestSchema() {
        let preferences = ClaudeSessionPreferences(
            advisor: .automatic, speed: .fast, refusalFallback: .model("claude-opus-4-8"))
        let payload = preferences.requestPayload(for: .claudeSubscription, experiments: allFeatures)

        XCTAssertEqual((payload?["advisor"] as? [String: Any])?["mode"] as? String, "automatic")
        XCTAssertEqual(payload?["speed"] as? String, "fast")
        let fallback = payload?["refusalFallback"] as? [String: Any]
        XCTAssertEqual(fallback?["mode"] as? String, "model")
        XCTAssertEqual(fallback?["model"] as? String, "claude-opus-4-8")

        // Only non-default keys appear, so the daemon sees the smallest truthful request.
        let offAdvisor = ClaudeSessionPreferences(speed: .fast)
            .requestPayload(for: .claudeSubscription, experiments: allFeatures)
        XCTAssertEqual(Array(offAdvisor?.keys ?? [:].keys), ["speed"])

        // The payload must be JSON-serializable: it is written straight onto the NDJSON wire.
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: payload ?? [:]))
    }

    func testProviderDefaultFallbackOmitsAModel() {
        let payload = ClaudeSessionPreferences(refusalFallback: .providerDefault)
            .requestPayload(for: .anthropicAPI, experiments: allFeatures)
        let fallback = payload?["refusalFallback"] as? [String: Any]
        XCTAssertEqual(fallback?["mode"] as? String, "providerDefault")
        XCTAssertNil(fallback?["model"], "providerDefault must not name a model")
    }

    // MARK: Tolerant persistence

    func testPreferencesRoundTripThroughJSON() throws {
        for preferences in [
            ClaudeSessionPreferences(),
            ClaudeSessionPreferences(advisor: .automatic),
            ClaudeSessionPreferences(speed: .fast),
            ClaudeSessionPreferences(refusalFallback: .providerDefault),
            ClaudeSessionPreferences(refusalFallback: .model("claude-opus-4-8")),
            ClaudeSessionPreferences(advisor: .automatic, speed: .fast,
                                     refusalFallback: .model("claude-opus-4-8")),
        ] {
            let decoded = try JSONDecoder().decode(
                ClaudeSessionPreferences.self, from: JSONEncoder().encode(preferences))
            XCTAssertEqual(decoded, preferences)
        }
    }

    func testUnknownPersistedValuesDisableThePreferenceInsteadOfFailing() throws {
        // A newer build could persist a preference this one has never heard of. It must degrade to
        // off — the alternative (a throw) propagates up and quarantines the whole conversation.
        let json = """
        {"advisor":"consultAlways","speed":"blistering","refusalFallback":{"mode":"perCategory"}}
        """
        let decoded = try JSONDecoder().decode(
            ClaudeSessionPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, ClaudeSessionPreferences())
    }

    func testStructurallyWrongValuesDecodeToDefaults() throws {
        for json in [
            #"{"advisor":7,"speed":[],"refusalFallback":"providerDefault"}"#,
            #"{"refusalFallback":{"mode":"model"}}"#,          // "model" mode with no model
            #"{"refusalFallback":{"mode":"model","model":""}}"#,
            #"{}"#,
        ] {
            let decoded = try JSONDecoder().decode(
                ClaudeSessionPreferences.self, from: Data(json.utf8))
            XCTAssertEqual(decoded, ClaudeSessionPreferences(), "\(json) must decode to defaults")
        }
    }

    // MARK: Conversation persistence

    func testAConversationWrittenBeforeThisBuildDecodesWithEveryMessage() throws {
        // The `Codable` default trap: a non-optional field with a default silently quarantines older
        // sidecars. `claudePreferences` is optional AND decoded tolerantly, so a sidecar with no key
        // keeps all of its messages. The fixture is derived from a real encode with the key removed,
        // so it stays accurate as the rest of the conversation schema evolves.
        let conversation = try Self.decodeConversation(mutating: { $0["claudePreferences"] = nil })

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.first?.text, "Earlier work")
        XCTAssertNil(conversation.claudePreferences)
        XCTAssertEqual(conversation.claudeSessionPreferences, ClaudeSessionPreferences())
    }

    func testACorruptPreferenceBlockCostsThePreferenceNotTheConversation() throws {
        let conversation = try Self.decodeConversation(mutating: {
            $0["claudePreferences"] = "not-an-object"
        })

        XCTAssertEqual(conversation.messages.count, 1, "the conversation must survive intact")
        XCTAssertEqual(conversation.messages.first?.text, "Earlier work")
        XCTAssertEqual(conversation.claudeSessionPreferences, ClaudeSessionPreferences())
    }

    func testAPreferenceBlockWithOneUnreadableFieldKeepsTheOthers() throws {
        let conversation = try Self.decodeConversation(mutating: {
            $0["claudePreferences"] = ["advisor": "automatic", "speed": 42]
        })

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.claudeSessionPreferences.advisor, .automatic)
        XCTAssertEqual(conversation.claudeSessionPreferences.speed, .standard)
    }

    /// Encode a real conversation, apply `mutating` to its JSON object, and decode it back — the way
    /// to exercise a sidecar shape without hand-writing (and having to maintain) the whole schema.
    private static func decodeConversation(
        mutating: (inout [String: Any]) -> Void
    ) throws -> Conversation {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoder.encode(conversation()))
                as? [String: Any])
        mutating(&object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            Conversation.self,
            from: try JSONSerialization.data(withJSONObject: object))
    }

    func testDefaultPreferencesAddNoKeyToAPersistedConversation() throws {
        let conversation = Self.conversation()
        let encoded = try JSONEncoder().encode(conversation)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        // Nothing new is written for the overwhelming majority of conversations.
        XCTAssertNil(object["claudePreferences"])
    }

    func testAnExplicitPreferenceSurvivesAConversationRoundTrip() throws {
        var conversation = Self.conversation()
        conversation.claudePreferences = ClaudeSessionPreferences(advisor: .automatic, speed: .fast)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            Conversation.self, from: encoder.encode(conversation))

        XCTAssertEqual(decoded.claudePreferences?.advisor, .automatic)
        XCTAssertEqual(decoded.claudePreferences?.speed, .fast)
        XCTAssertEqual(decoded.messages.count, conversation.messages.count)
    }

    private static func conversation() -> Conversation {
        Conversation(
            title: "Fixture",
            cwd: "/tmp",
            sdkSessionId: nil,
            modelSelection: ModelSelection(access: .anthropicAPI, modelID: "claude-opus-5"),
            messages: [TranscriptEntry(kind: .user, text: "Earlier work")],
            updatedAt: Date(timeIntervalSince1970: 1))
    }
}
