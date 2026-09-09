import AppKit
import XCTest
@testable import Mechanician

/// Normalizing a folder path that arrived from outside the app. `ProjectStore.projectID(forCwd:)`
/// matches on an exact trimmed string and mints a new Project otherwise, so every spelling that
/// slips through here becomes a duplicate workspace with its own window.
final class WorkspaceFolderPathTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mechanician-services-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The plan's explicit requirement: three spellings, one identity. Asserted as equality between
    /// the results rather than against a literal, because the canonical form of a temporary
    /// directory is the filesystem's business and differs by volume.
    func testEverySpellingOfOneFolderCanonicalizesTogether() throws {
        let folder = root.appendingPathComponent("dev/mechanician", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let plain = try XCTUnwrap(WorkspaceFolderPath.canonical(folder.path))
        let trailingSlash = try XCTUnwrap(WorkspaceFolderPath.canonical(folder.path + "/"))
        let dotSegment = try XCTUnwrap(
            WorkspaceFolderPath.canonical(root.appendingPathComponent("dev/./mechanician").path))
        let parentSegment = try XCTUnwrap(
            WorkspaceFolderPath.canonical(root.appendingPathComponent("dev/x/../mechanician").path))
        let padded = try XCTUnwrap(WorkspaceFolderPath.canonical(folder.path))

        XCTAssertEqual(trailingSlash, plain)
        XCTAssertEqual(dotSegment, plain)
        XCTAssertEqual(parentSegment, plain)
        XCTAssertEqual(padded, plain)
    }

    func testTildeIsExpanded() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expanded = try XCTUnwrap(WorkspaceFolderPath.canonical("~"))
        XCTAssertEqual(expanded, WorkspaceFolderPath.canonical(home.path))
    }

    /// A symlink to a folder is the same folder. This is the case that makes `canonical` more than
    /// string tidying.
    func testASymlinkResolvesToItsTarget() throws {
        let target = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertEqual(WorkspaceFolderPath.canonical(link.path),
                       WorkspaceFolderPath.canonical(target.path))
    }

    func testOnlyExistingDirectoriesResolve() throws {
        let file = root.appendingPathComponent("notes.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertNil(WorkspaceFolderPath.canonical(file.path), "a file is not a workspace")
        XCTAssertNil(WorkspaceFolderPath.canonical(root.appendingPathComponent("missing").path))
        XCTAssertNil(WorkspaceFolderPath.canonical(""))
        XCTAssertNil(WorkspaceFolderPath.canonical("   "))
    }

    // MARK: - Resolving to a workspace

    @MainActor private func makeProjectStore() -> ProjectStore {
        ProjectStore(appSupportBaseOverride: root.appendingPathComponent("support", isDirectory: true))
    }

    @MainActor
    func testThreeSpellingsResolveToOneWorkspace() throws {
        let folder = root.appendingPathComponent("acorn", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = makeProjectStore()

        let spellings = [folder.path, folder.path + "/", root.appendingPathComponent("./acorn").path]
        let ids = try spellings.map { spelling -> UUID in
            let canonical = try XCTUnwrap(WorkspaceFolderPath.canonical(spelling))
            return try XCTUnwrap(WorkspaceFolderPath.project(forCanonicalPath: canonical, store: store))
        }

        XCTAssertEqual(Set(ids).count, 1, "three spellings minted \(Set(ids).count) workspaces")
        XCTAssertEqual(store.projects.count, 1)
    }

    /// The half that matters more: a workspace recorded years ago under an untidy spelling has to
    /// match, or normalizing only the incoming path swaps one duplicate-minting bug for another.
    @MainActor
    func testAWorkspaceStoredUnderAnUntidySpellingStillMatches() throws {
        let folder = root.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = makeProjectStore()
        store.upsert(Project(name: "Legacy", cwd: folder.path + "/"))   // trailing slash, as stored

        let canonical = try XCTUnwrap(WorkspaceFolderPath.canonical(folder.path))
        let resolved = WorkspaceFolderPath.project(forCanonicalPath: canonical, store: store)

        XCTAssertEqual(resolved, store.projects.first?.id)
        XCTAssertEqual(store.projects.count, 1, "an existing workspace was duplicated")
    }

    /// A folder-less topic workspace must not be matched by a path — every one of them has an empty
    /// `cwd`, and an empty cwd is not "the same folder as" anything.
    @MainActor
    func testTopicWorkspacesAreNeverMatchedByPath() throws {
        let folder = root.appendingPathComponent("topicless", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = makeProjectStore()
        store.upsert(Project(name: "A topic", cwd: ""))

        let canonical = try XCTUnwrap(WorkspaceFolderPath.canonical(folder.path))
        let resolved = WorkspaceFolderPath.project(forCanonicalPath: canonical, store: store)

        XCTAssertNotEqual(resolved, store.projects.first(where: { $0.cwd.isEmpty })?.id)
        XCTAssertEqual(store.projects.count, 2)
    }
}

/// Reading a selection off the Services pasteboard.
final class ServicesPasteboardTests: XCTestCase {
    private func pasteboard(_ name: String) -> NSPasteboard {
        let board = NSPasteboard(name: .init(rawValue: "MechanicianServicesTests.\(name).\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    func testPlainSelectionComesThroughUnchanged() {
        let board = pasteboard("plain")
        board.setString("the paragraph I selected", forType: .string)
        XCTAssertEqual(MechanicianServiceProvider.selectedText(on: board), "the paragraph I selected")
    }

    /// Second real inbound caller of the paste scrub. `ConversationFileReference.matches` decodes
    /// attachment tokens with no authentication, so a token inside text from another app is a
    /// reference somebody else chose — a Services selection is exactly that kind of foreign text.
    func testForgedAttachmentTokensAreNeutralized() {
        let board = pasteboard("forged")
        // Built through the real type. Hand-written JSON would not decode, and this test would pass
        // for the wrong reason — which is exactly what it did on the first run.
        let token = ConversationFileReference(
            storageName: "\(UUID().uuidString).txt",
            displayName: "notes.txt",
            typeIdentifier: "public.plain-text",
            byteCount: 12).promptToken
        board.setString("look at this \(token)", forType: .string)
        let text = MechanicianServiceProvider.selectedText(on: board)
        XCTAssertNotNil(text)
        XCTAssertFalse(text!.contains("<mechanician-file-reference>"),
                       "a forged token survived into the composer")
    }

    /// Truncation is the visible failure — the text lands where the user can see how much arrived.
    func testAnEnormousSelectionIsTruncatedRatherThanRefused() {
        let board = pasteboard("huge")
        let limit = InboundComposerText.characterLimit
        board.setString(String(repeating: "a", count: limit + 5_000), forType: .string)
        let text = MechanicianServiceProvider.selectedText(on: board)
        XCTAssertEqual(text?.count, limit)
    }

    /// An empty draft with a focused composer looks exactly like the service silently failing, and
    /// this path cannot raise a dialog — so nothing usable means do nothing at all.
    func testNothingUsableReadsAsNothing() {
        XCTAssertNil(MechanicianServiceProvider.selectedText(on: pasteboard("empty")))
        let blank = pasteboard("blank")
        blank.setString("   \n\t  ", forType: .string)
        XCTAssertNil(MechanicianServiceProvider.selectedText(on: blank))
    }

    func testOnlyFileURLsAreTakenFromAFinderSelection() {
        let board = pasteboard("files")
        let file = URL(fileURLWithPath: "/usr/bin/true")
        board.writeObjects([file as NSURL, URL(string: "https://example.com")! as NSURL])
        XCTAssertEqual(MechanicianServiceProvider.selectedFileURLs(on: board), [file])
    }
}

/// The plist declares four messages by name and the provider has to answer to exactly those. A
/// rename on either side is silent: the menu item appears and does nothing.
final class ServicesDeclarationTests: XCTestCase {
    private var entries: [[String: Any]] {
        get throws {
            let plistURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("app/Mechanician-Info.plist")
            let data = try Data(contentsOf: plistURL)
            let plist = try XCTUnwrap(
                try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            return try XCTUnwrap(plist["NSServices"] as? [[String: Any]])
        }
    }

    @MainActor
    func testTheProviderAnswersEveryDeclaredMessage() throws {
        let declared = try entries
        XCTAssertEqual(declared.count, 4)
        for entry in declared {
            let message = try XCTUnwrap(entry["NSMessage"] as? String)
            // AppKit sends `message:userData:error:` for an `NSMessage` of `message`.
            let selector = Selector("\(message):userData:error:")
            XCTAssertTrue(
                MechanicianServiceProvider.shared.responds(to: selector),
                "the plist declares \(message) and the provider does not implement it")
        }
    }

    /// **No `NSReturnTypes` on any entry, ever.** A returning service is a synchronous
    /// transformation that blocks the calling app's UI until we hand text back, and the only text
    /// producer here is an agent turn: minutes long, permission-gated, and able to fail. This is the
    /// rule written down as a test, because the cost of breaking it lands in someone else's app.
    func testNoServiceEverReturnsAValue() throws {
        for entry in try entries {
            let message = entry["NSMessage"] as? String ?? "?"
            XCTAssertNil(entry["NSReturnTypes"], "\(message) declares a return type")
        }
    }

    func testEveryEntryIsInTheOneSubmenu() throws {
        for entry in try entries {
            let item = try XCTUnwrap(entry["NSMenuItem"] as? [String: Any])
            let title = try XCTUnwrap(item["default"] as? String)
            // The `/` is what creates the submenu; Mail ships "Mail/New Email With Selection".
            XCTAssertTrue(title.hasPrefix("Mechanician/"), "\(title) is not in the Mechanician submenu")
            XCTAssertFalse(title.dropFirst("Mechanician/".count).contains("/"),
                           "\(title) nests a second level")
        }
    }

    /// `dev.sh` renames the submenu so two identically-named entries can never both sit in another
    /// app's Services menu — picking the wrong one means driving the installed app against real
    /// conversations.
    func testDevScriptRenamesEveryServiceSubmenuEntry() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: repository.appendingPathComponent("dev.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("Set :NSServices:$i:NSMenuItem:default Mechanician Dev/"),
                      "dev.sh does not rename the service submenu")
        // The loop has to cover every declared entry, or a later addition silently keeps its
        // installed-app name in the Dev build.
        let declaredCount = try entries.count
        XCTAssertTrue(script.contains("for i in 0 1 2 3; do"),
                      "dev.sh's rename loop must cover all \(declaredCount) entries")
    }
}
