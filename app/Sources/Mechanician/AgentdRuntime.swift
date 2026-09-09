import Foundation
import Darwin

/// Read coordination is deliberately launch-scoped. A stopped process may leave callbacks queued,
/// but those callbacks can neither read from nor delay a later launch on the same runtime object.
private final class AgentdReaderState: @unchecked Sendable {
    var closed = false
    let framer = AgentdNDJSONFramer(maximumFrameBytes: 32 * 1024 * 1024)
}

/// JSON dictionaries are dynamically typed and therefore not `Sendable`, but each decoded value
/// is immutable after construction and crosses exactly once from the serial reader queue to main.
final class AgentdDecodedEvent: @unchecked Sendable {
    let value: [String: Any]

    init(_ value: [String: Any]) {
        self.value = value
    }
}

enum AgentdFrameConsumeResult {
    case consumed
    case detached
    case frameTooLarge
}

/// The single app-to-daemon NDJSON encoder.
///
/// Foundation emits U+2028 and U+2029 as literal UTF-8 inside otherwise valid JSON strings. Node's
/// line reader treats those JavaScript line separators as record boundaries before `JSON.parse`
/// runs, so valid JSON becomes two invalid protocol frames. Escape both after JSON serialization,
/// then append the one and only literal line-feed that terminates the record.
enum AgentdNDJSONRecordEncoder {
    private static let utf8LineSeparator = Data([0xE2, 0x80, 0xA8])
    private static let utf8ParagraphSeparator = Data([0xE2, 0x80, 0xA9])
    private static let escapedLineSeparator: [UInt8] = [0x5C, 0x75, 0x32, 0x30, 0x32, 0x38]
    private static let escapedParagraphSeparator: [UInt8] = [0x5C, 0x75, 0x32, 0x30, 0x32, 0x39]

    static func encode(_ request: [String: Any]) throws -> Data {
        let serialized = try JSONSerialization.data(withJSONObject: request)
        var record = escapingJavaScriptLineSeparators(in: serialized)
        record.append(0x0A)
        return record
    }

    private static func escapingJavaScriptLineSeparators(in serialized: Data) -> Data {
        guard serialized.range(of: utf8LineSeparator) != nil
                || serialized.range(of: utf8ParagraphSeparator) != nil else {
            return serialized
        }
        let bytes = [UInt8](serialized)
        var escaped = Data()
        escaped.reserveCapacity(serialized.count + 6)
        var index = 0
        while index < bytes.count {
            if index + 2 < bytes.count,
               bytes[index] == 0xE2,
               bytes[index + 1] == 0x80,
               bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9 {
                escaped.append(contentsOf: bytes[index + 2] == 0xA8
                    ? escapedLineSeparator
                    : escapedParagraphSeparator)
                index += 3
            } else {
                escaped.append(bytes[index])
                index += 1
            }
        }
        return escaped
    }
}

/// Stable, provider-neutral process termination evidence. Keeping this separate from `Process`
/// lets the bridge persist useful diagnostics after the runtime generation has been released.
struct AgentdUnexpectedExit: Equatable, Sendable {
    enum Reason: String, Equatable, Sendable {
        case exit
        case uncaughtSignal = "uncaught_signal"
        case unknown
    }

    let status: Int32
    let reason: Reason

    init(status: Int32, reason: Reason) {
        self.status = status
        self.reason = reason
    }

    init(_ process: Process) {
        status = process.terminationStatus
        switch process.terminationReason {
        case .exit: reason = .exit
        case .uncaughtSignal: reason = .uncaughtSignal
        @unknown default: reason = .unknown
        }
    }

    var diagnosticCode: String {
        switch reason {
        case .exit: return "agentd_exit_\(status)"
        case .uncaughtSignal: return "agentd_signal_\(status)"
        case .unknown: return "agentd_termination_\(status)"
        }
    }

    var terminalReason: String {
        switch reason {
        case .exit: return "Runtime exited with code \(status)"
        case .uncaughtSignal: return "Runtime was terminated by signal \(status)"
        case .unknown: return "Runtime terminated with status \(status)"
        }
    }
}

/// Bounded NDJSON framing and JSON decoding. Agentd may legitimately emit large tool results, but a
/// missing newline must never grow app memory without limit. This object is confined to one serial
/// queue in production; tests can exercise it directly without launching a provider process.
final class AgentdNDJSONFramer: @unchecked Sendable {
    private let maximumFrameBytes: Int
    private var lineBuffer = Data()

    init(maximumFrameBytes: Int) {
        self.maximumFrameBytes = maximumFrameBytes
    }

