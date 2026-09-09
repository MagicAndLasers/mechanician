#!/usr/bin/env swift

import CryptoKit
import Foundation

private let profileSigningPublicKeyBase64 = "iiOb4sGQkFqJbPGwQ/vq/YuA8cFfe/8c6UU26PnyHSw="
private let defaultAccount = "mechanician-enterprise-profiles"

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("!! \(message)\n".utf8))
    exit(1)
}

private func run(_ executable: URL, _ arguments: [String]) throws -> String {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let error = stderr.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        let detail = String(data: error, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw NSError(
            domain: "MechanicianProfileSigner",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: detail?.isEmpty == false ? detail! : "signing command failed"])
    }
    return String(decoding: output, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

guard CommandLine.arguments.count == 3 || CommandLine.arguments.count == 4 else {
    fail("usage: sign-enterprise-profile.swift INPUT.json OUTPUT.mechanician-profile [keychain-account]")
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let repository = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let inputURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
let account = CommandLine.arguments.count == 4 ? CommandLine.arguments[3] : defaultAccount
let sparkleTools = repository
    .appendingPathComponent("app/.build/artifacts/sparkle/Sparkle/bin", isDirectory: true)
let generateKeys = sparkleTools.appendingPathComponent("generate_keys")
let signUpdate = sparkleTools.appendingPathComponent("sign_update")

guard FileManager.default.isExecutableFile(atPath: generateKeys.path),
      FileManager.default.isExecutableFile(atPath: signUpdate.path)
else {
    fail("Sparkle signing tools are missing; resolve the app package dependencies first")
}

do {
    let expectedPublicKey = try Data(base64Encoded: profileSigningPublicKeyBase64)
        .unwrap(or: "embedded profile public key is invalid")
    let keychainPublicKey = try run(generateKeys, ["--account", account, "-p"])
    guard keychainPublicKey == profileSigningPublicKeyBase64 else {
        fail("Keychain account \(account) does not match Mechanician's embedded profile trust key")
    }

    let rawProfile = try Data(contentsOf: inputURL, options: [.mappedIfSafe])
    guard let profileObject = try JSONSerialization.jsonObject(with: rawProfile) as? [String: Any],
          JSONSerialization.isValidJSONObject(profileObject)
    else {
        fail("input must be a JSON object")
    }

    let payloadObject: [String: Any] = [
        "documentVersion": 1,
        "profile": profileObject,
    ]
    let payload = try JSONSerialization.data(
        withJSONObject: payloadObject,
        options: [.sortedKeys, .withoutEscapingSlashes])

    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mechanician-profile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: temporaryDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let payloadURL = temporaryDirectory.appendingPathComponent("payload.json")
    try payload.write(to: payloadURL, options: [.atomic])

    let signatureBase64 = try run(signUpdate, ["--account", account, "-p", payloadURL.path])
    guard let signature = Data(base64Encoded: signatureBase64), signature.count == 64 else {
        fail("Sparkle returned an invalid Ed25519 signature")
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: expectedPublicKey)
    guard publicKey.isValidSignature(signature, for: payload) else {
        fail("generated signature does not verify against Mechanician's embedded trust key")
    }

    let envelope: [String: Any] = [
        "documentVersion": 1,
        "profile": profileObject,
        "signature": signatureBase64,
    ]
    var output = try JSONSerialization.data(
        withJSONObject: envelope,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    output.append(0x0A)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try output.write(to: outputURL, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outputURL.path)
    print("==> signed enterprise profile: \(outputURL.path)")
} catch {
    fail(error.localizedDescription)
}

private extension Optional {
    func unwrap(or message: String) throws -> Wrapped {
        guard let value = self else {
            throw NSError(
                domain: "MechanicianProfileSigner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
        return value
    }
}
