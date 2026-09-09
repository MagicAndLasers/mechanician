import XCTest
@testable import Mechanician

private final class TestMCPSecretVault: MCPSecretVault {
    var values: [String: String] = [:]
    var removed: [String] = []
    var storesBeforeFailure: Int?

    func store(_ value: String, account: String) throws {
        if let storesBeforeFailure, values.count >= storesBeforeFailure {
            throw MCPSecretVaultError.commandFailed("fixture failure")
        }
        values[account] = value
    }

    func read(account: String) throws -> String {
        guard let value = values[account] else { throw MCPSecretVaultError.missing(account) }
        return value
    }

    func remove(account: String) throws {
        values[account] = nil
        removed.append(account)
    }
}

final class MCPSecretPersistenceTests: XCTestCase {
    private let fixedNonce = UUID(uuidString: "2B4794C9-4BB5-4FD0-924A-C871CA93C24E")!

    func testSecretsRoundTripThroughVaultAndNeverAppearInPersistedValues() throws {
        let vault = TestMCPSecretVault()
        var server = MCPServer(
            id: UUID(uuidString: "7F661A72-4885-42AD-BCE1-242B6741D88A")!,
            name: "fixture", enabled: true, transport: .stdio,
            command: "/usr/bin/env", args: ["node"])
        server.env = ["API_TOKEN": "super-secret"]
        server.headers = ["Authorization": "Bearer hidden"]

        let protected = try MCPSecretPersistence.protect(
            [server], vault: vault, nonce: { self.fixedNonce })

        XCTAssertEqual(protected.accounts.count, 2)
        XCTAssertTrue(protected.servers[0].env["API_TOKEN"]!.hasPrefix(MCPSecretReference.prefix))
        XCTAssertTrue(protected.servers[0].headers["Authorization"]!.hasPrefix(MCPSecretReference.prefix))
        let persistedJSON = String(decoding: try JSONEncoder().encode(protected.servers), as: UTF8.self)
        XCTAssertFalse(persistedJSON.contains("super-secret"))
        XCTAssertFalse(persistedJSON.contains("Bearer hidden"))

        let hydrated = MCPSecretPersistence.hydrate(protected.servers, vault: vault)
        XCTAssertEqual(hydrated.servers, [server])
        XCTAssertFalse(hydrated.needsMigration)
        XCTAssertTrue(hydrated.warnings.isEmpty)
    }

    func testReferenceBindingMatchesNodeImplementationAndChangesWithEndpoint() {
        var server = MCPServer(
            id: UUID(uuidString: "7F661A72-4885-42AD-BCE1-242B6741D88A")!,
            transport: .stdio, command: "/usr/bin/env", args: ["node"])
        XCTAssertEqual(
            MCPSecretReference.bindingDigest(server),
            "02dd5027d3dc9d7d23849fe45f8b6af69dafdafe644161bf3d2bbbe577e3aa9e")
        let reference = MCPSecretReference.make(
            server: server, kind: "env", key: "API_TOKEN", nonce: fixedNonce)
        XCTAssertTrue(MCPSecretReference.isValid(
            reference, server: server, kind: "env", key: "API_TOKEN"))
        server.command = "/tmp/different"
        XCTAssertFalse(MCPSecretReference.isValid(
            reference, server: server, kind: "env", key: "API_TOKEN"))
    }

    func testFailedProtectionDeletesOnlyAccountsCreatedByAttempt() {
        let vault = TestMCPSecretVault()
        vault.storesBeforeFailure = 1
        var server = MCPServer(name: "fixture", transport: .stdio, command: "/bin/test")
        server.env = ["ONE": "first", "TWO": "second"]

        XCTAssertThrowsError(try MCPSecretPersistence.protect(
            [server], vault: vault, nonce: { self.fixedNonce }))
        XCTAssertTrue(vault.values.isEmpty)
        XCTAssertEqual(vault.removed.count, 1)
    }

    func testLegacyPlaintextRequestsMigrationWithoutLosingValue() {
        let vault = TestMCPSecretVault()
        var server = MCPServer(name: "legacy", transport: .http, url: "https://example.com/mcp")
        server.headers = ["Authorization": "Bearer legacy"]

        let hydrated = MCPSecretPersistence.hydrate([server], vault: vault)

        XCTAssertEqual(hydrated.servers, [server])
        XCTAssertTrue(hydrated.needsMigration)
        XCTAssertTrue(hydrated.warnings.isEmpty)
    }

    func testMalformedReferenceIsNeverStoredAsASecretDuringAnUnrelatedSave() {
        let vault = TestMCPSecretVault()
        var server = MCPServer(name: "broken", transport: .http, url: "https://example.com/mcp")
        server.headers = ["Authorization": MCPSecretReference.prefix + "not-a-valid-reference"]

        let hydrated = MCPSecretPersistence.hydrate([server], vault: vault)
        XCTAssertFalse(hydrated.warnings.isEmpty)
        XCTAssertThrowsError(try MCPSecretPersistence.protect(
            hydrated.servers, vault: vault, nonce: { self.fixedNonce })) { error in
            guard case MCPSecretVaultError.invalidReference = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(vault.values.isEmpty)
    }

    func testRemovedServerAccountsAreIdentifiedAndDeletedAfterReplacement() throws {
        let vault = TestMCPSecretVault()
        var server = MCPServer(name: "retired", transport: .stdio, command: "/bin/test")
        server.env = ["TOKEN": "secret"]
        let old = try MCPSecretPersistence.protect(
            [server], vault: vault, nonce: { self.fixedNonce })

        let currentAccounts = Set<String>()
        let stale = old.accounts.subtracting(currentAccounts)
        MCPSecretPersistence.remove(stale, vault: vault)

        XCTAssertEqual(Set(vault.removed), old.accounts)
        XCTAssertTrue(vault.values.isEmpty)
    }

    func testAtomicPrivateFileHasOwnerOnlyPermissionsAndNoTemporarySibling() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("extensions.json")

        try PrivateAtomicFile.write(Data("private".utf8), to: file)

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["extensions.json"])

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        PrivateAtomicFile.enforcePrivatePermissions(at: file)
        let tightened = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((tightened[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
