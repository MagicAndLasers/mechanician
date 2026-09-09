import CryptoKit
import Darwin
import Foundation

/// Secrets embedded in MCP launch environments and HTTP headers are credentials, not ordinary
/// preferences. `extensions.json` therefore contains only opaque references; the values themselves
/// live in the user's login Keychain. The account name is bound to the server's executable endpoint
/// so copying a reference onto a different command or URL does not resolve.
enum MCPSecretReference {
    static var service: String { MechanicianEnvironment.currentCredentialServices.mcpSecret }
    static var prefix: String { "keychain://\(service)/v1/" }

    static func make(server: MCPServer, kind: String, key: String, nonce: UUID = UUID()) -> String {
        let account = accountPrefix(server: server, kind: kind, key: key)
            + nonce.uuidString.lowercased()
        return prefix + Data(account.utf8).base64URLEncodedString
    }

    static func account(from reference: String) -> String? {
        guard reference.hasPrefix(prefix) else { return nil }
        let encoded = String(reference.dropFirst(prefix.count))
        guard let data = Data(base64URLString: encoded),
              let account = String(data: data, encoding: .utf8),
              !account.isEmpty else { return nil }
        return account
    }

    static func isValid(_ reference: String, server: MCPServer, kind: String, key: String) -> Bool {
        guard let account = account(from: reference) else { return false }
        let expected = accountPrefix(server: server, kind: kind, key: key)
        guard account.hasPrefix(expected) else { return false }
        let nonce = String(account.dropFirst(expected.count))
        return UUID(uuidString: nonce) != nil
    }

    static func accountPrefix(server: MCPServer, kind: String, key: String) -> String {
        let keyToken = Data(key.utf8).base64URLEncodedString
        return "mcp-secret-v1|\(server.id.uuidString.lowercased())|\(bindingDigest(server))|\(kind)|\(keyToken)|"
    }

    static func bindingDigest(_ server: MCPServer) -> String {
        let fields: [String]
        switch server.transport {
        case .stdio:
            fields = [server.transport.rawValue, server.command] + server.args
        case .http, .sse:
            fields = [server.transport.rawValue, server.url]
        }
        let framed = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLString: String) {
        var value = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }
}

protocol MCPSecretVault {
    func store(_ value: String, account: String) throws
    func read(account: String) throws -> String
    func remove(account: String) throws
}

enum MCPSecretVaultError: LocalizedError {
    case commandFailed(String)
    case missing(String)
    case invalidReference

    var errorDescription: String? {
        switch self {
        case .commandFailed(let detail): return "Keychain operation failed: \(detail)"
        case .missing: return "An MCP credential is missing from Keychain. Re-enter it in Connections."
        case .invalidReference:
            return "An MCP credential reference is invalid. Re-enter that credential in Connections."
        }
    }
}

/// `/usr/bin/security` is also how the Node sidecar reads these items. Creating the item through the
/// same system tool avoids granting a bundled executable access to a raw secret on argv and keeps the
/// Keychain access behavior consistent across the Swift and Node processes.
struct SystemMCPSecretVault: MCPSecretVault {
    func store(_ value: String, account: String) throws {
        let result = run([
            "add-generic-password", "-U", "-a", account,
            "-s", MCPSecretReference.service, "-w",
        ], input: value + "\n" + value + "\n")
        guard result.status == 0 else { throw MCPSecretVaultError.commandFailed(result.output) }
    }

    func read(account: String) throws -> String {
        let result = run([
            "find-generic-password", "-a", account,
            "-s", MCPSecretReference.service, "-w",
        ])
        guard result.status == 0 else { throw MCPSecretVaultError.missing(account) }
        return result.output.trimmingCharacters(in: .newlines)
    }

    func remove(account: String) throws {
        let result = run([
            "delete-generic-password", "-a", account,
            "-s", MCPSecretReference.service,
        ])
        if result.status != 0,
           !result.output.localizedCaseInsensitiveContains("could not be found") {
            throw MCPSecretVaultError.commandFailed(result.output)
        }
    }

