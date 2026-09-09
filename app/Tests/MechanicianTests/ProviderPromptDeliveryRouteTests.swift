import XCTest
@testable import Mechanician

/// A message can reach a provider through several routes: the first send, a queued prompt drained
/// after the running turn, guidance steered into a live turn, a retry, Edit & Resend, a background
/// send for a non-visible conversation, and history replay after a session rewind.
///
/// Each of those must expand the composer's compact artifact and file tokens. A route that forgets
/// ships `<mechanician-file-reference>{…}` to the model as literal JSON: the attachment silently
/// becomes unreadable transport metadata rather than the file the user attached, and it fails
/// quietly — the turn still completes, just without the attachment.
@MainActor
final class ProviderPromptDeliveryRouteTests: XCTestCase {
    private func makeStore(_ base: URL) -> ConversationStore {
        ConversationStore(
            appSupportBaseOverride: base.appendingPathComponent("support", isDirectory: true),
            watchesDirectory: false)
    }

    func testSharedBoundaryExpandsArtifactAndFileTokensTogetherInAuthoredOrder() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeliveryRouteTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = base.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let source = sourceDirectory.appendingPathComponent("Project brief.pdf")
        try Data("%PDF-1.7\nattached".utf8).write(to: source)

        let store = makeStore(base)
        let ownerID = UUID()
        let reference = try XCTUnwrap(store.persistComposerFile(
            at: source,
            conversationID: ownerID))

        let artifactStore = ArtifactStore(
            appSupportBaseOverride: base.appendingPathComponent(
                "artifacts",
                isDirectory: true),
            watchesDirectory: false)
        let durable = artifactStore.upsertFromAgent(
            title: "Sales chart",
            type: "html",
            source: "<h1>Launch</h1>",
            workspaceID: nil,
            conversationID: nil,
            conversationTitle: "",
            cwd: "")
        defer { artifactStore.flushSaves() }
        let artifact = ArtifactDragReference(
            artifactID: durable.uuid,
            title: durable.title,
            type: durable.type,
            currentSourcePath: "/tmp/Sales chart.html")

        // Both kinds in one prompt: the two expanders run in sequence, and a change to either one
        // must not consume or reorder the other's token.
        let prompt = "first \(artifact.promptToken) middle \(reference.promptToken) last"
        let expanded = AgentBridge.providerPrompt(
            from: prompt,
            conversationID: ownerID,
            store: store,
            artifactStore: artifactStore)

        XCTAssertFalse(expanded.contains(ArtifactDragReference.openingTag))
        XCTAssertFalse(expanded.contains(ConversationFileReference.openingTag))
        XCTAssertTrue(expanded.contains("<mechanician-artifact-context>"))
        XCTAssertTrue(expanded.contains("<mechanician-file-context>"))

        let artifactPosition = try XCTUnwrap(
            expanded.range(of: "<mechanician-artifact-context>")).lowerBound
        let filePosition = try XCTUnwrap(
            expanded.range(of: "<mechanician-file-context>")).lowerBound
        XCTAssertLessThan(
            artifactPosition,
            filePosition,
            "Expansion must preserve the order the user authored.")
        XCTAssertTrue(expanded.hasPrefix("first "))
        XCTAssertTrue(expanded.hasSuffix(" last"))
    }

    func testSharedBoundaryKeepsAnotherConversationsAttachmentInert() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeliveryRouteTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = base.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let source = sourceDirectory.appendingPathComponent("Private notes.txt")
        try Data("confidential".utf8).write(to: source)

        let store = makeStore(base)
        let ownerID = UUID()
        let reference = try XCTUnwrap(store.persistComposerFile(
            at: source,
            conversationID: ownerID))
        let prompt = "Summarise \(reference.promptToken)"

        // Retry and Edit & Resend replay stored prompt text. If a replayed prompt were expanded
        // against the wrong conversation, one conversation's attachment would leak into another.
        XCTAssertEqual(
            AgentBridge.providerPrompt(
                from: prompt,
                conversationID: UUID(),
                store: store),
            prompt)
        XCTAssertNotEqual(
            AgentBridge.providerPrompt(
                from: prompt,
                conversationID: ownerID,
                store: store),
            prompt)
    }

    /// Guard the wiring rather than the expander: the expander is covered above and by
    /// `ConversationFileReferenceTests`, but nothing otherwise stops a new send path from writing a
    /// raw draft straight to the provider.
    func testEveryProviderPromptWriteSendsAnExpandedValue() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MechanicianTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .appendingPathComponent("Sources/Mechanician/AgentBridge.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        var offenders: [String] = []
        var writes = 0
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            // Only dictionary literals headed for the provider carry a "prompt" key with a value.
            guard let range = line.range(of: "\"prompt\":") else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            writes += 1
            guard value.hasPrefix("providerPrompt") else {
                offenders.append("AgentBridge.swift:\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                continue
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            Every prompt written to a provider must be expanded through \
            AgentBridge.providerPrompt(from:conversationID:), or the user's attachments reach the \
            model as raw transport JSON. Unexpanded write(s):
            \(offenders.joined(separator: "\n"))
            """)
        XCTAssertEqual(
            writes,
            3,
            """
            The known provider prompt writes are the interactive send, the guidance steer, and the \
            background send. A change here means a delivery route was added or removed — confirm \
            it expands attachments, then update this count.
            """)
    }
}
