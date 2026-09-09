import XCTest
@testable import Mechanician

/// A key the provider rejects must never reach the Keychain, and an unreachable provider must never
/// block a save. The distinction is the whole point of this type.
final class ProviderKeyValidationTests: XCTestCase {
    func testRejectionIsDistinctFromFailureToCheck() {
        XCTAssertEqual(ProviderKeyValidation.outcome(status: 200, provider: "OpenAI"), .valid)
        guard case .rejected = ProviderKeyValidation.outcome(status: 401, provider: "OpenAI") else {
            return XCTFail("401 must be a rejection")
        }
        guard case .rejected = ProviderKeyValidation.outcome(status: 403, provider: "OpenAI") else {
            return XCTFail("403 must be a rejection")
        }
        guard case .unverified = ProviderKeyValidation.outcome(status: 500, provider: "OpenAI") else {
            return XCTFail("a provider outage must not condemn the user's key")
        }
    }

    func testRateLimitingProvesTheKeyIsReal() {
        // 429 means the credential authenticated and the ACCOUNT is throttled or out of quota.
        // Treating it as a rejection would refuse a perfectly good key.
        XCTAssertEqual(ProviderKeyValidation.outcome(status: 429, provider: "OpenAI"), .valid)
    }

    func testTheRejectionMessagePointsAtTheLikelyCause() {
        guard case .rejected(let why) = ProviderKeyValidation.outcome(status: 401, provider: "OpenAI")
        else { return XCTFail("expected a rejection") }
        XCTAssertTrue(why.contains("OpenAI"))
        XCTAssertTrue(why.lowercased().contains("full"),
                      "a truncated paste is the most common cause and the message should say so")
    }

    func testEachSupportedLaneUsesItsOwnAuthScheme() throws {
        let openAI = try XCTUnwrap(ProviderKeyValidation.request(for: .openAIAPI, key: "sk-test"))
        XCTAssertEqual(openAI.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertNil(openAI.value(forHTTPHeaderField: "x-api-key"))

        let anthropic = try XCTUnwrap(ProviderKeyValidation.request(for: .anthropicAPI, key: "sk-ant"))
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(anthropic.value(forHTTPHeaderField: "Authorization"))
    }

    func testLanesWithoutAnAPIKeyAreNotChecked() {
        for access in [ModelAccess.claudeSubscription, .codexSubscription, .claudeVertex] {
            XCTAssertNil(ProviderKeyValidation.request(for: access, key: "x"),
                         "\(access) has no API key to verify")
        }
    }

    func testAValidationRequestCarriesTheWholeKey() throws {
        // The bug this whole feature came from: 164 characters stored as 128. Nothing in the
        // verification path may shorten the value it checks, or a truncated key would validate.
        let long = "sk-proj-" + String(repeating: "a", count: 156)
        XCTAssertEqual(long.count, 164)
        let request = try XCTUnwrap(ProviderKeyValidation.request(for: .openAIAPI, key: long))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + long)
    }
}
