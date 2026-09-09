import Foundation
import LocalAuthentication
import Security

// Minimal native credential broker for Mechanician's Node runtime. Secret bytes travel only over
// stdin/stdout; service/account identifiers are non-secret argv. Using Security.framework avoids
// `/usr/bin/security -w`'s 128-byte interactive-input truncation and keeps OAuth records out of
// process arguments, environment variables, configuration files, and logs.

private let maximumValueBytes = 1024 * 1024

private func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

private func validIdentifier(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum && !value.contains("\0")
}

guard CommandLine.arguments.count == 4 else {
    fail("usage: MechanicianKeychainHelper read|write|delete service account", status: 64)
}

let operation = CommandLine.arguments[1]
let service = CommandLine.arguments[2]
let account = CommandLine.arguments[3]
guard validIdentifier(service, maximum: 200), validIdentifier(account, maximum: 1000) else {
    fail("invalid Keychain identifier", status: 64)
}

let authenticationContext = LAContext()
authenticationContext.interactionNotAllowed = true
let baseQuery: [CFString: Any] = [
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: service,
    kSecAttrAccount: account,
    // Credential access is non-interactive. If the login Keychain is locked or access is denied,
    // return a visible failure to Mechanician instead of leaving an invisible modal prompt.
    kSecUseAuthenticationContext: authenticationContext,
]

switch operation {
case "read":
    var query = baseQuery
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { exit(44) }
    guard status == errSecSuccess, let value = result as? Data,
          value.count <= maximumValueBytes else {
        fail("Keychain read failed (\(status))")
    }
    FileHandle.standardOutput.write(value)

case "write":
    let value = FileHandle.standardInput.readDataToEndOfFile()
    guard !value.isEmpty, value.count <= maximumValueBytes else {
        fail("invalid Keychain value", status: 65)
    }
    // The authentication context is a query-only control and is not a persisted attribute.
    var addQuery = baseQuery
    addQuery[kSecUseAuthenticationContext] = nil
    addQuery[kSecValueData] = value
    addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    var status = SecItemAdd(addQuery as CFDictionary, nil)
    if status == errSecDuplicateItem {
        let updates: [CFString: Any] = [kSecValueData: value]
        status = SecItemUpdate(baseQuery as CFDictionary, updates as CFDictionary)
    }
    guard status == errSecSuccess else { fail("Keychain write failed (\(status))") }

case "delete":
    let status = SecItemDelete(baseQuery as CFDictionary)
    if status == errSecItemNotFound { exit(44) }
    guard status == errSecSuccess else { fail("Keychain delete failed (\(status))") }

default:
    fail("unknown Keychain operation", status: 64)
}