    func consume(
        _ data: Data,
        deliver: (AgentdDecodedEvent) -> Bool
    ) -> AgentdFrameConsumeResult {
        var segmentStart = data.startIndex
        while let newline = data[segmentStart...].firstIndex(of: 0x0A) {
            let segment = data[segmentStart..<newline]
            guard lineBuffer.count <= maximumFrameBytes - segment.count else {
                lineBuffer.removeAll(keepingCapacity: false)
                return .frameTooLarge
            }
            lineBuffer.append(contentsOf: segment)
            if let value = try? JSONSerialization.jsonObject(with: lineBuffer) as? [String: Any],
               !deliver(AgentdDecodedEvent(value)) {
                lineBuffer.removeAll(keepingCapacity: false)
                return .detached
            }
            if lineBuffer.count > 1 * 1024 * 1024 {
                lineBuffer = Data()
            } else {
                lineBuffer.removeAll(keepingCapacity: true)
            }
            segmentStart = data.index(after: newline)
        }

        if segmentStart < data.endIndex {
            let segment = data[segmentStart..<data.endIndex]
            guard lineBuffer.count <= maximumFrameBytes - segment.count else {
                lineBuffer.removeAll(keepingCapacity: false)
                return .frameTooLarge
            }
            lineBuffer.append(contentsOf: segment)
        }
        return .consumed
    }
}

/// One provider-fixed agentd process.
///
/// `AgentdRuntime` owns only transport lifecycle and NDJSON framing. Conversation/turn routing and
/// provider-specific UI state remain the responsibility of `AgentBridge`; attaching `access` to
/// every callback gives that future pool owner an authoritative runtime lane for each event.
@MainActor
final class AgentdRuntime {
    typealias EventHandler = (ModelAccess, [String: Any]) -> Void
    typealias UnexpectedExitHandler = (ModelAccess, AgentdUnexpectedExit) -> Void
    typealias ProcessStarter = @Sendable (Process) -> String?
    typealias RecordWriter = @Sendable (FileHandle, Data) throws -> Void

    let access: ModelAccess

    private let onEvent: EventHandler
    private let onLaunchFailure: (ModelAccess, String) -> Void
    private let onUnexpectedExit: UnexpectedExitHandler
    private let processStarter: ProcessStarter
    private let recordWriter: RecordWriter
    private let processEnvironment: () -> [String: String]
    private let loginShellPath: @MainActor () -> String?
    private let managedPolicy: ManagedEnterprisePolicy?
    private let tenantProfile: () -> TenantProfile

