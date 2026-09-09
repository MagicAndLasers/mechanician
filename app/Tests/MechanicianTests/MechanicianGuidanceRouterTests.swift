import AppKit
import XCTest
@testable import Mechanician

@MainActor
final class MechanicianGuidanceRouterTests: XCTestCase {
    private final class ValidityBox {
        var isValid = true
    }

    private final class GuideLoadGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<MechanicianHelpGuidanceSource?, Never>?

        var isWaiting: Bool {
            lock.withLock { continuation != nil }
        }

        func wait() async -> MechanicianHelpGuidanceSource? {
            await withCheckedContinuation { continuation in
                lock.withLock { self.continuation = continuation }
            }
        }

        func resume(returning source: MechanicianHelpGuidanceSource?) {
            let pending = lock.withLock {
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume(returning: source)
        }
    }

    private struct OwnedWindowFixture {
        let bridge: AgentBridge
        let window: NSWindow
        let support: URL
        let conversationID: UUID

        @MainActor
        func cleanUp() {
            bridge.window = nil
            bridge.shutdown()
            ConversationStore.shared.remove(conversationID, permanently: true)
            window.orderOut(nil)
            window.contentView = nil
            try? FileManager.default.removeItem(at: support)
        }
    }

    private let metadata = MechanicianHelpMetadata(
        schemaVersion: 4,
        corpusID: "mechanician.public",
        applicationVersion: "9.9.9",
        applicationBuild: "999",
        bundleIdentifier: "ai.mechanician.tests",
        tenantID: "default",
        sourceCommit: "source",
        sourceDiffSHA256: String(repeating: "b", count: 64),
        contentSHA256: String(repeating: "a", count: 64))

    private func ownedWindow(
        projectID: UUID? = nil,
        name: String = #function
    ) -> OwnedWindowFixture {
        _ = NSApplication.shared
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("show-mechanician-\(name)-\(UUID().uuidString)",
                                  isDirectory: true)
        let bridge = AgentBridge(settingsBaseOverride: support, environmentOverride: [:])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        bridge.window = window
        bridge.projectID = projectID
        let conversation = Conversation(
            title: "Guidance fixture",
            cwd: "",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(),
            draft: "retained test fixture",
            projectID: projectID)
        ConversationStore.shared.upsert(conversation)
        bridge.currentID = conversation.id
        return OwnedWindowFixture(
            bridge: bridge,
            window: window,
            support: support,
            conversationID: conversation.id)
    }

    private func admission(
        for fixture: OwnedWindowFixture,
        profile: ProviderToolProfile = .standard,
        guideID: String = "inspector.changes-tour",
        corpusContentSHA256: String? = nil,
        validity: ValidityBox = ValidityBox()
    ) -> MechanicianGuidanceSourceAdmission {
        MechanicianGuidanceSourceAdmission(
            bridge: fixture.bridge,
            window: fixture.window,
            conversationID: fixture.bridge.currentID!,
            toolProfile: profile,
            guideID: guideID,
            corpusContentSHA256: corpusContentSHA256 ?? metadata.contentSHA256,
            revalidateTurn: { validity.isValid })!
    }

    private func guide(
        id: String = "inspector.changes-tour",
        surface: MechanicianHelpGuideSurface = .conversationWorkspace,
        lifecycle: MechanicianHelpLifecycle = .current,
        steps: [MechanicianHelpGuideStep]? = nil
    ) -> MechanicianHelpGuide {
        MechanicianHelpGuide(
            id: id,
            articleID: "inspector",
            title: "Show the Changes panel",
            summary: "Show the Changes tab in this conversation's own window.",
            surface: surface,
            lifecycle: lifecycle,
            ordinal: 0,
            claimKeys: ["inspector.changes"],
            steps: steps ?? [
                MechanicianHelpGuideStep(
                    id: "inspector.changes-tour.tab",
                    title: "Open Changes",
                    instruction: "Use the Changes inspector tab.",
                    target: .conversationChangesTab,
                    revealAction: .showChangesInspector,
                    completion: .userAdvance,
                    ordinal: 0),
                MechanicianHelpGuideStep(
                    id: "inspector.changes-tour.composer",
                    title: "Where the work starts",
                    instruction: "Use the message box.",
                    target: .conversationComposer,
                    revealAction: .showConversationControls,
                    completion: .userAdvance,
                    ordinal: 1),
            ],
            evidence: [])
    }