    private func run(_ arguments: [String], input: String? = nil) -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        let inputPipe = input == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        process.standardInput = inputPipe
        do { try process.run() }
        catch { return (-1, error.localizedDescription) }
        if let input, let inputPipe {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

struct MCPSecretProtection {
    var servers: [MCPServer]
    var accounts: Set<String>
}

struct MCPSecretHydration {
    var servers: [MCPServer]
    var needsMigration: Bool
    var warnings: [String]
}

enum MCPSecretPersistence {
    static func protect(
        _ servers: [MCPServer],
        vault: any MCPSecretVault,
        nonce: () -> UUID = UUID.init
    ) throws -> MCPSecretProtection {
        var protectedServers: [MCPServer] = []
        var createdAccounts = Set<String>()
        var referencedAccounts = Set<String>()
        do {
            for var server in servers {
                server.env = try protectMap(
                    server.env, server: server, kind: "env", vault: vault,
                    nonce: nonce, created: &createdAccounts, referenced: &referencedAccounts)
                server.headers = try protectMap(
                    server.headers, server: server, kind: "header", vault: vault,
                    nonce: nonce, created: &createdAccounts, referenced: &referencedAccounts)
                protectedServers.append(server)
            }
            return MCPSecretProtection(servers: protectedServers, accounts: referencedAccounts)
        } catch {
            // New accounts are deliberately versioned. If one write fails, deleting this attempt
            // leaves the old extensions.json and every account it references untouched.
            for account in createdAccounts { try? vault.remove(account: account) }
            throw error
        }
    }

    static func hydrate(_ servers: [MCPServer], vault: any MCPSecretVault) -> MCPSecretHydration {
        var hydrated: [MCPServer] = []
        var migration = false
        var warnings: [String] = []
        for var server in servers {
            server.env = hydrateMap(
                server.env, server: server, kind: "env", vault: vault,
                needsMigration: &migration, warnings: &warnings)
            server.headers = hydrateMap(
                server.headers, server: server, kind: "header", vault: vault,
                needsMigration: &migration, warnings: &warnings)
            hydrated.append(server)
        }
        return MCPSecretHydration(servers: hydrated, needsMigration: migration, warnings: warnings)
    }

    static func referencedAccounts(in servers: [MCPServer]) -> Set<String> {
        var accounts = Set<String>()
        for server in servers {
            for value in Array(server.env.values) + Array(server.headers.values) {
                if let account = MCPSecretReference.account(from: value) { accounts.insert(account) }
            }
        }
        return accounts
    }

    @discardableResult
    static func remove(_ accounts: Set<String>, vault: any MCPSecretVault) -> Set<String> {
        var failed = Set<String>()
        for account in accounts {
            do { try vault.remove(account: account) }
            catch { failed.insert(account) }
        }
        return failed
    }

    private static func protectMap(
        _ values: [String: String],
        server: MCPServer,
        kind: String,
        vault: any MCPSecretVault,
        nonce: () -> UUID,
        created: inout Set<String>,
        referenced: inout Set<String>
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in values {
            guard !value.isEmpty else { result[key] = value; continue }
            if value.hasPrefix(MCPSecretReference.prefix) {
                guard MCPSecretReference.isValid(value, server: server, kind: kind, key: key),
                      let account = MCPSecretReference.account(from: value) else {
                    // Hydration deliberately preserves a malformed reference so an unrelated edit
                    // cannot erase the only forensic/recovery value. It is never plaintext: fail
                    // the save instead of storing the reference text as a fresh Keychain secret.
                    throw MCPSecretVaultError.invalidReference
                }
                result[key] = value
                referenced.insert(account)
                continue
            }
            let reference = MCPSecretReference.make(
                server: server, kind: kind, key: key, nonce: nonce())
            guard let account = MCPSecretReference.account(from: reference) else {
                throw MCPSecretVaultError.commandFailed("could not construct a credential reference")
            }
            try vault.store(value, account: account)
            created.insert(account)
            referenced.insert(account)
            result[key] = reference
        }
        return result
    }

    private static func hydrateMap(
        _ values: [String: String],
        server: MCPServer,
        kind: String,
        vault: any MCPSecretVault,
        needsMigration: inout Bool,
        warnings: inout [String]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in values {
            guard value.hasPrefix(MCPSecretReference.prefix) else {
                result[key] = value
                if !value.isEmpty { needsMigration = true }
                continue
            }
            guard MCPSecretReference.isValid(value, server: server, kind: kind, key: key),
                  let account = MCPSecretReference.account(from: value) else {
                // Preserve an invalid reference verbatim: never turn it into plaintext or silently
                // overwrite it during an unrelated edit. agentd will reject it as well.
                result[key] = value
                warnings.append("Credential reference for MCP server \(server.name) is invalid.")
                continue
            }
            do { result[key] = try vault.read(account: account) }
            catch {
                result[key] = value
                warnings.append("Credential for MCP server \(server.name) is unavailable.")
            }
        }
        return result
    }
}

enum PrivateAtomicFile {
    static func write(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            let result = temporary.withUnsafeFileSystemRepresentation { source in
                destination.withUnsafeFileSystemRepresentation { target in
                    Darwin.rename(source, target)
                }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // The rename is the commit point. Everything after it is best-effort: surfacing a
            // post-commit housekeeping error to the caller would make it delete the new Keychain
            // items while the published file already references them.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: destination.path)
            // fsync the directory as well as the file: otherwise a power loss can preserve the
            // Keychain rotation while losing the rename that publishes its matching references.
            let directoryDescriptor = Darwin.open(
                destination.deletingLastPathComponent().path,
                O_RDONLY | O_DIRECTORY)
            if directoryDescriptor >= 0 {
                defer { Darwin.close(directoryDescriptor) }
                _ = Darwin.fsync(directoryDescriptor)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func enforcePrivatePermissions(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
