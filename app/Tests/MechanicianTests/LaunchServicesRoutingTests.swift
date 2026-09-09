import AppKit
import XCTest
@testable import Mechanician

@MainActor
final class LaunchServicesRoutingTests: XCTestCase {
    private func conversation(id: UUID, draft: String = "") -> Conversation {
        Conversation(
            id: id,
            title: "Launch Services routing",
            cwd: "",
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(),
            draft: draft)
    }

    private func sourceFile(named name: String) throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-services-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data("launch services fixture".utf8).write(to: file)
        return (directory, file)
    }

    private func bridge(named name: String) -> (AgentBridge, URL) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        return (
            AgentBridge(settingsBaseOverride: support, environmentOverride: [:]),
            support)
    }

    func testOnlyDestinationWindowConsumesQueuedFilesWhenAnotherWindowReadiesFirst() throws {
        _ = NSApplication.shared
        let store = ConversationStore.shared
        let firstID = UUID()
        let destinationID = UUID()
        let (first, firstSupport) = bridge(named: "launch-first-window")
        let (destination, destinationSupport) = bridge(named: "launch-destination-window")
        let source = try sourceFile(named: "two-window.txt")
        defer {
            first.currentID = nil
            destination.currentID = nil
            first.shutdown()
            destination.shutdown()
            store.remove(firstID)
            store.remove(destinationID)
            store.flushSaves()
            try? FileManager.default.removeItem(at: firstSupport)
            try? FileManager.default.removeItem(at: destinationSupport)
            try? FileManager.default.removeItem(at: source.directory)
        }
        store.upsert(conversation(id: firstID))
        store.upsert(conversation(id: destinationID))

        let active = ActiveWorkspace(
            productAccessRequest: { true },
            whenProductReady: { $0() })
        active.bridge = destination
        active.open(.files([source.file]))

        first.currentID = firstID
        first.isReady = true
        active.consumePending(first)
        XCTAssertTrue(store.conversation(firstID)?.draft.isEmpty == true)
        XCTAssertTrue(store.conversation(destinationID)?.draft.isEmpty == true)

        destination.currentID = destinationID
        destination.isReady = true
        active.consumePending(destination)

        XCTAssertTrue(store.conversation(firstID)?.draft.isEmpty == true)
        let references = ConversationFileReference.matches(
            in: store.conversation(destinationID)?.draft ?? "")
        XCTAssertEqual(references.map(\.reference.displayName), ["two-window.txt"])
    }

    func testQueuedDeliveryKeepsConversationCapturedBeforeNavigation() throws {
        _ = NSApplication.shared
        let store = ConversationStore.shared
        let sourceID = UUID()
        let navigatedID = UUID()
        let (bridge, bridgeSupport) = bridge(named: "launch-navigation")
        let source = try sourceFile(named: "captured-conversation.txt")
        defer {
            bridge.currentID = nil
            bridge.shutdown()
            store.remove(sourceID)
            store.remove(navigatedID)
            store.flushSaves()
            try? FileManager.default.removeItem(at: bridgeSupport)
            try? FileManager.default.removeItem(at: source.directory)
        }
        store.upsert(conversation(id: sourceID))
        store.upsert(conversation(id: navigatedID))
        bridge.currentID = sourceID
        bridge.isReady = false

        let active = ActiveWorkspace(
            productAccessRequest: { true },
            whenProductReady: { $0() })
        active.bridge = bridge
        active.open(.files([source.file]))

        bridge.currentID = navigatedID
        bridge.isReady = true
        active.consumePending(bridge)

        let sourceReferences = ConversationFileReference.matches(
            in: store.conversation(sourceID)?.draft ?? "")
        XCTAssertEqual(
            sourceReferences.map(\.reference.displayName),
            ["captured-conversation.txt"])
        XCTAssertTrue(store.conversation(navigatedID)?.draft.isEmpty == true)
    }

    func testImmediateDeliverySurvivesNavigationBeforeComposerRefresh() throws {
        _ = NSApplication.shared
        let store = ConversationStore.shared
        let sourceID = UUID()
        let navigatedID = UUID()
        let (bridge, bridgeSupport) = bridge(named: "launch-composer-refresh")
        let source = try sourceFile(named: "refresh-race.txt")
        defer {
            bridge.currentID = nil
            bridge.liveDraft = nil
            bridge.liveDraftConversationID = nil
            bridge.shutdown()
            store.remove(sourceID)
            store.remove(navigatedID)
            store.flushSaves()
            try? FileManager.default.removeItem(at: bridgeSupport)
            try? FileManager.default.removeItem(at: source.directory)
        }
        store.upsert(conversation(id: sourceID))
        store.upsert(conversation(id: navigatedID))
        bridge.currentID = sourceID
        bridge.isReady = true
        bridge.liveDraft = { "already typed" }
        bridge.liveDraftConversationID = { sourceID }

        let active = ActiveWorkspace(
            productAccessRequest: { true },
            whenProductReady: { $0() })
        active.bridge = bridge
        active.open(.files([source.file]))
        bridge.select(navigatedID)

        let storedDraft = store.conversation(sourceID)?.draft ?? ""
        XCTAssertTrue(storedDraft.hasPrefix("already typed\n"))
        XCTAssertEqual(
            ConversationFileReference.matches(in: storedDraft)
                .map(\.reference.displayName),
            ["refresh-race.txt"])
        XCTAssertTrue(store.conversation(navigatedID)?.draft.isEmpty == true)
    }
}