    /// `Process.run()` can synchronously wait while macOS performs first-execution validation of
    /// the bundled Node binary. The 0.9.3 bundle made that executable large enough for a cold launch
    /// to take about a minute. Launching on this queue keeps AppKit responsive while preserving all
    /// transport ownership and event delivery on the main actor.
    private static let launchQueue = DispatchQueue(
        label: "ai.mechanician.agentd-runtime.launch",
        qos: .userInitiated,
        attributes: .concurrent)
    nonisolated private static let defaultProcessStarter: ProcessStarter = { process in
        do {
            try process.run()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
    /// A prompt includes history and workspace instructions, so even a short user message can be
    /// larger than a pipe's available buffer. FileHandle.write is blocking; keeping it on the main
    /// actor made AppKit stop servicing window and divider drags whenever agentd was briefly busy
    /// initializing a provider or its MCP connections. One serial queue per runtime preserves exact
    /// request order without coupling UI responsiveness to the child process's stdin consumption.
    private let writerQueue = DispatchQueue(
        label: "ai.mechanician.agentd-runtime.writer",
        qos: .userInitiated)
    nonisolated private static let defaultRecordWriter: RecordWriter = { handle, data in
        try handle.write(contentsOf: data)
    }

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderrLog: FileHandle?
    /// A Stop escalation is stronger than ordinary window/reload shutdown. Keep ownership of the
    /// exact `Process` until its termination callback has drained final output, then release every
    /// waiter together. AgentBridge uses that callback as the old-generation death certificate;
    /// merely sending TERM is never permission to launch the replacement lane.
    private var retirementCompletions: [() -> Void] = []
    private var isRetiringImmediately = false
    private var launchIsPending = false
    private var retirementKillWork: DispatchWorkItem?
    var isRunning: Bool { process?.isRunning == true }

    init(
        access: ModelAccess,
        onEvent: @escaping EventHandler,
        onLaunchFailure: @escaping (ModelAccess, String) -> Void,
        onUnexpectedExit: @escaping UnexpectedExitHandler,
        processStarter: @escaping ProcessStarter = AgentdRuntime.defaultProcessStarter,
        recordWriter: @escaping RecordWriter = AgentdRuntime.defaultRecordWriter,
        processEnvironment: @escaping () -> [String: String] = {
            ProcessInfo.processInfo.environment
        },
        loginShellPath: @escaping @MainActor () -> String? = {
            AgentdRuntime.cachedLoginShellPath()
        },
        managedPolicy: ManagedEnterprisePolicy? = ManagedEnterprisePolicy.current,
        tenantProfile: @escaping () -> TenantProfile = { TenantProfile.current }
    ) {
        self.access = access
        self.onEvent = onEvent
        self.onLaunchFailure = onLaunchFailure
        self.onUnexpectedExit = onUnexpectedExit
        self.processStarter = processStarter
        self.recordWriter = recordWriter
        self.processEnvironment = processEnvironment
        self.loginShellPath = loginShellPath
        self.managedPolicy = managedPolicy
        self.tenantProfile = tenantProfile
    }

    /// Launch this lane's provider-fixed agentd without blocking AppKit. Calling `start` while a
    /// launch is pending or its process is running is a no-op. Failures return asynchronously to
    /// the pool owner so the runtime can remain identity-safe if its window closes mid-launch.
    func start() {
        guard process == nil else { return }
        if let reason = managedPolicy?.turnBlockReason(for: access) {
            onLaunchFailure(access, reason)
            return
        }
        let profile = tenantProfile()

        let proc = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()
        let inHandle = inPipe.fileHandleForWriting
        let outHandle = outPipe.fileHandleForReading

        let node = Self.resolveNodePath()
        let agentdPath = Self.resolveAgentdPath()
        proc.executableURL = URL(fileURLWithPath: node)
        // `/usr/bin/env` needs `node` as its first argument; an absolute node does not.
        proc.arguments = node.hasSuffix("/env") ? ["node", agentdPath] : [agentdPath]
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        let errorLog = Self.openStderrLog(for: access)
        if let errorLog { proc.standardError = errorLog }

        var environment = Self.withUserIdentity(processEnvironment())
        environment["PATH"] = Self.agentPath(
            login: loginShellPath(),
            inherited: environment["PATH"],
            runtime: Bundle.main.resourceURL?.appendingPathComponent("runtime").path)
        // A provider lane receives only its own externally managed credential. The app process may
        // inherit several keys from a developer shell; forwarding all of them to every daemon makes
        // an unrelated provider secret visible to the wrong runtime and its child processes.
        let inheritedAnthropicKey = environment["ANTHROPIC_API_KEY"]
        let inheritedOpenAIKey = environment["OPENAI_API_KEY"]
        let inheritedClaudeToken = environment["CLAUDE_CODE_OAUTH_TOKEN"]
        environment["ANTHROPIC_API_KEY"] = nil
        environment["ANTHROPIC_AUTH_TOKEN"] = nil
        environment["OPENAI_API_KEY"] = nil
        environment["CLAUDE_CODE_OAUTH_TOKEN"] = nil
        environment["MECHANICIAN_ACCOUNT_DISABLED"] = nil
        // Never trust similarly named variables inherited from a shell. Only the forced managed
        // preference snapshot may constrain this daemon generation.
        environment["MECHANICIAN_MANAGED_POLICY"] = nil
        environment["MECHANICIAN_MAX_PERMISSION_MODE"] = nil
        environment["MECHANICIAN_ALLOWED_PROVIDER_ACCESSES"] = nil
        environment["MECHANICIAN_ALLOW_USER_EXTENSIONS"] = nil
        environment["MECHANICIAN_MANAGED_EXTENSION_SERVERS"] = nil
        environment["MECHANICIAN_ALLOW_UNATTENDED_TASKS"] = nil
        if let policy = managedPolicy {
            environment["MECHANICIAN_MANAGED_POLICY"] = "1"
            if let maximum = policy.maximumInteractivePermissionMode {
                environment["MECHANICIAN_MAX_PERMISSION_MODE"] = maximum
            }
            if let allowed = policy.allowedProviderAccesses {
                environment["MECHANICIAN_ALLOWED_PROVIDER_ACCESSES"] = allowed.sorted()
                    .joined(separator: ",")
            }
            environment["MECHANICIAN_ALLOW_USER_EXTENSIONS"] =
                policy.allowUserConfiguredExtensions ? "1" : "0"
            if !policy.allowUserConfiguredExtensions,
               let data = try? JSONEncoder().encode(
                   profile.extensions.managedServers),
               data.count <= ManagedEnterprisePolicy.maximumManagedExtensionServerBytes {
                environment["MECHANICIAN_MANAGED_EXTENSION_SERVERS"] =
                    String(decoding: data, as: UTF8.self)
            }
            environment["MECHANICIAN_ALLOW_UNATTENDED_TASKS"] =
                policy.allowUnattendedTasks ? "1" : "0"
        }
        switch access {
        case .claudeSubscription:
            if let inheritedClaudeToken { environment["CLAUDE_CODE_OAUTH_TOKEN"] = inheritedClaudeToken }
        case .anthropicAPI:
            if let inheritedAnthropicKey {
                environment["ANTHROPIC_API_KEY"] = inheritedAnthropicKey
            }
        case .openAIAPI:
            if let inheritedOpenAIKey {
                environment["OPENAI_API_KEY"] = inheritedOpenAIKey
            }
        case .codexSubscription, .claudeVertex, .claudeBedrock:
            // Codex owns its own credential store; Vertex uses Google ADC (a file the child reads
            // directly); Bedrock uses the ordinary AWS chain the child resolves for itself. None
            // receives an injected Anthropic/OpenAI secret. The Vertex and Bedrock endpoint
            // selectors are added below from the configuration for their route.
            break
        }
        let route = Self.route(for: access)
        environment["MECHANICIAN_PROVIDER"] = route.provider
        environment["MECHANICIAN_AUTH"] = route.authMode
        // Bind MCP authorization/readiness evidence to the exact provider-account instance that
        // owns this daemon. This UUID is app-generated and non-secret; the daemon compares it with
        // every readiness claim before it asks a provider to create or resume a turn. A process
        // launched for an older account therefore cannot acknowledge tools for its replacement.
        environment["MECHANICIAN_ACCOUNT_INSTANCE_ID"] = ProviderAccountStore.shared
            .accountInstanceID(for: access).rawValue.uuidString.lowercased()
        if access == .codexSubscription,
           let codex = CodexRuntime.resolveBinary(environment: environment) {
            environment["MECHANICIAN_CODEX_BIN"] = codex.path
        }
        // Claude-on-Vertex (FR-103): hand the daemon the tenant profile's Vertex project + region so it
        // can activate CLAUDE_CODE_USE_VERTEX for this route. The daemon obtains Google ADC itself.
        for (name, value) in Self.tenantRouteEnvironment(
            for: access,
            profile: profile,
            supportDirectory: Self.supportDirectory(
                environment: environment,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        ) {
            environment[name] = value
        }
        // Credential service names are derived from the signed bundle identity, not inherited from
        // a launching shell. Node and Swift must address the same tenant-scoped Keychain entries.
        for (name, value) in MechanicianEnvironment.currentCredentialServices.processEnvironment {
            environment[name] = value
        }
        // 1M context remains on by default. Preserve the existing advanced-setting opt-out and any
        // explicit launch-environment override inherited by the app.
        let use1M = (UserDefaults.standard.object(forKey: "use1MContext") as? Bool) ?? true
        if !use1M { environment["MECHANICIAN_NO_1M"] = "1" }
        // Claude preview surfaces (Opus 5 advisor, Fast mode, configurable safety fallback) are
        // opt-in and billable. Clear any inherited value FIRST so a developer shell or a parent
        // Mechanician process can never enable them; a release build then adds nothing back, because
        // `ClaudeExperiments` resolves to empty at compile time outside DEBUG.
        environment[ClaudeExperiments.environmentKey] = nil
        if let experiments = ClaudeExperiments.current.daemonEnvironmentValue {
            environment[ClaudeExperiments.environmentKey] = experiments
        }
        proc.environment = environment

        let readerState = AgentdReaderState()
        let launchID = UUID().uuidString
        let terminationQueue = DispatchQueue(
            label: "ai.mechanician.agentd-runtime.termination.\(launchID)"
        )
        let readerQueue = DispatchQueue(
            label: "ai.mechanician.agentd-runtime.reader.\(launchID)"
        )

        // Framing and JSON decoding stay off the main actor. Synchronous one-event delivery applies
        // backpressure to the reader queue, so a provider cannot enqueue an unbounded number of
        // decoded dictionaries while preserving exact wire order.
        let deliverSynchronously: (AgentdDecodedEvent) -> Bool = { [weak self, weak proc] decoded in
            guard let proc else { return false }
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    guard let self, self.process === proc else { return false }
                    self.onEvent(self.access, decoded.value)
                    return self.process === proc
                }
            }
        }

        outHandle.readabilityHandler = { handle in
            readerQueue.sync {
                guard !readerState.closed else { return }
                let data = handle.availableData
                guard !data.isEmpty else {
                    readerState.closed = true
                    handle.readabilityHandler = nil
                    return
                }
                switch readerState.framer.consume(data, deliver: deliverSynchronously) {
                case .consumed:
                    break
                case .detached:
                    readerState.closed = true
                    handle.readabilityHandler = nil
                case .frameTooLarge:
                    readerState.closed = true
                    handle.readabilityHandler = nil
                    let message = "[Mechanician] agentd emitted an NDJSON frame larger than 32 MiB; terminating it.\n"
                    try? errorLog?.write(contentsOf: Data(message.utf8))
                    proc.terminate()
                }
            }
        }

        // Ordinary `stop` clears `process` before terminating it. A Stop escalation deliberately
        // retains identity and sets `isRetiringImmediately`, because its caller needs positive exit
        // evidence before a replacement generation can become usable.
        proc.terminationHandler = { [weak self] terminated in
            terminationQueue.async {
                // Exclusion with the normal callback preserves byte order. Once the parent has
                // terminated, every final byte it wrote is already buffered in the pipe. A
                // nonblocking POSIX drain consumes exactly those bytes without waiting for a
                // descendant that inherited the write end.
                var finalData = Data()
                readerQueue.sync {
                    readerState.closed = true
                    outHandle.readabilityHandler = nil

                    let descriptor = outHandle.fileDescriptor
                    let currentFlags = fcntl(descriptor, F_GETFL)
                    if currentFlags >= 0 {
                        _ = fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK)
                    }

                    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                    while true {
                        let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                            guard let baseAddress = bytes.baseAddress else { return 0 }
                            return Darwin.read(descriptor, baseAddress, bytes.count)
                        }
                        if count > 0 {
                            finalData.append(contentsOf: buffer.prefix(count))
                        } else if count == 0 {
                            break
                        } else if errno == EINTR {
                            continue
                        } else if errno == EAGAIN || errno == EWOULDBLOCK {
                            break
                        } else {
                            break
                        }
                    }
                    if !finalData.isEmpty {
                        _ = readerState.framer.consume(finalData, deliver: deliverSynchronously)
                    }
                }
                try? outHandle.close()
                try? inHandle.close()
                try? errorLog?.close()
                let exit = AgentdUnexpectedExit(terminated)
                DispatchQueue.main.async { [weak self] in
                    guard let self, let current = self.process, current === terminated else { return }
                    let retiredIntentionally = self.isRetiringImmediately
                    let retirementCompletions = self.retirementCompletions
                    self.retirementKillWork?.cancel()
                    self.retirementKillWork = nil
                    self.retirementCompletions.removeAll()
                    self.isRetiringImmediately = false
                    self.launchIsPending = false
                    self.process = nil
                    self.stdin = nil
                    self.stdout = nil
                    self.stderrLog = nil
                    if retiredIntentionally {
                        retirementCompletions.forEach { $0() }
                    } else {
                        self.onUnexpectedExit(self.access, exit)
                    }
                }
            }
        }