    private func router(
        source: MechanicianHelpGuidanceSource?,
        target: OwnedWindowFixture,
        productAccessAllowed: @escaping @MainActor () -> Bool = { true },
        resolveConversation: MechanicianGuidanceRouter.ConversationWorkspaceResolver? = nil,
        monotonicNow: @escaping MechanicianGuidanceRouter.MonotonicNow = {
            ProcessInfo.processInfo.systemUptime
        },
        requestTimeout: TimeInterval = 12,
        attempts: Int = 40
    ) -> MechanicianGuidanceRouter {
        MechanicianGuidanceRouter(
            loadGuide: { _ in source },
            productAccessAllowed: productAccessAllowed,
            resolveConversationWorkspace: resolveConversation ?? { _ in target.bridge },
            targetIsReady: { bridge, window in
                bridge === target.bridge && window === target.window
            },
            monotonicNow: monotonicNow,
            requestTimeout: requestTimeout,
            targetRegistrationAttempts: attempts,
            targetRegistrationDelayNanoseconds: 0)
    }

    private func registerConversationTargets(
        in registry: GuidedHelpTargetRegistry,
        window: NSWindow
    ) {
        guard let content = window.contentView else { return }
        let tab = NSView(frame: NSRect(x: 710, y: 580, width: 70, height: 32))
        let composer = NSView(frame: NSRect(x: 600, y: 500, width: 180, height: 34))
        content.addSubview(tab)
        content.addSubview(composer)
        XCTAssertTrue(registry.register(.conversationChangesTab, view: tab))
        XCTAssertTrue(registry.register(.conversationComposer, view: composer))
    }

    private func startAndRegister(
        router: MechanicianGuidanceRouter,
        source: MechanicianGuidanceSourceAdmission,
        target: OwnedWindowFixture,
        guideID: String = "inspector.changes-tour"
    ) async -> MechanicianGuidanceStartResult {
        let priorCoordinator = router.targetCoordinator
        let task = Task { await router.start(guideID: guideID, source: source) }
        for _ in 0..<100 {
            if router.targetCoordinator !== priorCoordinator,
               let registry = router.registry(for: target.bridge) {
                registerConversationTargets(in: registry, window: target.window)
                break
            }
            await Task.yield()
        }
        return await task.value
    }

