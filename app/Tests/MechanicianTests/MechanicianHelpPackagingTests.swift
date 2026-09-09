import CryptoKit
import Foundation
import XCTest
@testable import Mechanician

final class MechanicianHelpPackagingTests: XCTestCase {
    func testReleaseAndDevelopmentBundlesUseTheSameStagingHelperBeforeSigning() throws {
        let build = try source("build-app.sh")
        let development = try source("dev.sh")

        XCTAssertEqual(build.components(separatedBy: "stage-help-corpus.sh").count - 1, 1)
        XCTAssertEqual(development.components(separatedBy: "stage-help-corpus.sh").count - 1, 1)
        XCTAssertLessThan(
            try XCTUnwrap(build.range(of: "stage-help-corpus.sh")?.lowerBound),
            try XCTUnwrap(build.range(of: "SIGNING_TEAM_ID")?.lowerBound))
        XCTAssertLessThan(
            try XCTUnwrap(development.range(of: "stage-help-corpus.sh")?.lowerBound),
            try XCTUnwrap(development.range(of: "[dev] signing")?.lowerBound))
        XCTAssertTrue(build.contains("$APP/Contents/Resources/node"))
    }

    func testReleaseProvenanceRecordsTheSealedCorpus() throws {
        let build = try source("build-app.sh")

        XCTAssertTrue(build.contains("helpCorpusSchemaVersion"))
        XCTAssertTrue(build.contains("helpCorpusSHA256"))
        XCTAssertTrue(build.contains("MechanicianHelp.sqlite"))
        XCTAssertTrue(build.contains("sqlite3 -readonly"))
        XCTAssertTrue(build.contains("$HELP_CORPUS_SCHEMA_VERSION"))
        XCTAssertTrue(build.contains("$SOURCE_COMMIT\" \"$SOURCE_DIFF_SHA256"))
    }

    func testCanonicalCheckValidatesCorpusTestsAndDeterminism() throws {
        let check = try source("scripts/check.sh")

        XCTAssertTrue(check.contains("==> Mechanician Help corpus"))
        XCTAssertTrue(check.contains("scripts/test/help-corpus.test.mjs"))
        XCTAssertTrue(check.contains("scripts/test/help-expertise.test.mjs"))
        XCTAssertTrue(check.contains("build-help-corpus.mjs\" --check"))
    }

    func testPackagedTenantIsBuildIdentityRatherThanTheActiveManagedProfile() {
        XCTAssertEqual(
            MechanicianHelpBuildIdentity.packagedTenantID(
                bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
                provenanceTenantID: nil),
            TenantProfile.defaultTenantId)
        XCTAssertEqual(
            MechanicianHelpBuildIdentity.packagedTenantID(
                bundleIdentifier: MechanicianEnvironment.devBundleIdentifier,
                provenanceTenantID: nil),
            TenantProfile.defaultTenantId)
        XCTAssertEqual(
            MechanicianHelpBuildIdentity.packagedTenantID(
                bundleIdentifier: "ai.mechanician.app.acme",
                provenanceTenantID: nil),
            "acme")
        XCTAssertEqual(
            MechanicianHelpBuildIdentity.packagedTenantID(
                bundleIdentifier: MechanicianEnvironment.baseBundleIdentifier,
                provenanceTenantID: "packaged-tenant"),
            "packaged-tenant")
    }

    func testSharedStagingHelperSealsTheExactBuildAndSourceIdentity() throws {
        let repository = repositoryURL
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MechanicianHelpPackage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Mechanician.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/Resources", isDirectory: true),
            withIntermediateDirectories: true)
        let plist = repository.appendingPathComponent("app/Mechanician-Info.plist")
        let node = try command("/usr/bin/which", ["node"]).string

        _ = try command("/bin/bash", [
            repository.appendingPathComponent("scripts/stage-help-corpus.sh").path,
            app.path,
            plist.path,
            TenantProfile.defaultTenantId,
            node,
        ])

        let plistData = try Data(contentsOf: plist)
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil)
                as? [String: Any])
        let databaseURL = app.appendingPathComponent(
            "Contents/Resources/MechanicianHelp.sqlite")
        let store = try MechanicianHelpStore(databaseURL: databaseURL)
        XCTAssertEqual(
            store.metadata.applicationVersion,
            try XCTUnwrap(info["CFBundleShortVersionString"] as? String))
        XCTAssertEqual(
            store.metadata.applicationBuild,
            try XCTUnwrap(info["CFBundleVersion"] as? String))
        XCTAssertEqual(
            store.metadata.bundleIdentifier,
            try XCTUnwrap(info["CFBundleIdentifier"] as? String))
        XCTAssertEqual(store.metadata.tenantID, TenantProfile.defaultTenantId)
        XCTAssertEqual(
            store.metadata.sourceCommit,
            try command("/usr/bin/git", ["-C", repository.path, "rev-parse", "HEAD"]).string)
        let diff = try command(
            "/usr/bin/git", ["-C", repository.path, "diff", "--binary", "HEAD"]).data
        XCTAssertEqual(
            store.metadata.sourceDiffSHA256,
            SHA256.hash(data: diff).map { String(format: "%02x", $0) }.joined())
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-shm"))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryURL.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MechanicianTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // repository
    }

    private func command(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "MechanicianHelpPackagingTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        return CommandOutput(data: data)
    }
}

private struct CommandOutput {
    let data: Data

    var string: String {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