        // Establish identity before launching so an immediate `ready` callback cannot beat the
        // runtime's ownership assignment while `Process.run()` returns to the main actor.
        process = proc
        stdin = inHandle
        stdout = outHandle
        stderrLog = errorLog
        launchIsPending = true
        let processStarter = self.processStarter

        Self.launchQueue.async { [weak self, weak proc] in
            guard let proc else { return }
            let failure = processStarter(proc)
            DispatchQueue.main.async { [weak self, weak proc] in
                MainActor.assumeIsolated {
                    guard let proc else { return }
                    if let failure {
                        // A failed exec never produces a termination callback, so release every
                        // pipe here even when this runtime was detached while launch was pending.
                        readerQueue.sync {
                            readerState.closed = true
                            outHandle.readabilityHandler = nil
                        }
                        try? inHandle.close()
                        try? outHandle.close()
                        try? errorLog?.close()
                        guard let self else { return }
                        guard self.process === proc else { return }
                        let retiredIntentionally = self.isRetiringImmediately
                        let retirementCompletions = self.retirementCompletions
                        self.retirementKillWork?.cancel()
                        self.retirementKillWork = nil
                        self.retirementCompletions.removeAll()
                        self.isRetiringImmediately = false
                        self.launchIsPending = false
                        self.process = nil
                        self.stdin = nil
                        self.stdout = nil
                        self.stderrLog = nil
                        if retiredIntentionally {
                            retirementCompletions.forEach { $0() }
                        } else {
                            self.onLaunchFailure(self.access, failure)
                        }
                    } else if let self, self.process === proc {
                        self.launchIsPending = false
                        if self.isRetiringImmediately {
                            self.signalImmediateRetirement(of: proc)
                        }
                    } else if self?.process !== proc, proc.isRunning {
                        // `stop()` may have detached this generation while Gatekeeper was still
                        // validating it. Do not let the eventually launched orphan survive.
                        proc.terminate()
                    }
                }
            }
        }
    }

    /// The PATH every shell command an agent runs will resolve against.
    ///
    /// Three sources, in this order, de-duplicated:
    ///
    /// 1. The **login shell's** PATH, because that is the only authority on what the person actually
    ///    installed. A Finder or Sparkle launch inherits launchd's minimal PATH, so `/opt/homebrew/bin`
    ///    is absent and every `npm`, `gh` or `python3` they have is unreachable — the agent reports
    ///    "command not found" or "permission denied" and a model relays that as *blocked*.
    /// 2. Anything **inherited** that the login shell did not list, so a developer launch from a
    ///    terminal and any MDM-injected entry still survive.
    /// 3. The **bundled runtime**, LAST. It is a fallback for a stock Mac with no Node, not an
    ///    override: prepending it shadowed the person's own `node` with the pinned one in every
    ///    command an agent ran. `codex-runtime-path.mjs` already refuses to do this for Python —
    ///    *"that would shadow the user's interpreter in every shell command the agent runs"* — and
    ///    this lane is held to the same rule.
    ///
    /// Idempotent: an entry already present is never added twice, so a relaunch cannot grow PATH.
    static func agentPath(login: String?, inherited: String?, runtime: String?) -> String {
        var seen = Set<String>()
        var entries: [String] = []
        for source in [login, inherited] {
            for entry in (source ?? "").split(separator: ":").map(String.init)
            where !entry.isEmpty && seen.insert(entry).inserted {
                entries.append(entry)
            }
        }
        if entries.isEmpty {
            entries = ["/usr/local/bin", "/usr/bin", "/bin"]
            seen.formUnion(entries)
        }
        if let runtime, !runtime.isEmpty, seen.insert(runtime).inserted {
            entries.append(runtime)
        }
        return entries.joined(separator: ":")
    }

    /// Ask the person's login shell for its PATH once per app run.
    ///
    /// `printenv` rather than `echo $PATH`: fish and friends do not share POSIX variable syntax, but
    /// every shell can exec a binary. A shell that hangs — waiting on a prompt in a login file, or a
    /// slow network mount — must not delay a daemon launch, so the read is bounded and failure is
    /// silent: the inherited PATH is still a working, if smaller, environment.
    ///
    /// Measured at 40ms for a normal zsh, and the result is cached for the life of the app run, so
    /// only the first lane to launch pays it.
    static func loginShellPath(
        shell: String? = ProcessInfo.processInfo.environment["SHELL"],
        timeout: TimeInterval = 2
    ) -> String? {
        let shellPath = shell.flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shellPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lc", "/usr/bin/printenv PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let expiry = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: expiry)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        expiry.cancel()
        guard process.terminationStatus == 0 else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static var loginShellPathCache: String??
    static func cachedLoginShellPath() -> String? {
        if let cached = loginShellPathCache { return cached }
        let resolved = loginShellPath()
        loginShellPathCache = resolved
        return resolved
    }

    /// Anthropic's macOS secure-storage namespace is user-scoped and its CLI requires `USER` even
    /// when HOME points at the correct account. Finder and Sparkle normally provide it, but an app
    /// launched by a stripped harness or unusual process manager may not. Make that OS identity an
    /// explicit child-process invariant instead of letting authentication depend on launch style.
    static func withUserIdentity(
        _ environment: [String: String],
        currentUser: String = NSUserName()
    ) -> [String: String] {
        var result = environment
        let inherited = result["USER"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = (inherited?.isEmpty == false ? inherited : nil) ?? currentUser
        result["USER"] = user
        if result["LOGNAME"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            result["LOGNAME"] = user
        }
        return result
    }

    /// Stop this runtime intentionally. Its termination handler cannot report this as an unexpected
    /// exit because the owned process identity is cleared before `terminate()` is called.
    func stop() {
        let proc = process
        let input = stdin
        process = nil
        stdin = nil
        stdout = nil
        stderrLog = nil
        launchIsPending = false
        try? input?.close()
        guard let proc else { return }

        // EOF is the cooperative shutdown request. Give agentd a bounded chance to drain and reap
        // its own provider children before escalating to TERM, then guarantee death with KILL.
        let terminationQueue = DispatchQueue.global(qos: .utility)
        terminationQueue.asyncAfter(deadline: .now() + 3) {
            guard proc.isRunning else { return }
            proc.terminate()
            terminationQueue.asyncAfter(deadline: .now() + 2) {
                guard proc.isRunning else { return }
                _ = Darwin.kill(proc.processIdentifier, SIGKILL)
            }
        }
    }

    /// Retire a provider lane whose accepted Stop request never produced a terminal event.
    ///
    /// Ordinary `stop()` is cooperative-first: agentd gets EOF and may keep a healthy turn alive
    /// for three seconds before TERM. That is the right window-close/reload behavior, but it is the
    /// wrong promise after the user already pressed Stop and the provider failed to acknowledge it.
    /// Retain callback ownership, signal the daemon immediately, and complete only after the exact
    /// process has actually exited. agentd's TERM drain is capped at two seconds; the outer KILL is
    /// deliberately later so the app never races that drain at the same deadline.
    func retireImmediately(completion: @escaping () -> Void) {
        retirementCompletions.append(completion)
        guard !isRetiringImmediately else { return }
        isRetiringImmediately = true
        try? stdin?.close()
        stdin = nil
        guard let proc = process else {
            let completions = retirementCompletions
            retirementCompletions.removeAll()
            isRetiringImmediately = false
            launchIsPending = false
            completions.forEach { $0() }
            return
        }
        // A cold executable-validation launch may still be pending. Its completion path observes
        // this flag and signals the process immediately after exec; a launch failure is equally
        // valid proof that no old generation exists.
        guard !launchIsPending else { return }
        signalImmediateRetirement(of: proc)
    }

    private func signalImmediateRetirement(of proc: Process) {
        guard process === proc, isRetiringImmediately else { return }
        if proc.isRunning { proc.terminate() }
        retirementKillWork?.cancel()
        let kill = DispatchWorkItem {
            guard proc.isRunning else { return }
            _ = Darwin.kill(proc.processIdentifier, SIGKILL)
        }
        retirementKillWork = kill
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + 4,
            execute: kill)
    }

    /// Enqueue one JSON request as a newline-delimited record. `true` means that a valid record was
    /// accepted for the current live process; provider-turn ownership still begins only with
    /// agentd's `turn_started` event. The serial writer may briefly block on a full child pipe, but
    /// it can no longer block AppKit's main actor.
    @discardableResult
    func write(_ request: [String: Any]) -> Bool {
        guard let process, process.isRunning, let stdin else { return false }
        let data: Data
        do {
            data = try AgentdNDJSONRecordEncoder.encode(request)
        } catch {
            return false
        }
        let recordWriter = self.recordWriter
        writerQueue.async { [weak process] in
            guard let process, process.isRunning else { return }
            do {
                try recordWriter(stdin, data)
            } catch {
                // A live child whose control pipe no longer accepts requests is unusable. Let the
                // ordinary termination path recover pending starts and restart the exact lane.
                if process.isRunning { process.terminate() }
            }
        }
        return true
    }

    private static func route(for access: ModelAccess) -> (provider: String, authMode: String) {
        switch access {
        case .claudeSubscription: return ("anthropic", "subscription")
        case .anthropicAPI: return ("anthropic", "apikey")
        case .codexSubscription: return ("codex", "subscription")
        case .openAIAPI: return ("openai", "apikey")
        case .claudeVertex: return ("anthropic", "vertex")
        case .claudeBedrock: return ("anthropic", "bedrock")
        }
    }

    /// Secret-free route metadata handed to agentd. Keeping this mapping explicit and testable
    /// prevents a tenant profile from becoming a generic environment-variable injection surface.
    nonisolated static func tenantRouteEnvironment(
        for access: ModelAccess,
        profile: TenantProfile,
        supportDirectory: URL
    ) -> [String: String] {
        // Remote MCP OAuth is lane-independent, so this one is not gated on a route. It names the
        // hosts allowed to use the audited same-origin browser sign-in, which used to be a hostname
        // compiled into agentd. The value comes from the signed profile; the public profile declares
        // none, and with none declared agentd offers that fallback to no host at all.
        var shared: [String: String] = [:]
        if let suffix = profile.extensions.sameOriginBrowserAuthHostSuffix?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !suffix.isEmpty {
            shared["MECHANICIAN_MCP_SAME_ORIGIN_HOST_SUFFIX"] = suffix
        }
        if access == .claudeBedrock {
            guard let bedrock = profile.bedrockConfig,
                  let routeIdentity = profile.routeIdentity(for: access),
                  let configDirectory = profile.routeConfigDirectory(
                    for: access, supportDirectory: supportDirectory)
            else { return [:] }
            var environment = [
                "MECHANICIAN_BEDROCK_REGION": bedrock.region,
                "MECHANICIAN_ROUTE_IDENTITY": routeIdentity,
                "MECHANICIAN_CONFIG_DIR": configDirectory.path,
            ]
            if let awsProfile = bedrock.profile?.trimmingCharacters(in: .whitespacesAndNewlines),
               !awsProfile.isEmpty {
                environment["MECHANICIAN_AWS_PROFILE"] = awsProfile
            }
            return environment.merging(shared) { current, _ in current }
        }
        guard access == .claudeVertex,
              let vertex = profile.vertexConfig,
              let routeIdentity = profile.routeIdentity(for: access),
              let configDirectory = profile.routeConfigDirectory(
                    for: access, supportDirectory: supportDirectory)
        else { return shared }
        var environment = [
            "MECHANICIAN_VERTEX_PROJECT": vertex.projectId,
            "MECHANICIAN_VERTEX_REGION": vertex.region,
            "MECHANICIAN_ROUTE_IDENTITY": routeIdentity,
            "MECHANICIAN_CONFIG_DIR": configDirectory.path,
        ]
        // `supportedModels()` requires a real Claude query to initialize first. If that query omits
        // a model, the bundled runtime chooses its moving first-party default—which can be newer
        // than this Vertex project and fail before discovery begins. The signed route's default is
        // the one model initialization is allowed to assume.
        if let declared = profile.declaredModels(for: access).first,
           !declared.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            environment["MECHANICIAN_MANAGED_MODEL"] = declared.id
        }
        return environment.merging(shared) { current, _ in current }
    }

    nonisolated static func supportDirectory(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        if let override = environment["MECHANICIAN_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent("Library/Application Support/Mechanician", isDirectory: true)
    }

    /// A GUI-launched app has a minimal PATH, so prefer a known absolute Node executable.
    private static func resolveNodePath() -> String {
        if let override = ProcessInfo.processInfo.environment["MECHANICIAN_NODE"] {
            return override
        }
        // Prefer the Node runtime bundled in the app — self-contained, no system Node required, and
        // a pinned version so node-pty's native prebuild always matches its ABI.
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("node").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/usr/bin/env"
    }

    /// Resolve agentd from an explicit dev override, the app bundle, then the repository layout.
    ///
    /// Directly launching `build/Mechanician-dev.app` does not inherit the override exported by
    /// `dev.sh`, and its working directory is not guaranteed to be `app/`. The bundle's ancestors
    /// are therefore the most reliable way to recover the source repository. Current-directory
    /// candidates remain useful for running the executable or tests outside an app bundle.
    private static func resolveAgentdPath() -> String {
        resolvedAgentdPath(
            environment: ProcessInfo.processInfo.environment,
            resourceURL: Bundle.main.resourceURL,
            bundleURL: Bundle.main.bundleURL,
            currentDirectoryURL: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true),
            fileExists: FileManager.default.fileExists(atPath:))
    }

    nonisolated static func resolvedAgentdPath(
        environment: [String: String],
        resourceURL: URL?,
        bundleURL: URL,
        currentDirectoryURL: URL,
        fileExists: (String) -> Bool
    ) -> String {
        if let override = environment["MECHANICIAN_AGENTD"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
        }

        let relativePath = "agentd/src/agentd.mjs"
        if let bundled = resourceURL?
            .appendingPathComponent(relativePath)
            .standardizedFileURL.path,
           fileExists(bundled) {
            return bundled
        }

        var candidates: [String] = []
        func appendCandidate(root: URL) {
            let path = root
                .appendingPathComponent(relativePath)
                .standardizedFileURL.path
            if !candidates.contains(path) {
                candidates.append(path)
            }
        }

        // A source-built bundle normally lives at `<repo>/build/Mechanician-dev.app`. Bound the
        // walk so an unexpectedly relocated bundle cannot turn this into an unbounded filesystem
        // search; only exact, inexpensive existence checks are performed.
        var ancestor = bundleURL.standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<6 {
            appendCandidate(root: ancestor)
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            ancestor = parent
        }

        let workingDirectory = currentDirectoryURL.standardizedFileURL
        appendCandidate(root: workingDirectory)
        appendCandidate(root: workingDirectory.deletingLastPathComponent())

        if let found = candidates.first(where: fileExists) {
            return found
        }

        // Retain the historical source-tree fallback so launch failures still identify the path
        // callers previously expected when neither a bundle nor repository checkout is present.
        return workingDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
            .standardizedFileURL.path
    }

    /// Keep provider stderr durable for crash/stall diagnosis without allowing an unbounded log.
    /// Each exact access lane has its own file; a single previous generation is retained.
    private static func openStderrLog(for access: ModelAccess) -> FileHandle? {
        let environment = ProcessInfo.processInfo.environment
        let base = supportDirectory(
            environment: environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        let directory = base.appendingPathComponent("logs", isDirectory: true)
        let url = directory.appendingPathComponent("agentd-\(access.rawValue).log")
        let previous = directory.appendingPathComponent("agentd-\(access.rawValue).previous.log")
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
           size.int64Value > 5 * 1024 * 1024 {
            try? fileManager.removeItem(at: previous)
            try? fileManager.moveItem(at: url, to: previous)
        }
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]) else { return nil }
        }
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        do {
            try handle.seekToEnd()
            let timestamp = ISO8601DateFormatter().string(from: Date())
            if let header = "\n--- agentd \(access.rawValue) launched \(timestamp) ---\n"
                .data(using: .utf8) {
                try handle.write(contentsOf: header)
            }
            return handle
        } catch {
            try? handle.close()
            return nil
        }
    }
}
