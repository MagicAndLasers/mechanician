#!/usr/bin/env swift

import CryptoKit
import Foundation

private let profileSigningPublicKeyBase64 = "iiOb4sGQkFqJbPGwQ/vq/YuA8cFfe/8c6UU26PnyHSw="

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("!! \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: verify-enterprise-profile.swift PROFILE.mechanician-profile")
}

do {
    let url = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    let raw = try JSONSerialization.jsonObject(with: data)
    guard let envelope = raw as? [String: Any],
          Set(envelope.keys) == Set(["documentVersion", "profile", "signature"]),
          let documentVersion = envelope["documentVersion"] as? Int,
          documentVersion == 1,
          let profile = envelope["profile"] as? [String: Any],
          let tenantID = profile["tenantId"] as? String,
          !tenantID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let signatureText = envelope["signature"] as? String,
          let signature = Data(base64Encoded: signatureText),
          signature.count == 64
    else {
        fail("enterprise profile envelope is malformed")
    }

    let payload: [String: Any] = [
        "documentVersion": documentVersion,
        "profile": profile,
    ]
    let canonical = try JSONSerialization.data(
        withJSONObject: payload,
        options: [.sortedKeys, .withoutEscapingSlashes])
    guard let publicKeyData = Data(base64Encoded: profileSigningPublicKeyBase64) else {
        fail("embedded enterprise profile public key is invalid")
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    guard publicKey.isValidSignature(signature, for: canonical) else {
        fail("enterprise profile signature is invalid")
    }

    print("==> verified signed enterprise profile: \(url.path)")
} catch {
    fail(error.localizedDescription)
}
