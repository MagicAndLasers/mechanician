import XCTest
import Security
@testable import Mechanician

/// The regression that started this: `security add-generic-password … -w` reading the value from
/// stdin SILENTLY TRUNCATES AT 128 CHARACTERS — measured, 212 written read back as 128, exit code
/// zero and no error. Anthropic keys are shorter than the limit so nothing showed; an OpenAI
/// project key (164 characters) was stored as a valid-looking 128-character prefix, which the
/// provider then rejected as an incorrect key. The blame landed on the user's key for a while.
///
/// This exercises the real Keychain through the same API the app now uses, so a regression to any
/// length-capped write is caught here.
final class KeychainRoundTripTests: XCTestCase {
    private let service = "MECHANICIAN_TEST_KEYCHAIN_ROUNDTRIP"

    private func write(_ value: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "mechanician",
            kSecAttrService as String: service,
        ]
        let data = Data(value.utf8)
        let update = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update != errSecItemNotFound { return update }
        var insert = query
        insert[kSecValueData as String] = data
        return SecItemAdd(insert as CFDictionary, nil)
    }

    private func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "mechanician",
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    override func tearDown() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "mechanician",
            kSecAttrService as String: service,
        ] as CFDictionary)
        super.tearDown()
    }

    func testAKeyLongerThan128CharactersSurvivesTheRoundTrip() throws {
        // 164 is the real length of the OpenAI project key that exposed this.
        let key = "sk-proj-" + String(repeating: "k", count: 152) + "2NOUA"
        XCTAssertEqual(key.count, 165)
        let status = write(key)
        try XCTSkipIf(status != errSecSuccess,
                      "Keychain unavailable in this environment (status \(status))")
        XCTAssertEqual(read(), key, "the stored value must not be truncated at any length")
        XCTAssertEqual(read()?.count, key.count)
    }

    func testOverwritingReplacesRatherThanAppends() throws {
        let first = String(repeating: "a", count: 200)
        try XCTSkipIf(write(first) != errSecSuccess, "Keychain unavailable")
        let second = String(repeating: "b", count: 170)
        XCTAssertEqual(write(second), errSecSuccess)
        XCTAssertEqual(read(), second)
    }
}