    private func restoreDefault(_ key: String, to value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func testProfilesAndSignedVocabularyAdmitOnlyInteractiveConversationGuides() {
        XCTAssertTrue(ProviderToolProfile.standard.permitsMechanicianGuidance)
        XCTAssertTrue(ProviderToolProfile.helpExpert.permitsMechanicianGuidance)
        XCTAssertTrue(MechanicianGuidanceRouter.isAdmissibleAgentGuide(guide()))
        // The Help reader's own tour is presented from inside Help, never by an agent request.
        XCTAssertFalse(MechanicianGuidanceRouter.isAdmissibleAgentGuide(
            guide(surface: .helpWorkspaceInspector)))
        XCTAssertFalse(MechanicianGuidanceRouter.isAdmissibleAgentGuide(
            guide(lifecycle: .historical)))
        XCTAssertFalse(MechanicianGuidanceRouter.isAdmissibleAgentGuide(guide(steps: [
            MechanicianHelpGuideStep(
                id: "forged",
                title: "Forged",
                instruction: "Try a Help-only target.",
                target: .helpSearchField,
                revealAction: .showChangesInspector,
                completion: .userAdvance,
                ordinal: 0),
        ])))
    }

    func testSearchAdmissionIsExactTurnRouteDigestAndSingleReservation() {
        let digest = String(repeating: "a", count: 64)
        let route = MechanicianGuidanceSearchAdmissionLedger.Route(
            conversationID: UUID(),
            selection: ModelSelection(access: .claudeSubscription, modelID: "model-a"),
            toolProfile: .helpExpert)
        var subject = MechanicianGuidanceSearchAdmissionLedger()
        subject.acknowledge(
            MechanicianHelpGuideAdmission(
                guideIDs: ["memory.inspector-tour", "memory.second-tour"],
                corpusContentSHA256: digest),
            turnID: "turn-a",
            route: route)

        let first = subject.reserve(
            guideID: "memory.inspector-tour", turnID: "turn-a", route: route)
        XCTAssertNotNil(first)
        XCTAssertNil(subject.reserve(
            guideID: "memory.inspector-tour", turnID: "turn-a", route: route))
        XCTAssertNil(subject.reserve(
            guideID: "memory.second-tour", turnID: "turn-b", route: route))
        XCTAssertNil(subject.reserve(
            guideID: "memory.second-tour",
            turnID: "turn-a",
            route: .init(
                conversationID: route.conversationID,
                selection: route.selection,
                toolProfile: .standard)))

        subject.restore(first!)
        XCTAssertNotNil(subject.reserve(
            guideID: "memory.inspector-tour", turnID: "turn-a", route: route))
    }

    func testSearchAdmissionsUnionBoundedlyAndCorpusReplacementInvalidatesReservations() {
        let route = MechanicianGuidanceSearchAdmissionLedger.Route(
            conversationID: UUID(),
            selection: ModelSelection(access: .codexSubscription, modelID: "model-b"),
            toolProfile: .standard)
        let firstDigest = String(repeating: "a", count: 64)
        let secondDigest = String(repeating: "b", count: 64)
        var subject = MechanicianGuidanceSearchAdmissionLedger()
        subject.acknowledge(
            .init(guideIDs: ["memory.first"], corpusContentSHA256: firstDigest),
            turnID: "turn",
            route: route)
        let first = subject.reserve(guideID: "memory.first", turnID: "turn", route: route)!
        XCTAssertTrue(subject.isCurrent(first))
        subject.restore(first)
        subject.acknowledge(
            .init(guideIDs: ["memory.second"], corpusContentSHA256: firstDigest),
            turnID: "turn",
            route: route)
        XCTAssertNotNil(subject.reserve(
            guideID: "memory.first", turnID: "turn", route: route))
        XCTAssertNotNil(subject.reserve(
            guideID: "memory.second", turnID: "turn", route: route))

        subject.acknowledge(
            .init(
                guideIDs: (0..<20).map { "memory.guide-\($0)" },
                corpusContentSHA256: firstDigest),
            turnID: "turn",
            route: route)
        XCTAssertNil(subject.reserve(
            guideID: "memory.guide-0", turnID: "turn", route: route))
        XCTAssertNotNil(subject.reserve(
            guideID: "memory.guide-19", turnID: "turn", route: route))

        subject.acknowledge(
            .init(guideIDs: ["memory.replacement"], corpusContentSHA256: secondDigest),
            turnID: "turn",
            route: route)
        XCTAssertFalse(subject.isCurrent(first))
        subject.restore(first)
        XCTAssertNil(subject.reserve(
            guideID: "memory.first", turnID: "turn", route: route))
        XCTAssertNotNil(subject.reserve(
            guideID: "memory.replacement", turnID: "turn", route: route))
    }

    func testMalformedSearchAdmissionClearsTheTurnAndRemovalClearsValidOffers() {
        let route = MechanicianGuidanceSearchAdmissionLedger.Route(
            conversationID: UUID(),
            selection: ModelSelection(access: .openAIAPI, modelID: "model-c"),
            toolProfile: .standard)
        var subject = MechanicianGuidanceSearchAdmissionLedger()
        subject.acknowledge(
            .init(
                guideIDs: ["memory.inspector-tour"],
                corpusContentSHA256: String(repeating: "a", count: 64)),
            turnID: "turn",
            route: route)
        subject.acknowledge(
            .init(guideIDs: ["memory.inspector-tour"], corpusContentSHA256: "not-a-digest"),
            turnID: "turn",
            route: route)
        XCTAssertNil(subject.reserve(
            guideID: "memory.inspector-tour", turnID: "turn", route: route))

        subject.acknowledge(
            .init(
                guideIDs: ["memory.inspector-tour"],
                corpusContentSHA256: String(repeating: "a", count: 64)),
            turnID: "turn",
            route: route)
        subject.remove(turnID: "turn")
        XCTAssertNil(subject.reserve(
            guideID: "memory.inspector-tour", turnID: "turn", route: route))
    }

    func testAgentBridgeRetainsExactSourceAcrossAsyncStart() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Mechanician/AgentBridge.swift"),
            encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func applyShowMechanicianRequest("))
        let rest = source[start.lowerBound...]
        let end = try XCTUnwrap(rest.range(of:
            "\n    /// Consume only the acknowledgement for the exact started session."))
        let body = String(rest[..<end.lowerBound])

        XCTAssertTrue(body.contains("Task { [weak self, source] in"))
        XCTAssertFalse(body.contains("Task { [weak self, weak source] in"))
        XCTAssertTrue(body.contains("source.isCurrent"))
        XCTAssertTrue(body.contains("cancel(sessionToken: sessionToken)"))
    }

    func testAdmissionIsExactBridgeWindowConversationAndProfile() {
        let source = ownedWindow()
        let other = ownedWindow()
        defer {
            source.cleanUp()
            other.cleanUp()
        }

        XCTAssertNotNil(admission(for: source))
        XCTAssertNil(MechanicianGuidanceSourceAdmission(
            bridge: source.bridge,
            window: other.window,
            conversationID: source.bridge.currentID!,
            toolProfile: .standard,
            guideID: "inspector.changes-tour",
            corpusContentSHA256: metadata.contentSHA256,
            revalidateTurn: { true }))
        XCTAssertNil(MechanicianGuidanceSourceAdmission(
            bridge: source.bridge,
            window: source.window,
            conversationID: UUID(),
            toolProfile: .standard,
            guideID: "inspector.changes-tour",
            corpusContentSHA256: metadata.contentSHA256,
            revalidateTurn: { true }))
    }

    func testInvalidGuideIDDoesNotReplaceAnActivePresentation() async throws {
        let sourceFixture = ownedWindow()
        let target = ownedWindow()
        defer {
            sourceFixture.cleanUp()
            target.cleanUp()
        }
        let active = try XCTUnwrap(GuidedHelpPresentationCoordinator(
            bridge: target.bridge, window: target.window))
        let presentation = GuidedHelpPresentationGuide(
            id: "manual-help",
            title: "Manual Help",
            corpusDigest: metadata.contentSHA256,
            steps: [GuidedHelpPresentationStep(
                id: "manual",
                target: .helpTopics,
                title: "Browse Help",
                instruction: "Browse the topics.")])
        XCTAssertEqual(active.present(presentation), .started)

        let result = await router(source: nil, target: target).start(
            guideID: "not-a-guide",
            source: admission(for: sourceFixture))
        XCTAssertEqual(result, .failed(.sourceInvalidated))
        XCTAssertEqual(active.snapshot?.guideID, "manual-help")
        active.exit()
    }

    func testGuideMustMatchTheAppPrivateSearchIDAndCorpusDigest() async {
        let sourceFixture = ownedWindow()
        let target = ownedWindow()
        defer {
            sourceFixture.cleanUp()
            target.cleanUp()
        }
        let signed = MechanicianHelpGuidanceSource(guide: guide(), metadata: metadata)
        let subject = router(source: signed, target: target)

        let wrongID = await subject.start(
            guideID: signed.guide.id,
            source: admission(for: sourceFixture, guideID: "memory.other-tour"))
        XCTAssertEqual(wrongID, .failed(.sourceInvalidated))
        let wrongDigest = await subject.start(
            guideID: signed.guide.id,
            source: admission(
                for: sourceFixture,
                corpusContentSHA256: String(repeating: "c", count: 64)))
        XCTAssertEqual(wrongDigest, .failed(.guideUnavailable))
        XCTAssertNil(subject.targetCoordinator)
    }

    func testHelpSurfaceIsRejectedWithoutReplacingAnActivePresentation() async throws {
        let sourceFixture = ownedWindow()
        let target = ownedWindow()
        defer {
            sourceFixture.cleanUp()
            target.cleanUp()
        }
        let active = try XCTUnwrap(GuidedHelpPresentationCoordinator(
            bridge: target.bridge, window: target.window))
        let presentation = GuidedHelpPresentationGuide(
            id: "manual-help",
            title: "Manual Help",
            corpusDigest: metadata.contentSHA256,
            steps: [GuidedHelpPresentationStep(
                id: "manual",
                target: .helpTopics,
                title: "Browse Help",
                instruction: "Browse the topics.")])
        XCTAssertEqual(active.present(presentation), .started)

        let helpSource = MechanicianHelpGuidanceSource(
            guide: guide(surface: .helpWorkspaceInspector), metadata: metadata)
        let result = await router(source: helpSource, target: target).start(
            guideID: helpSource.guide.id,
            source: admission(for: sourceFixture))
        XCTAssertEqual(result, .failed(.unsupportedSurface))
        XCTAssertEqual(active.snapshot?.guideID, "manual-help")
        active.exit()
    }



    func testDelayedGuideLoadPastAppDeadlineCannotRouteOrPresent() async {
        let sourceFixture = ownedWindow()
        let target = ownedWindow()
        defer {
            sourceFixture.cleanUp()
            target.cleanUp()
        }
        var now: TimeInterval = 100
        let loadGate = GuideLoadGate()
        var routeCount = 0
        let signed = MechanicianHelpGuidanceSource(guide: guide(), metadata: metadata)
        let subject = MechanicianGuidanceRouter(
            loadGuide: { _ in
                await loadGate.wait()
            },
            productAccessAllowed: { true },
            resolveConversationWorkspace: { _ in
                routeCount += 1
                return target.bridge
            },
            targetIsReady: { _, _ in true },
            monotonicNow: { now },
            requestTimeout: 12,
            targetRegistrationAttempts: 1,
            targetRegistrationDelayNanoseconds: 0)
        let source = admission(for: sourceFixture)
        let task = Task { await subject.start(guideID: signed.guide.id, source: source) }
        for _ in 0..<100 where !loadGate.isWaiting { await Task.yield() }
        XCTAssertTrue(loadGate.isWaiting)

        now = 113
        loadGate.resume(returning: signed)
        let result = await task.value
        XCTAssertEqual(result, .failed(.requestExpired))
        XCTAssertEqual(routeCount, 0)
        XCTAssertNil(subject.targetCoordinator)
        XCTAssertFalse(target.window.contentView?.subviews.contains(where: {
            $0 is GuidedHelpOverlayView
        }) ?? true)
    }


    func testRegistrationTimeoutFailsClosedWithoutAnOverlay() async {
        let sourceFixture = ownedWindow()
        let target = ownedWindow()
        defer {
            sourceFixture.cleanUp()
            target.cleanUp()
        }
        let signed = MechanicianHelpGuidanceSource(guide: guide(), metadata: metadata)
        let subject = router(source: signed, target: target, attempts: 1)

        let result = await subject.start(
            guideID: signed.guide.id,
            source: admission(for: sourceFixture))
        XCTAssertEqual(result, .failed(.targetUnavailable))
        XCTAssertNil(subject.targetCoordinator)
        XCTAssertNil(subject.registry(for: target.bridge))
        XCTAssertFalse(target.window.contentView?.subviews.contains(where: {
            $0 is GuidedHelpOverlayView
        }) ?? true)
    }

    func testPresentationIsBoundOnlyToTheExactTargetWindowAndRoute() async {
        let sourceFixture = ownedWindow()
        let target = ownedWindow()
        let unrelated = ownedWindow()
        defer {
            sourceFixture.cleanUp()
            target.cleanUp()
            unrelated.cleanUp()
        }
        let signed = MechanicianHelpGuidanceSource(guide: guide(), metadata: metadata)
        let subject = router(source: signed, target: target)
        let result = await startAndRegister(
            router: subject,
            source: admission(for: sourceFixture),
            target: target)
        guard case let .started(_, token) = result else {
            return XCTFail("expected started, got \(result)")
        }

        XCTAssertNil(subject.registry(for: sourceFixture.bridge))
        XCTAssertNotNil(subject.registry(for: target.bridge))
        XCTAssertNil(subject.registry(for: unrelated.bridge))
        XCTAssertFalse(sourceFixture.window.contentView?.subviews.contains(where: {
            $0 is GuidedHelpOverlayView
        }) ?? true)
        XCTAssertTrue(target.window.contentView?.subviews.contains(where: {
            $0 is GuidedHelpOverlayView
        }) ?? false)
        XCTAssertFalse(unrelated.window.contentView?.subviews.contains(where: {
            $0 is GuidedHelpOverlayView
        }) ?? true)
        subject.cancel(sessionToken: token)
    }

    func testStaleSessionTokenCannotCancelNewerGuide() async {
        let sourceFixture = ownedWindow()
        let target = ownedWindow()
        defer {
            sourceFixture.cleanUp()
            target.cleanUp()
        }
        let signed = MechanicianHelpGuidanceSource(guide: guide(), metadata: metadata)
        let subject = router(source: signed, target: target)
        let source = admission(for: sourceFixture)
        let first = await startAndRegister(router: subject, source: source, target: target)
        guard case let .started(_, firstToken) = first else {
            return XCTFail("expected first guide to start, got \(first)")
        }
        let second = await startAndRegister(router: subject, source: source, target: target)
        guard case let .started(_, secondToken) = second else {
            return XCTFail("expected second guide to start, got \(second)")
        }

        subject.cancel(sessionToken: firstToken)
        XCTAssertNotNil(subject.targetCoordinator?.snapshot)
        subject.cancel(sessionToken: secondToken)
        XCTAssertNil(subject.targetCoordinator)
    }



    func testInspectorFallbackTrueAndFalseArePreservedAroundEveryGuideAssignment() {
        let panelKey = "panel.inspector"
        let priorPanel = UserDefaults.standard.object(forKey: panelKey)
        defer { restoreDefault(panelKey, to: priorPanel) }
        let target = ownedWindow()
        defer { target.cleanUp() }

        for fallback in [false, true] {
            target.bridge.showInspector = false
            target.bridge.inspectorTab = .artifacts
            UserDefaults.standard.set(fallback, forKey: panelKey)
            let navigation = ConversationGuidanceNavigationSnapshot(bridge: target.bridge)
            navigation.reveal(tab: .changes)
            XCTAssertEqual(UserDefaults.standard.bool(forKey: panelKey), fallback)
            navigation.restoreIfUnchanged()
            XCTAssertFalse(target.bridge.showInspector)
            XCTAssertEqual(target.bridge.inspectorTab, .artifacts)
            XCTAssertEqual(UserDefaults.standard.bool(forKey: panelKey), fallback)
        }
    }
}
