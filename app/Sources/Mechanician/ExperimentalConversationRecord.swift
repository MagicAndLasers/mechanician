import CryptoKit
import CoreFoundation
import Darwin
import Foundation

enum ExperimentalConversationRecordProfile: String, CaseIterable, Sendable {
    case shareSnapshot = "ai.mechanician.share-snapshot/0-experimental"
    case localFull = "ai.mechanician.local-full/0-experimental"

    var title: String {
        switch self {
        case .shareSnapshot: return "Share Snapshot"
        case .localFull: return "Local Full"
        }
    }

    var detail: String {
        switch self {
        case .shareSnapshot:
            return "Retains dialog; omits tool, interaction, task, result, and common path content. Review required."
        case .localFull:
            return "All currently mapped portable facts. May contain sensitive conversation content."
        }
    }
}

struct ExperimentalConversationRecordOmission: Decodable, Equatable, Sendable {
    let code: String
    let count: Int
    let reason: String
}

struct ExperimentalConversationRecordReport: Decodable, Equatable, Sendable {
    let formatVersion: Int
    let profile: String
    let lineageID: String
    let versionID: String
    let contentDigestSHA256: String
    let byteDigestSHA256: String
    let bytes: Int
    let agents: Int
    let events: Int
    let chronology: String
    let omissions: [ExperimentalConversationRecordOmission]
    var trailingUncommittedBytes: Int = 0
    var publicationWarning: String? = nil

    var profileTitle: String {
        ExperimentalConversationRecordProfile(rawValue: profile)?.title ?? "Unknown profile"
    }
}

struct ExperimentalConversationRecordInspectionAgent: Equatable, Identifiable, Sendable {
    let rowID: Int
    let displayID: String
    let parentID: String?
    let type: String
    let observedModel: String?

    var id: Int { rowID }
}

struct ExperimentalConversationRecordInspectionDialog: Equatable, Identifiable, Sendable {
    let id: String
    let kind: String
    let actorID: String
    let observedAt: String?
    let text: String
    let wasTruncated: Bool
}

/// A detached, bounded, inert projection produced during the exact descriptor read that validated
/// the record. It is intentionally not a Conversation, transcript entry, import model, or trust
/// token for reopening the path.
struct ExperimentalConversationRecordInspection: Equatable, Sendable {
    let report: ExperimentalConversationRecordReport
    let displayName: String
    let exportedAt: String?
    let producerName: String?
    let producerVersion: String?
    let producerBuild: String?
    let producerSourceRevision: String?
    let agents: [ExperimentalConversationRecordInspectionAgent]
    let dialog: [ExperimentalConversationRecordInspectionDialog]
    let omittedAgentCount: Int
    let omittedDialogEntryCount: Int
    let truncatedDialogEntryCount: Int
    let replacedControlCharacterCount: Int
}

enum ExperimentalConversationRecordError: LocalizedError, Equatable {
    case selectionChanged
    case sourcePersistenceFailed
    case runtimeUnavailable
    case exporterFailed(String)
    case exporterTimedOut
    case exporterCancelled
    case destinationAlreadyExists
    case publicationMismatch
    case fileTooLarge
    case notRegularFile
    case fileChangedDuringValidation
    case validationCancelled
    case validationTimedOut
    case unsupportedPrelude
    case missingCommit
    case truncatedFrame
    case oversizedFrame
    case checksumMismatch
    case malformedFrame
    case unexpectedFrame(String)
    case commitMismatch

    var errorDescription: String? {
        switch self {
        case .selectionChanged:
            return "The selected conversation changed before export began. Try again."
        case .sourcePersistenceFailed:
            return "Mechanician could not publish the current conversation before export. No Conversation Record was written."
        case .runtimeUnavailable:
            return "The experimental Conversation Record exporter is unavailable in this build."
        case .exporterFailed(let message):
            return "The experimental Conversation Record exporter failed: \(message)"
        case .exporterTimedOut:
            return "The experimental Conversation Record exporter did not finish within two minutes. No destination file was changed."
        case .exporterCancelled:
            return "The experimental Conversation Record export was cancelled. No destination file was changed."
        case .destinationAlreadyExists:
            return "A file now exists at the export destination. Mechanician left it unchanged; choose a new filename and try again."
        case .publicationMismatch:
            return "The published Conversation Record did not match the validated export. Mechanician did not report it as successful."
        case .fileTooLarge:
            return "This experimental Conversation Record exceeds the 512 MB validation limit."
        case .notRegularFile:
            return "Conversation Record validation accepts regular files only."
        case .fileChangedDuringValidation:
            return "The Conversation Record changed while it was being validated. Try again when the file is stable."
        case .validationCancelled:
            return "Conversation Record inspection was cancelled."
        case .validationTimedOut:
            return "Conversation Record validation exceeded the two-minute safety limit."
        case .unsupportedPrelude:
            return "This is not a supported experimental Conversation Record v0."
        case .missingCommit:
            return "The Conversation Record has no valid final commit. It may be incomplete."
        case .truncatedFrame:
            return "The Conversation Record ends inside a frame. It was not modified."
        case .oversizedFrame:
            return "A Conversation Record frame exceeds the 16 MB experimental limit."
        case .checksumMismatch:
            return "A Conversation Record frame failed its CRC-32 integrity check."
        case .malformedFrame:
            return "A Conversation Record frame does not contain a valid JSON object."
        case .unexpectedFrame(let type):
            return "The Conversation Record contains an unexpected \(type) frame."
        case .commitMismatch:
            return "The Conversation Record commit does not match its preceding bytes."
        }
    }
}

/// Structurally independent, read-only reader for the experimental framed binding. It shares no
/// parsing or checksum code with the JavaScript writer and never truncates or repairs a user file.
enum ExperimentalConversationRecordValidator {
    static let maximumFrameBytes = 16 * 1024 * 1024
    static let maximumRecordBytes = 512 * 1024 * 1024
    static let maximumEventCount = 100_000
    static let maximumAgentCount = 10_000
    static let maximumWorkflowCount = 10_000
    static let maximumWorkflowPhaseCount = 50_000
    static let maximumInspectionAgentCount = 2_000
    static let maximumInspectionDialogCount = 2_000
    static let maximumInspectionDialogEntryUTF8Bytes = 16 * 1024
    static let maximumInspectionDialogUTF8Bytes = 2 * 1024 * 1024
    static let maximumRetainedSemanticBytes = 64 * 1024 * 1024
    private static let maximumJSONDepth = 64
    private static let maximumJSONStructuralTokens = 1_000_000
    private static let maximumValidationSeconds: TimeInterval = 120
    private static let prelude = Data([
        0x43, 0x4f, 0x4e, 0x56, 0x52, 0x45, 0x43, 0x00,
        0x00, 0x00, 0x01, 0x00, 0x10, 0x00, 0x00, 0x00,
    ])

    private static let crcTable: [UInt32] = (0..<256).map { source in
        var value = UInt32(source)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffffffff
        for byte in data {
            value = crcTable[Int((value ^ UInt32(byte)) & 0xff)] ^ (value >> 8)
        }
        return value ^ 0xffffffff
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    /// FileHandle may legally return a short read. Loop until the exact requested byte count is
    /// available, distinguish clean EOF from a torn value, and never allocate beyond validated caps.
    private static func readExactly(
        _ count: Int,
        from handle: FileHandle
    ) throws -> Data? {
        var data = Data()
        while data.count < count {
            let chunk = try handle.read(upToCount: count - data.count) ?? Data()
            if chunk.isEmpty {
                if data.isEmpty { return nil }
                throw ExperimentalConversationRecordError.truncatedFrame
            }
            data.append(chunk)
        }
        return data
    }

    private static func checkBudget(
        startedAt: TimeInterval,
        isCancelled: () -> Bool
    ) throws {
        if isCancelled() {
            throw ExperimentalConversationRecordError.validationCancelled
        }
        if ProcessInfo.processInfo.systemUptime - startedAt > maximumValidationSeconds {
            throw ExperimentalConversationRecordError.validationTimedOut
        }
    }

    /// Bound JSON nesting and collection complexity before Foundation materializes an object graph.
    /// JSONSerialization remains the grammar authority; this scanner is only a fail-fast resource
    /// budget over untrusted bytes.
    private static func validateJSONComplexity(
        _ data: Data,
        startedAt: TimeInterval,
        isCancelled: () -> Bool
    ) throws {
        var depth = 0
        var tokens = 0
        var insideString = false
        var escaped = false
        for (index, byte) in data.enumerated() {
            if index & 0xffff == 0 {
                try checkBudget(startedAt: startedAt, isCancelled: isCancelled)
            }
            if insideString {
                if escaped {
                    escaped = false
                } else if byte == 0x5c {
                    escaped = true
                } else if byte == 0x22 {
                    insideString = false
                }
                continue
            }
            switch byte {
            case 0x22: // string
                insideString = true
                tokens += 1
            case 0x7b, 0x5b: // { [
                depth += 1
                tokens += 1
                guard depth <= maximumJSONDepth else {
                    throw ExperimentalConversationRecordError.malformedFrame
                }
            case 0x7d, 0x5d: // } ]
                depth -= 1
                tokens += 1
                guard depth >= 0 else {
                    throw ExperimentalConversationRecordError.malformedFrame
                }
            case 0x2c, 0x3a: // , :
                tokens += 1
            default:
                break
            }
            guard tokens <= maximumJSONStructuralTokens else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
        }
        guard depth == 0, !insideString, !escaped else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
    }

    private static func boundedString(_ value: Any?, maximum: Int = 512) -> String? {
        guard let string = value as? String,
              !string.isEmpty,
              string.utf8.count <= maximum,
              string.unicodeScalars.count <= maximum else { return nil }
        return string
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let result = Int(number.stringValue),
              result >= 0 else { return nil }
        return result
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.unicodeScalars.allSatisfy {
            ("0"..."9").contains(Character(String($0)))
                || ("a"..."f").contains(Character(String($0)))
        }
    }

    private static func isExperimentalV8URN(_ value: String) -> Bool {
        value.range(
            of: #"^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
            options: .regularExpression) != nil
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let knownEventKinds: Set<String> = [
        "agent_call_result", "agent_identity", "agent_lifecycle", "agent_spawn",
        "answer", "answer_ack", "assistant_message", "authorization_ack",
        "authorization_request", "authorization_response", "compaction", "context_usage",
        "history_reduction", "interaction_closed", "question", "supersession", "system",
        "tool_call", "tool_result", "tool_terminal", "usage", "user_delivery",
        "user_message",
    ]

    /// The validator retains only bounded identifiers and counters from the graph and event stream.
    /// Tool results, dialog, and other potentially large payloads leave scope with each frame.
    private struct SemanticChronology {
        let status: String
        let eventCount: Int
        let maximumCaptureOrdinal: Int?
        let captureBatchCount: Int?
        let capturedOrdinalEventCount: Int?
        let missingCaptureOrdinalEventCount: Int?
        let invalidCaptureOrdinalEventCount: Int?
        let stableEventIDEventCount: Int?
        let missingStableEventIDEventCount: Int?
        let duplicateStableEventIDEventCount: Int?
        let legacySummaryEventCount: Int?
        let degradedWorkflowSummaryEventCount: Int?
    }

    private struct SemanticManifest {
        let profile: String
        let lineageID: String
        let versionID: String
        let eventCount: Int
        let agentCount: Int
        let workflowCount: Int
        let omissions: [ExperimentalConversationRecordOmission]
    }

    private struct SemanticGraph {
        let agentIDs: Set<String>
        let workflowIDs: Set<String>
        let workflowByPhaseID: [String: String]
        let chronology: SemanticChronology
        let recordLineageID: String
        let recordVersionID: String
        let agentCount: Int
        let workflowCount: Int
        let retainedSemanticBytes: Int
    }

    private struct InspectionAccumulator {
        var displayName = "Conversation Record"
        var exportedAt: String?
        var producerName: String?
        var producerVersion: String?
        var producerBuild: String?
        var producerSourceRevision: String?
        var agents: [ExperimentalConversationRecordInspectionAgent] = []
        var dialog: [ExperimentalConversationRecordInspectionDialog] = []
        var omittedAgentCount = 0
        var omittedDialogEntryCount = 0
        var truncatedDialogEntryCount = 0
        var replacedControlCharacterCount = 0
        var retainedDialogUTF8Bytes = 0
    }

    private struct ReadResult {
        let report: ExperimentalConversationRecordReport
        let inspection: ExperimentalConversationRecordInspection?
    }

    private struct InteractionReference {
        let id: String
        let expectedType: String
    }

    private struct SemanticEvents {
        var count = 0
        var eventIDs: Set<String> = []
        var missingEventIDCount = 0
        var duplicateEventIDCount = 0
        var referencedEventIDs: [String] = []
        var validCaptureOrdinalCount = 0
        var missingCaptureOrdinalCount = 0
        var maximumCaptureOrdinal: Int?
        var captureOrdinals: Set<Int> = []
        var previousCaptureOrdinal: Int?
        var previousEventID: String?
        var toolCalls: Set<String> = []
        var toolReferences: Set<String> = []
        var interactionTypes: [String: String] = [:]
        var interactionReferences: [InteractionReference] = []
        var spawnedAgentByCorrelationID: [String: String] = [:]
        var completedAgentByCorrelationID: [String: String] = [:]
        var spawnedAgentIDs: Set<String> = []
        var completedAgentIDs: Set<String> = []
        var legacySummaryEventCount = 0
        var degradedWorkflowSummaryEventCount = 0
        var retainedSemanticBytes = 0
    }

    static func validateGraphEntityCounts(
        agents: Int,
        workflows: Int,
        phases: Int
    ) throws {
        guard agents > 0,
              agents <= maximumAgentCount,
              workflows >= 0,
              workflows <= maximumWorkflowCount,
              phases >= 0,
              phases <= maximumWorkflowPhaseCount else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
    }

    static func validateCanAppendEvent(currentCount: Int) throws {
        guard currentCount >= 0, currentCount < maximumEventCount else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
    }

    @discardableResult
    static func validateCanRetainSemanticBytes(
        currentBytes: Int,
        addingUTF8Bytes: Int,
        entries: Int = 1
    ) throws -> Int {
        guard currentBytes >= 0, addingUTF8Bytes >= 0, entries >= 0 else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        let (entryOverhead, overheadOverflow) = entries.multipliedReportingOverflow(by: 64)
        let (increment, incrementOverflow) = addingUTF8Bytes.addingReportingOverflow(entryOverhead)
        let (next, totalOverflow) = currentBytes.addingReportingOverflow(increment)
        guard !overheadOverflow, !incrementOverflow, !totalOverflow,
              next <= maximumRetainedSemanticBytes else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        return next
    }

    private static func chargeRetainedSemantic(
        _ values: [String],
        state: inout SemanticEvents
    ) throws {
        let utf8Bytes = values.reduce(into: 0) { total, value in
            total += value.utf8.count
        }
        state.retainedSemanticBytes = try validateCanRetainSemanticBytes(
            currentBytes: state.retainedSemanticBytes,
            addingUTF8Bytes: utf8Bytes,
            entries: values.count)
    }

    private static func chargeRetainedSemantic(
        _ values: [String],
        total: inout Int
    ) throws {
        let utf8Bytes = values.reduce(into: 0) { sum, value in
            sum += value.utf8.count
        }
        total = try validateCanRetainSemanticBytes(
            currentBytes: total,
            addingUTF8Bytes: utf8Bytes,
            entries: values.count)
    }

    private static func isUnsafeDisplayScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (value < 0x20 && value != 0x09 && value != 0x0a)
            || (0x7f...0x9f).contains(value)
            || value == 0x061c
            || value == 0x200e
            || value == 0x200f
            || (0x202a...0x202e).contains(value)
            || (0x2066...0x2069).contains(value)
    }

    private static func inertDisplayPrefix(
        _ source: String,
        maximumUTF8Bytes: Int
    ) -> (text: String, truncated: Bool, replacements: Int) {
        var output = String.UnicodeScalarView()
        var usedBytes = 0
        var replacements = 0
        var truncated = false
        for scalar in source.unicodeScalars {
            let displayed: Unicode.Scalar
            if isUnsafeDisplayScalar(scalar) {
                displayed = "\u{fffd}"
                replacements += 1
            } else {
                displayed = scalar
            }
            let byteCount = String(displayed).utf8.count
            guard usedBytes + byteCount <= maximumUTF8Bytes else {
                truncated = true
                break
            }
            output.append(displayed)
            usedBytes += byteCount
        }
        return (String(output), truncated, replacements)
    }

    private static func inertMetadataString(
        _ value: Any?,
        maximum: Int = 512,
        accumulator: inout InspectionAccumulator
    ) -> String? {
        guard let source = boundedString(value, maximum: maximum) else { return nil }
        let projected = inertDisplayPrefix(source, maximumUTF8Bytes: maximum)
        accumulator.replacedControlCharacterCount += projected.replacements
        return projected.text
    }

    private static func ingestInspectionDialog(
        _ event: [String: Any],
        eventOrdinal: Int,
        inspection: inout InspectionAccumulator?
    ) {
        guard var accumulator = inspection,
              let kind = event["kind"] as? String,
              kind == "user_message" || kind == "assistant_message" || kind == "system" else {
            return
        }
        guard accumulator.dialog.count < maximumInspectionDialogCount,
              accumulator.retainedDialogUTF8Bytes < maximumInspectionDialogUTF8Bytes,
              let source = event["text"] as? String else {
            accumulator.omittedDialogEntryCount += 1
            inspection = accumulator
            return
        }

        let remainingBytes = maximumInspectionDialogUTF8Bytes
            - accumulator.retainedDialogUTF8Bytes
        let entryBudget = min(maximumInspectionDialogEntryUTF8Bytes, remainingBytes)
        let projected = inertDisplayPrefix(source, maximumUTF8Bytes: entryBudget)
        accumulator.retainedDialogUTF8Bytes += projected.text.utf8.count
        accumulator.replacedControlCharacterCount += projected.replacements
        if projected.truncated {
            accumulator.truncatedDialogEntryCount += 1
        }
        let actorID = inertMetadataString(
            event["agentId"], maximum: 512, accumulator: &accumulator)
            ?? (kind == "user_message" ? "user" : "unknown-agent")
        let observedAt = inertMetadataString(
            event["observedAt"], maximum: 128, accumulator: &accumulator)
        accumulator.dialog.append(ExperimentalConversationRecordInspectionDialog(
            id: "inspection-dialog-\(eventOrdinal)",
            kind: kind,
            actorID: actorID,
            observedAt: observedAt,
            text: projected.text,
            wasTruncated: projected.truncated))
        inspection = accumulator
    }

    private static func optionalID(
        _ object: [String: Any],
        _ key: String
    ) throws -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        guard let result = boundedString(value) else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        return result
    }

    private static func requiredID(
        _ object: [String: Any],
        _ key: String
    ) throws -> String {
        guard let result = try optionalID(object, key) else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        return result
    }

    private static func optionalInteger(_ value: Any?) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        guard let result = integer(value) else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        return result
    }

    private static func semanticCounter(_ value: Any?) -> Int? {
        guard let result = integer(value), result <= maximumEventCount else { return nil }
        return result
    }

    private static func validateSemanticManifest(
        _ object: [String: Any],
        inspection: inout InspectionAccumulator?
    ) throws -> SemanticManifest {
        guard integer(object["formatVersion"]) == 0,
              boundedString(object["documentType"])
                == "ai.mechanician.conversation-record",
              boundedString(object["compatibility"]) == "experimental-no-compatibility",
              boundedString(object["binding"])
                == "framed-json-crc32-commit/0-experimental",
              let profile = boundedString(object["profile"]),
              ExperimentalConversationRecordProfile(rawValue: profile) != nil,
              let identity = object["identity"] as? [String: Any],
              let lineageID = boundedString(identity["conversationLineageID"]),
              let versionID = boundedString(identity["recordVersionID"]),
              isExperimentalV8URN(lineageID),
              isExperimentalV8URN(versionID),
              lineageID != versionID,
              let counts = object["counts"] as? [String: Any],
              let eventCount = semanticCounter(counts["events"]),
              let agentCount = integer(counts["agents"]),
              let workflowCount = integer(counts["workflows"]),
              let disclosure = object["disclosure"] as? [String: Any],
              let rawOmissions = disclosure["omissions"] as? [[String: Any]],
              rawOmissions.count <= 128 else {
            throw ExperimentalConversationRecordError.malformedFrame
        }

        var omissions: [ExperimentalConversationRecordOmission] = []
        omissions.reserveCapacity(rawOmissions.count)
        for omission in rawOmissions {
            guard let code = boundedString(omission["code"], maximum: 128),
                  let count = integer(omission["count"]),
                  let reason = boundedString(omission["reason"], maximum: 512) else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
            omissions.append(ExperimentalConversationRecordOmission(
                code: code, count: count, reason: reason))
        }

        if var accumulator = inspection {
            accumulator.exportedAt = inertMetadataString(
                object["exportedAt"], maximum: 128, accumulator: &accumulator)
            if let producer = object["producer"] as? [String: Any] {
                accumulator.producerName = inertMetadataString(
                    producer["name"], maximum: 128, accumulator: &accumulator)
                accumulator.producerVersion = inertMetadataString(
                    producer["version"], maximum: 128, accumulator: &accumulator)
                accumulator.producerBuild = inertMetadataString(
                    producer["build"], maximum: 128, accumulator: &accumulator)
                accumulator.producerSourceRevision = inertMetadataString(
                    producer["sourceRevision"], maximum: 128, accumulator: &accumulator)
            }
            inspection = accumulator
        }

        return SemanticManifest(
            profile: profile,
            lineageID: lineageID,
            versionID: versionID,
            eventCount: eventCount,
            agentCount: agentCount,
            workflowCount: workflowCount,
            omissions: omissions)
    }

    private static func validateSemanticChronology(
        _ chronology: [String: Any]
    ) throws -> SemanticChronology {
        guard let status = boundedString(chronology["status"], maximum: 64),
              status == "complete" || status == "degraded",
              let eventCount = semanticCounter(chronology["eventCount"]) else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        if status == "complete" {
            guard let captureBatchCount = semanticCounter(
                    chronology["captureBatchCount"]) else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
            return SemanticChronology(
                status: status,
                eventCount: eventCount,
                maximumCaptureOrdinal: try optionalInteger(
                    chronology["maximumCaptureOrdinal"]),
                captureBatchCount: captureBatchCount,
                capturedOrdinalEventCount: nil,
                missingCaptureOrdinalEventCount: nil,
                invalidCaptureOrdinalEventCount: nil,
                stableEventIDEventCount: nil,
                missingStableEventIDEventCount: nil,
                duplicateStableEventIDEventCount: nil,
                legacySummaryEventCount: nil,
                degradedWorkflowSummaryEventCount: nil)
        }

        guard let capturedOrdinalEventCount = semanticCounter(
                chronology["capturedOrdinalEventCount"]),
              let missingCaptureOrdinalEventCount = semanticCounter(
                chronology["missingCaptureOrdinalEventCount"]),
              let invalidCaptureOrdinalEventCount = semanticCounter(
                chronology["invalidCaptureOrdinalEventCount"]),
              let stableEventIDEventCount = semanticCounter(
                chronology["stableEventIdEventCount"]),
              let missingStableEventIDEventCount = semanticCounter(
                chronology["missingStableEventIdEventCount"]),
              let duplicateStableEventIDEventCount = semanticCounter(
                chronology["duplicateStableEventIdEventCount"]),
              let legacySummaryEventCount = semanticCounter(
                chronology["legacySummaryEventCount"]) else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        let degradedWorkflowSummaryEventCount: Int?
        if let rawValue = chronology["degradedWorkflowSummaryEventCount"] {
            guard !(rawValue is NSNull), let count = semanticCounter(rawValue) else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
            degradedWorkflowSummaryEventCount = count
        } else {
            degradedWorkflowSummaryEventCount = nil
        }
        return SemanticChronology(
            status: status,
            eventCount: eventCount,
            maximumCaptureOrdinal: nil,
            captureBatchCount: nil,
            capturedOrdinalEventCount: capturedOrdinalEventCount,
            missingCaptureOrdinalEventCount: missingCaptureOrdinalEventCount,
            invalidCaptureOrdinalEventCount: invalidCaptureOrdinalEventCount,
            stableEventIDEventCount: stableEventIDEventCount,
            missingStableEventIDEventCount: missingStableEventIDEventCount,
            duplicateStableEventIDEventCount: duplicateStableEventIDEventCount,
            legacySummaryEventCount: legacySummaryEventCount,
            degradedWorkflowSummaryEventCount: degradedWorkflowSummaryEventCount)
    }

    private static func validateSemanticGraph(
        _ graph: [String: Any],
        inspection: inout InspectionAccumulator?
    ) throws -> SemanticGraph {
        guard boundedString(graph["format"])
                == "ai.mechanician.conversation-record/0-experimental",
              graph["events"] == nil,
              let agents = graph["agents"] as? [[String: Any]],
              !agents.isEmpty,
              agents.count <= maximumAgentCount,
              let chronologyObject = graph["chronology"] as? [String: Any],
              let record = graph["record"] as? [String: Any] else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        let chronology = try validateSemanticChronology(chronologyObject)

        var agentIDs: Set<String> = []
        var parentByAgentID: [String: String] = [:]
        var agentWorkflowReferences: [(workflowID: String?, phaseID: String?)] = []
        var retainedSemanticBytes = 0
        for (agentOrdinal, agent) in agents.enumerated() {
            let id = try requiredID(agent, "id")
            try chargeRetainedSemantic([id], total: &retainedSemanticBytes)
            guard agentIDs.insert(id).inserted else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
            let parentID = try optionalID(agent, "parentId")
            if let parentID {
                try chargeRetainedSemantic(
                    [id, parentID], total: &retainedSemanticBytes)
                guard parentID != id else {
                    throw ExperimentalConversationRecordError.malformedFrame
                }
                parentByAgentID[id] = parentID
            }
            let workflowID = try optionalID(agent, "workflowId")
            let phaseID = try optionalID(agent, "phaseId")
            try chargeRetainedSemantic(
                [workflowID, phaseID].compactMap { $0 }, total: &retainedSemanticBytes)
            agentWorkflowReferences.append((workflowID: workflowID, phaseID: phaseID))
            if var accumulator = inspection {
                if accumulator.agents.count < maximumInspectionAgentCount {
                    let displayID = inertMetadataString(
                        id, accumulator: &accumulator) ?? "unknown-agent"
                    let displayParentID = inertMetadataString(
                        parentID, accumulator: &accumulator)
                    let type = inertMetadataString(
                        agent["type"], maximum: 128, accumulator: &accumulator) ?? "agent"
                    let model = inertMetadataString(
                        agent["observedModel"], maximum: 256, accumulator: &accumulator)
                    accumulator.agents.append(ExperimentalConversationRecordInspectionAgent(
                        rowID: agentOrdinal,
                        displayID: displayID,
                        parentID: displayParentID,
                        type: type,
                        observedModel: model))
                } else {
                    accumulator.omittedAgentCount += 1
                }
                inspection = accumulator
            }
        }
        guard agentIDs.contains("root") else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        for parentID in parentByAgentID.values where !agentIDs.contains(parentID) {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        var resolvedAgentIDs: Set<String> = []
        for agentID in agentIDs where !resolvedAgentIDs.contains(agentID) {
            var path: [String] = []
            var pathIDs: Set<String> = []
            var cursor: String? = agentID
            while let current = cursor,
                  !resolvedAgentIDs.contains(current),
                  let parent = parentByAgentID[current] {
                guard pathIDs.insert(current).inserted else {
                    throw ExperimentalConversationRecordError.malformedFrame
                }
                path.append(current)
                cursor = parent
            }
            resolvedAgentIDs.formUnion(path)
        }

        let workflows: [[String: Any]]
        if let value = graph["workflows"] {
            guard let objects = value as? [[String: Any]] else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
            workflows = objects
        } else {
            workflows = []
        }
        guard workflows.count <= maximumWorkflowCount else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        var workflowIDs: Set<String> = []
        for workflow in workflows {
            let id = try requiredID(workflow, "id")
            let ownerID = try requiredID(workflow, "ownerAgentId")
            try chargeRetainedSemantic([id], total: &retainedSemanticBytes)
            guard workflowIDs.insert(id).inserted, agentIDs.contains(ownerID) else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
        }

        let phases: [[String: Any]]
        if let value = graph["workflowPhases"] {
            guard let objects = value as? [[String: Any]] else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
            phases = objects
        } else {
            phases = []
        }
        guard phases.count <= maximumWorkflowPhaseCount else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        try validateGraphEntityCounts(
            agents: agents.count,
            workflows: workflows.count,
            phases: phases.count)
        var workflowByPhaseID: [String: String] = [:]
        for phase in phases {
            let id = try requiredID(phase, "id")
            let workflowID = try requiredID(phase, "workflowId")
            try chargeRetainedSemantic(
                [id, workflowID], total: &retainedSemanticBytes)
            guard workflowByPhaseID[id] == nil, workflowIDs.contains(workflowID) else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
            workflowByPhaseID[id] = workflowID
        }
        for reference in agentWorkflowReferences {
            if let workflowID = reference.workflowID {
                guard workflowIDs.contains(workflowID) else {
                    throw ExperimentalConversationRecordError.malformedFrame
                }
            }
            if let phaseID = reference.phaseID {
                guard let phaseWorkflowID = workflowByPhaseID[phaseID],
                      reference.workflowID == phaseWorkflowID else {
                    throw ExperimentalConversationRecordError.malformedFrame
                }
            }
        }

        if var accumulator = inspection {
            accumulator.displayName = inertMetadataString(
                record["displayName"], maximum: 512, accumulator: &accumulator)
                ?? "Conversation Record"
            inspection = accumulator
        }

        return SemanticGraph(
            agentIDs: agentIDs,
            workflowIDs: workflowIDs,
            workflowByPhaseID: workflowByPhaseID,
            chronology: chronology,
            recordLineageID: try requiredID(record, "conversationLineageID"),
            recordVersionID: try requiredID(record, "recordVersionID"),
            agentCount: agents.count,
            workflowCount: workflows.count,
            retainedSemanticBytes: retainedSemanticBytes)
    }

    private static func validateActorReference(
        _ event: [String: Any],
        key: String,
        graph: SemanticGraph
    ) throws {
        guard let id = try optionalID(event, key) else { return }
        guard id == "user" || graph.agentIDs.contains(id) else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
    }

    private static func ingestSemanticEvent(
        _ event: [String: Any],
        graph: SemanticGraph,
        state: inout SemanticEvents
    ) throws {
        try validateCanAppendEvent(currentCount: state.count)
        guard let kind = boundedString(event["kind"], maximum: 128),
              knownEventKinds.contains(kind) else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        state.count += 1

        let eventID = try optionalID(event, "eventId")
        if let eventID {
            try chargeRetainedSemantic([eventID], state: &state)
            if !state.eventIDs.insert(eventID).inserted {
                state.duplicateEventIDCount += 1
            }
        } else {
            state.missingEventIDCount += 1
        }

        let captureOrdinal: Int?
        if let value = event["captureOrdinal"], !(value is NSNull) {
            guard let ordinal = integer(value), ordinal > 0 else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
            captureOrdinal = ordinal
            state.validCaptureOrdinalCount += 1
            state.captureOrdinals.insert(ordinal)
            state.maximumCaptureOrdinal = max(state.maximumCaptureOrdinal ?? ordinal, ordinal)
        } else {
            captureOrdinal = nil
            state.missingCaptureOrdinalCount += 1
        }

        if graph.chronology.status == "complete" {
            guard let eventID, let captureOrdinal else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
            if let previousOrdinal = state.previousCaptureOrdinal {
                guard captureOrdinal > previousOrdinal
                        || (captureOrdinal == previousOrdinal
                            && eventID > (state.previousEventID ?? "")) else {
                    throw ExperimentalConversationRecordError.malformedFrame
                }
            }
            state.previousCaptureOrdinal = captureOrdinal
            state.previousEventID = eventID
        }

        try validateActorReference(event, key: "agentId", graph: graph)
        try validateActorReference(event, key: "recipientAgentId", graph: graph)
        for key in ["spawnedAgentId", "completedAgentId"] {
            if let agentID = try optionalID(event, key), !graph.agentIDs.contains(agentID) {
                throw ExperimentalConversationRecordError.malformedFrame
            }
        }

        let workflowID = try optionalID(event, "workflowId")
        let phaseID = try optionalID(event, "phaseId")
        if let workflowID, !graph.workflowIDs.contains(workflowID) {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        if let phaseID {
            guard let phaseWorkflowID = graph.workflowByPhaseID[phaseID],
                  workflowID == phaseWorkflowID else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
        }

        for key in ["targetEventId", "replacementEventId", "producingEventId"] {
            if let reference = try optionalID(event, key) {
                guard reference != eventID else {
                    throw ExperimentalConversationRecordError.malformedFrame
                }
                try chargeRetainedSemantic([reference], state: &state)
                state.referencedEventIDs.append(reference)
            }
        }

        switch kind {
        case "tool_call":
            let toolUseID = try requiredID(event, "toolUseId")
            try chargeRetainedSemantic([toolUseID], state: &state)
            guard state.toolCalls.insert(toolUseID).inserted else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
        case "tool_result", "tool_terminal":
            let toolUseID = try requiredID(event, "toolUseId")
            try chargeRetainedSemantic([toolUseID], state: &state)
            state.toolReferences.insert(toolUseID)
        case "authorization_request", "question":
            let interactionID = try requiredID(event, "interactionId")
            try chargeRetainedSemantic([interactionID], state: &state)
            let type = kind == "question" ? "question" : "authorization"
            guard state.interactionTypes.updateValue(type, forKey: interactionID) == nil else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
        case "authorization_response", "authorization_ack":
            let interactionID = try requiredID(event, "interactionId")
            try chargeRetainedSemantic([interactionID], state: &state)
            state.interactionReferences.append(InteractionReference(
                id: interactionID,
                expectedType: "authorization"))
        case "answer", "answer_ack":
            let interactionID = try requiredID(event, "interactionId")
            try chargeRetainedSemantic([interactionID], state: &state)
            state.interactionReferences.append(InteractionReference(
                id: interactionID,
                expectedType: "question"))
        case "interaction_closed":
            let type = try requiredID(event, "interactionType")
            guard type == "authorization" || type == "question" else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
            let interactionID = try requiredID(event, "interactionId")
            try chargeRetainedSemantic([interactionID], state: &state)
            state.interactionReferences.append(InteractionReference(
                id: interactionID, expectedType: type))
        case "agent_spawn":
            let agentID = try requiredID(event, "spawnedAgentId")
            try chargeRetainedSemantic([agentID], state: &state)
            guard state.spawnedAgentIDs.insert(agentID).inserted else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
            if let correlationID = try optionalID(event, "toolUseId") {
                try chargeRetainedSemantic([correlationID, agentID], state: &state)
                guard state.spawnedAgentByCorrelationID.updateValue(
                    agentID, forKey: correlationID) == nil else {
                    throw ExperimentalConversationRecordError.malformedFrame
                }
            }
        case "agent_call_result":
            let agentID = try requiredID(event, "completedAgentId")
            try chargeRetainedSemantic([agentID], state: &state)
            guard state.completedAgentIDs.insert(agentID).inserted else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
            if let correlationID = try optionalID(event, "toolUseId") {
                try chargeRetainedSemantic([correlationID, agentID], state: &state)
                guard state.completedAgentByCorrelationID.updateValue(
                    agentID, forKey: correlationID) == nil else {
                    throw ExperimentalConversationRecordError.malformedFrame
                }
            }
        default:
            break
        }

        if boundedString(event["chronologyProvenance"], maximum: 128)
            == "degraded-legacy-summary" {
            state.legacySummaryEventCount += 1
        }
        if boundedString(event["stateProvenance"], maximum: 128)
            == "degraded-workflow-summary-without-event-ledger-match" {
            state.degradedWorkflowSummaryEventCount += 1
        }
    }

    private static func validateChronology(
        graph: SemanticGraph,
        state: SemanticEvents
    ) throws {
        let chronology = graph.chronology
        guard chronology.eventCount == state.count,
              state.duplicateEventIDCount == 0 else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        if chronology.status == "complete" {
            let expectedMaximum: Int? = state.count == 0 ? nil : state.maximumCaptureOrdinal
            guard state.missingEventIDCount == 0,
                  state.missingCaptureOrdinalCount == 0,
                  chronology.maximumCaptureOrdinal == expectedMaximum,
                  chronology.captureBatchCount == state.captureOrdinals.count else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
        } else {
            guard chronology.capturedOrdinalEventCount == state.validCaptureOrdinalCount,
                  let missingOrdinals = chronology.missingCaptureOrdinalEventCount,
                  let invalidOrdinals = chronology.invalidCaptureOrdinalEventCount,
                  missingOrdinals + invalidOrdinals == state.missingCaptureOrdinalCount,
                  chronology.stableEventIDEventCount == state.count - state.missingEventIDCount,
                  chronology.missingStableEventIDEventCount == state.missingEventIDCount,
                  chronology.duplicateStableEventIDEventCount == state.duplicateEventIDCount,
                  chronology.legacySummaryEventCount == state.legacySummaryEventCount else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
            if let value = chronology.degradedWorkflowSummaryEventCount {
                guard value == state.degradedWorkflowSummaryEventCount else {
                    throw ExperimentalConversationRecordError.malformedFrame
                }
            } else if state.degradedWorkflowSummaryEventCount != 0 {
                throw ExperimentalConversationRecordError.malformedFrame
            }
        }
    }

    private static func validateLifecycleReferences(
        state: SemanticEvents
    ) throws {
        guard state.referencedEventIDs.allSatisfy(state.eventIDs.contains),
              state.toolReferences.isSubset(of: state.toolCalls),
              state.interactionReferences.allSatisfy({
                  state.interactionTypes[$0.id] == $0.expectedType
              }),
              state.completedAgentIDs.isSubset(of: state.spawnedAgentIDs) else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        for (correlationID, agentID) in state.completedAgentByCorrelationID {
            guard state.spawnedAgentByCorrelationID[correlationID] == agentID else {
                throw ExperimentalConversationRecordError.malformedFrame
            }
        }
    }

    static func validate(_ url: URL) throws -> ExperimentalConversationRecordReport {
        try read(url, collectInspection: false, isCancelled: { false }).report
    }

    static func inspect(
        _ url: URL,
        isCancelled: () -> Bool = { false }
    ) throws -> ExperimentalConversationRecordInspection {
        guard let inspection = try read(
            url, collectInspection: true, isCancelled: isCancelled).inspection else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        return inspection
    }

    private static func read(
        _ url: URL,
        collectInspection: Bool,
        isCancelled: () -> Bool
    ) throws -> ReadResult {
        let startedAt = ProcessInfo.processInfo.systemUptime
        try checkBudget(startedAt: startedAt, isCancelled: isCancelled)
        let descriptor = url.withUnsafeFileSystemRepresentation { fileSystemPath -> Int32 in
            guard let fileSystemPath else { return -1 }
            return Darwin.open(
                fileSystemPath,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var initialStatus = stat()
        guard fstat(handle.fileDescriptor, &initialStatus) == 0 else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        guard initialStatus.st_mode & S_IFMT == S_IFREG else {
            throw ExperimentalConversationRecordError.notRegularFile
        }
        let rawFileSize = initialStatus.st_size
        guard rawFileSize >= 0, rawFileSize <= off_t(maximumRecordBytes) else {
            throw ExperimentalConversationRecordError.fileTooLarge
        }
        let fileSize = Int(rawFileSize)
        guard fileSize >= prelude.count else {
            throw ExperimentalConversationRecordError.unsupportedPrelude
        }
        guard let actualPrelude = try readExactly(prelude.count, from: handle),
              actualPrelude == prelude else {
            throw ExperimentalConversationRecordError.unsupportedPrelude
        }

        var prefixHasher = SHA256()
        var wholeFileHasher = SHA256()
        prefixHasher.update(data: actualPrelude)
        wholeFileHasher.update(data: actualPrelude)
        var offset = prelude.count
        var nonCommitFrameCount = 0
        var eventCount = 0
        var manifest: SemanticManifest?
        var graph: SemanticGraph?
        var semanticEvents = SemanticEvents()
        var inspection: InspectionAccumulator? = collectInspection
            ? InspectionAccumulator()
            : nil
        var committed = false
        var committedContentDigest = ""

        while !committed {
            try checkBudget(startedAt: startedAt, isCancelled: isCancelled)
            let frameStart = offset
            guard offset <= fileSize else {
                throw ExperimentalConversationRecordError.fileChangedDuringValidation
            }
            let headerBytesRemaining = fileSize - offset
            guard headerBytesRemaining > 0 else {
                throw ExperimentalConversationRecordError.missingCommit
            }
            guard headerBytesRemaining >= 8 else {
                throw ExperimentalConversationRecordError.truncatedFrame
            }
            guard let header = try readExactly(8, from: handle) else {
                throw ExperimentalConversationRecordError.missingCommit
            }
            offset += header.count
            let payloadLength = Int(littleEndianUInt32(header, at: 0))
            guard payloadLength <= maximumFrameBytes else {
                throw ExperimentalConversationRecordError.oversizedFrame
            }
            guard payloadLength <= fileSize - offset else {
                throw ExperimentalConversationRecordError.truncatedFrame
            }
            guard let payload = try readExactly(payloadLength, from: handle) else {
                throw ExperimentalConversationRecordError.truncatedFrame
            }
            offset += payload.count
            wholeFileHasher.update(data: header)
            wholeFileHasher.update(data: payload)
            guard crc32(payload) == littleEndianUInt32(header, at: 4) else {
                throw ExperimentalConversationRecordError.checksumMismatch
            }
            try validateJSONComplexity(
                payload, startedAt: startedAt, isCancelled: isCancelled)
            guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let frameType = boundedString(object["frameType"], maximum: 64) else {
                throw ExperimentalConversationRecordError.malformedFrame
            }

            switch frameType {
            case "manifest":
                guard nonCommitFrameCount == 0, manifest == nil else {
                    throw ExperimentalConversationRecordError.unexpectedFrame(frameType)
                }
                manifest = try validateSemanticManifest(object, inspection: &inspection)
            case "graph":
                guard nonCommitFrameCount == 1, graph == nil,
                      let value = object["graph"] as? [String: Any] else {
                    throw ExperimentalConversationRecordError.unexpectedFrame(frameType)
                }
                let validatedGraph = try validateSemanticGraph(value, inspection: &inspection)
                semanticEvents.retainedSemanticBytes = validatedGraph.retainedSemanticBytes
                graph = validatedGraph
            case "event":
                guard nonCommitFrameCount >= 2,
                      let graph,
                      let event = object["event"] as? [String: Any] else {
                    throw ExperimentalConversationRecordError.unexpectedFrame(frameType)
                }
                try ingestSemanticEvent(event, graph: graph, state: &semanticEvents)
                ingestInspectionDialog(
                    event, eventOrdinal: semanticEvents.count, inspection: &inspection)
                eventCount += 1
            case "commit":
                guard manifest != nil, graph != nil,
                      integer(object["committedFrameCount"]) == nonCommitFrameCount,
                      integer(object["committedByteLength"]) == frameStart,
                      let expectedDigest = boundedString(
                        object["contentDigestSHA256"], maximum: 64),
                      isLowercaseHex(expectedDigest, count: 64) else {
                    throw ExperimentalConversationRecordError.commitMismatch
                }
                let actualDigest = hex(prefixHasher.finalize())
                guard expectedDigest == actualDigest else {
                    throw ExperimentalConversationRecordError.commitMismatch
                }
                committedContentDigest = actualDigest
                committed = true
                continue
            default:
                throw ExperimentalConversationRecordError.unexpectedFrame(frameType)
            }

            prefixHasher.update(data: header)
            prefixHasher.update(data: payload)
            nonCommitFrameCount += 1
        }

        guard let manifest, let graph,
              manifest.eventCount == eventCount,
              manifest.agentCount == graph.agentCount,
              manifest.workflowCount == graph.workflowCount,
              graph.recordLineageID == manifest.lineageID,
              graph.recordVersionID == manifest.versionID else {
            throw ExperimentalConversationRecordError.malformedFrame
        }
        try validateChronology(graph: graph, state: semanticEvents)
        try validateLifecycleReferences(state: semanticEvents)

        guard offset <= fileSize else {
            throw ExperimentalConversationRecordError.fileChangedDuringValidation
        }
        let trailingBytes = fileSize - offset
        var trailingBytesRemaining = trailingBytes
        while trailingBytesRemaining > 0 {
            try checkBudget(startedAt: startedAt, isCancelled: isCancelled)
            let chunkSize = min(trailingBytesRemaining, 1024 * 1024)
            guard let trailing = try readExactly(chunkSize, from: handle) else {
                throw ExperimentalConversationRecordError.fileChangedDuringValidation
            }
            wholeFileHasher.update(data: trailing)
            offset += trailing.count
            trailingBytesRemaining -= trailing.count
        }
        if let appended = try handle.read(upToCount: 1), !appended.isEmpty {
            throw ExperimentalConversationRecordError.fileChangedDuringValidation
        }
        var finalStatus = stat()
        var pathStatus = stat()
        guard fstat(handle.fileDescriptor, &finalStatus) == 0,
              lstat(url.path, &pathStatus) == 0,
              initialStatus.st_dev == finalStatus.st_dev,
              initialStatus.st_ino == finalStatus.st_ino,
              initialStatus.st_size == finalStatus.st_size,
              initialStatus.st_mtimespec.tv_sec == finalStatus.st_mtimespec.tv_sec,
              initialStatus.st_mtimespec.tv_nsec == finalStatus.st_mtimespec.tv_nsec,
              initialStatus.st_ctimespec.tv_sec == finalStatus.st_ctimespec.tv_sec,
              initialStatus.st_ctimespec.tv_nsec == finalStatus.st_ctimespec.tv_nsec,
              finalStatus.st_dev == pathStatus.st_dev,
              finalStatus.st_ino == pathStatus.st_ino,
              offset == fileSize else {
            throw ExperimentalConversationRecordError.fileChangedDuringValidation
        }
        let report = ExperimentalConversationRecordReport(
            formatVersion: 0,
            profile: manifest.profile,
            lineageID: manifest.lineageID,
            versionID: manifest.versionID,
            contentDigestSHA256: committedContentDigest,
            byteDigestSHA256: hex(wholeFileHasher.finalize()),
            bytes: fileSize,
            agents: manifest.agentCount,
            events: eventCount,
            chronology: graph.chronology.status,
            omissions: manifest.omissions,
            trailingUncommittedBytes: trailingBytes)
        let projectedInspection = inspection.map { accumulator in
            ExperimentalConversationRecordInspection(
                report: report,
                displayName: accumulator.displayName,
                exportedAt: accumulator.exportedAt,
                producerName: accumulator.producerName,
                producerVersion: accumulator.producerVersion,
                producerBuild: accumulator.producerBuild,
                producerSourceRevision: accumulator.producerSourceRevision,
                agents: accumulator.agents,
                dialog: accumulator.dialog,
                omittedAgentCount: accumulator.omittedAgentCount,
                omittedDialogEntryCount: accumulator.omittedDialogEntryCount,
                truncatedDialogEntryCount: accumulator.truncatedDialogEntryCount,
                replacedControlCharacterCount: accumulator.replacedControlCharacterCount)
        }
        return ReadResult(report: report, inspection: projectedInspection)
    }
}

enum ExperimentalConversationRecordExporter {
    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            size = Int64(status.st_size)
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }

        /// Moving a file changes ctime even when its inode and bytes are untouched. Everything else
        /// here must remain identical across the staging-to-destination rename.
        func matchesContentBeforeRename(_ other: FileIdentity) -> Bool {
            device == other.device
                && inode == other.inode
                && size == other.size
                && modifiedSeconds == other.modifiedSeconds
                && modifiedNanoseconds == other.modifiedNanoseconds
        }
    }

#if DEBUG
    enum PublicationTestStage { case beforeExclusiveRename, afterExclusiveRename }
    static var publicationTestHook: ((PublicationTestStage, URL, URL) -> Void)?
#endif

    private struct RecoveryReceipt: Codable {
        let schemaVersion: Int
        let ownerPID: Int32
        let sourceRootPath: String
        let stagingRootPath: String
        let stagingToken: String
    }

    private static let queue = DispatchQueue(
        label: "ai.mechanician.experimental-convrec-export",
        qos: .userInitiated)
    private static let processLock = NSLock()
    private static var activeProcess: Process?
    private static var cancellationRequested = false

    private static var privateTemporaryBase: URL {
        let suffix = NSClassFromString("XCTestCase") == nil
            ? MechanicianEnvironment.supportDirectoryName(for: Bundle.main.bundleIdentifier)
            : "xctest-\(ProcessInfo.processInfo.processIdentifier)"
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "Mechanician Convrec Export-\(suffix)", isDirectory: true)
    }

    private static var recoveryReceiptURL: URL {
        if NSClassFromString("XCTestCase") != nil {
            return privateTemporaryBase.appendingPathComponent("recovery.json", isDirectory: false)
        }
        let base = MechanicianEnvironment.currentSupportRoot()
        return base.appendingPathComponent(
            "experimental-convrec-export-recovery.json", isDirectory: false)
    }

    private static func throwIfCancelled() throws {
        processLock.lock()
        let cancelled = cancellationRequested
        processLock.unlock()
        if cancelled { throw ExperimentalConversationRecordError.exporterCancelled }
    }

    /// Remove crash-left private source/staging material before this process can begin a new export.
    /// A receipt is published and fsynced before either sensitive location is created.
    static func recoverAbandonedExports() {
        queue.sync { recoverAbandonedExportIfNeeded() }
    }

    /// Quit owns the same cleanup promise as a completed export: stop the child, then wait for the
    /// serial export scope to remove its private source and sibling validation candidate.
    static func cancelAndWaitForExports() {
        processLock.lock()
        cancellationRequested = true
        let process = activeProcess
        processLock.unlock()
        if process?.isRunning == true { process?.terminate() }
        queue.sync {}
    }

    @MainActor
    static func export(
        conversation: Conversation,
        profile: ExperimentalConversationRecordProfile,
        destination: URL,
        completion: @escaping @MainActor (
            Result<ExperimentalConversationRecordReport, Error>
        ) -> Void
    ) {
        queue.async {
            let result: Result<ExperimentalConversationRecordReport, Error>
            do {
                result = .success(try exportSynchronously(
                    conversation: conversation,
                    profile: profile,
                    destination: destination))
            } catch {
                result = .failure(error)
            }
            Task { @MainActor in completion(result) }
        }
    }

    static func exportSynchronously(
        conversation: Conversation,
        profile: ExperimentalConversationRecordProfile,
        destination: URL
    ) throws -> ExperimentalConversationRecordReport {
        try throwIfCancelled()
        let runtime = try resolveRuntime()
        recoverAbandonedExportIfNeeded()
        let stagingToken = UUID().uuidString
        let stagingRoot = destination.deletingLastPathComponent().appendingPathComponent(
            ".mechanician-convrec-export-\(stagingToken)", isDirectory: true)
        let staging = stagingRoot.appendingPathComponent("candidate.convrec", isDirectory: false)
        let root = privateTemporaryBase.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let receipt = RecoveryReceipt(
            schemaVersion: 1,
            ownerPID: ProcessInfo.processInfo.processIdentifier,
            sourceRootPath: root.path,
            stagingRootPath: stagingRoot.path,
            stagingToken: stagingToken)
        try persistRecoveryReceipt(receipt)
        defer { cleanUpExport(receipt) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let source = root.appendingPathComponent("source.json", isDirectory: false)
        try throwIfCancelled()
        let sourceData = try ConversationStore.makeEncoder().encode(conversation)
        try sourceData.write(to: source, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)

        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
        let process = Process()
        process.executableURL = runtime.node
        process.arguments = [
            runtime.script.path,
            "--source", source.path,
            "--destination", staging.path,
            "--profile", profile.rawValue,
            "--producer-version", version,
            "--producer-build", build,
            "--producer-source", BuildProvenance.current?.sourceCommit ?? "unknown",
        ]
        // Files avoid the classic waitUntilExit-before-pipe-drain deadlock. They live inside the
        // private 0700 export scope, are read with a hard cap, and disappear on every exit path.
        let outputURL = root.appendingPathComponent("report.json")
        let errorURL = root.appendingPathComponent("error.log")
        _ = FileManager.default.createFile(
            atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        _ = FileManager.default.createFile(
            atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try throwIfCancelled()
        processLock.lock()
        activeProcess = process
        let cancelledBeforeLaunch = cancellationRequested
        processLock.unlock()
        guard !cancelledBeforeLaunch else {
            processLock.lock()
            if activeProcess === process { activeProcess = nil }
            processLock.unlock()
            throw ExperimentalConversationRecordError.exporterCancelled
        }
        do {
            try process.run()
        } catch {
            processLock.lock()
            if activeProcess === process { activeProcess = nil }
            processLock.unlock()
            throw error
        }
        processLock.lock()
        let cancelledAfterLaunch = cancellationRequested
        processLock.unlock()
        if cancelledAfterLaunch, process.isRunning { process.terminate() }
        let timedOut = terminated.wait(timeout: .now() + 120) == .timedOut
        if timedOut, process.isRunning {
            process.terminate()
            if terminated.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 2)
            }
        }
        process.waitUntilExit()
        processLock.lock()
        if activeProcess === process { activeProcess = nil }
        processLock.unlock()
        try? outputHandle.close()
        try? errorHandle.close()
        let stdout = try readPrefix(of: outputURL, maximumBytes: 256 * 1024)
        let stderr = try readPrefix(of: errorURL, maximumBytes: 8 * 1024)
        try throwIfCancelled()
        if timedOut { throw ExperimentalConversationRecordError.exporterTimedOut }
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.prefix(2_048), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "unknown error"
            throw ExperimentalConversationRecordError.exporterFailed(message)
        }
        let writerReport = try JSONDecoder().decode(
            ExperimentalConversationRecordReport.self, from: stdout)
        try throwIfCancelled()
        let independentReport = try ExperimentalConversationRecordValidator.validate(staging)
        guard writerReport.formatVersion == independentReport.formatVersion,
              writerReport.profile == independentReport.profile,
              writerReport.lineageID == independentReport.lineageID,
              writerReport.versionID == independentReport.versionID,
              writerReport.contentDigestSHA256 == independentReport.contentDigestSHA256,
              writerReport.byteDigestSHA256 == independentReport.byteDigestSHA256,
              writerReport.events == independentReport.events else {
            throw ExperimentalConversationRecordError.commitMismatch
        }
        let validatedStagingIdentity = try fileIdentity(at: staging)
        // Hold the cancellation lock across the publication point. Quit either marks cancellation
        // first (and this export cannot publish) or waits until the exclusive rename, final
        // validation, and directory sync have completed. RENAME_EXCL also makes a destination that
        // appeared after the save panel a refusal, never an overwrite.
        processLock.lock()
        defer { processLock.unlock() }
        guard !cancellationRequested else {
            throw ExperimentalConversationRecordError.exporterCancelled
        }
        var publishedIdentity: FileIdentity?
        do {
#if DEBUG
            publicationTestHook?(.beforeExclusiveRename, staging, destination)
#endif
            try publishExclusively(staging: staging, destination: destination)
            let actualPublishedIdentity = try fileIdentity(at: destination)
            publishedIdentity = actualPublishedIdentity
            guard actualPublishedIdentity.matchesContentBeforeRename(validatedStagingIdentity) else {
                throw ExperimentalConversationRecordError.publicationMismatch
            }
#if DEBUG
            publicationTestHook?(.afterExclusiveRename, staging, destination)
#endif
            let finalReport = try ExperimentalConversationRecordValidator.validate(destination)
            let finalIdentity = try fileIdentity(at: destination)
            guard finalIdentity == actualPublishedIdentity,
                  finalReport == independentReport else {
                throw ExperimentalConversationRecordError.publicationMismatch
            }
            var report = finalReport
            report.publicationWarning = synchronizeParentDirectory(of: destination)
            return report
        } catch {
            if let publishedIdentity {
                removePublishedCandidateIfUnchanged(destination, identity: publishedIdentity)
            }
            throw error
        }
    }

    private static func fileIdentity(at url: URL) throws -> FileIdentity {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw ExperimentalConversationRecordError.notRegularFile
        }
        return FileIdentity(status)
    }

    private static func publishExclusively(staging: URL, destination: URL) throws {
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST {
                throw ExperimentalConversationRecordError.destinationAlreadyExists
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    /// A failed final verification removes only the exact inode and metadata snapshot Mechanician
    /// published. If another writer replaced or edited it, their bytes remain untouched for repair.
    private static func removePublishedCandidateIfUnchanged(
        _ destination: URL,
        identity: FileIdentity
    ) {
        guard (try? fileIdentity(at: destination)) == identity else { return }
        try? FileManager.default.removeItem(at: destination)
        _ = synchronizeParentDirectory(of: destination)
    }

    private static func persistRecoveryReceipt(_ receipt: RecoveryReceipt) throws {
        let url = recoveryReceiptURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(receipt)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try synchronizeRequired(url)
        try synchronizeRequired(url.deletingLastPathComponent())
    }

    private static func synchronizeRequired(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func recoverAbandonedExportIfNeeded() {
        let url = recoveryReceiptURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= 64 * 1024,
              let data = try? Data(contentsOf: url),
              let receipt = try? JSONDecoder().decode(RecoveryReceipt.self, from: data),
              receipt.schemaVersion == 1 else { return }
        if receipt.ownerPID != ProcessInfo.processInfo.processIdentifier,
           Darwin.kill(receipt.ownerPID, 0) == 0 {
            return
        }
        cleanUpExport(receipt)
    }

    private static func cleanUpExport(_ receipt: RecoveryReceipt) {
        let fileManager = FileManager.default
        let sourceRoot = URL(fileURLWithPath: receipt.sourceRootPath, isDirectory: true)
        if isOwnedSourceRoot(sourceRoot) { try? fileManager.removeItem(at: sourceRoot) }
        let stagingRoot = URL(fileURLWithPath: receipt.stagingRootPath, isDirectory: true)
        if isOwnedStagingRoot(stagingRoot, token: receipt.stagingToken) {
            try? fileManager.removeItem(at: stagingRoot)
        }
        guard !fileManager.fileExists(atPath: sourceRoot.path),
              !fileManager.fileExists(atPath: stagingRoot.path) else { return }
        try? fileManager.removeItem(at: recoveryReceiptURL)
        try? synchronizeRequired(recoveryReceiptURL.deletingLastPathComponent())
    }

    private static func isOwnedSourceRoot(_ url: URL) -> Bool {
        guard url.deletingLastPathComponent().standardizedFileURL
                == privateTemporaryBase.standardizedFileURL,
              UUID(uuidString: url.lastPathComponent) != nil else { return false }
        return isOwnedDirectory(url)
    }

    private static func isOwnedStagingRoot(_ url: URL, token: String) -> Bool {
        guard UUID(uuidString: token) != nil,
              url.lastPathComponent == ".mechanician-convrec-export-\(token)",
              isOwnedDirectory(url),
              let children = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil),
              children.allSatisfy({ $0.lastPathComponent == "candidate.convrec" }) else {
            return false
        }
        return children.allSatisfy(isOwnedRegularFile)
    }

    private static func isOwnedDirectory(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
            && status.st_mode & S_IFMT == S_IFDIR
            && status.st_uid == geteuid()
    }

    private static func isOwnedRegularFile(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
            && status.st_mode & S_IFMT == S_IFREG
            && status.st_uid == geteuid()
            && status.st_nlink == 1
    }

    /// APFS confirms the final filename through directory fsync. Some remote/file-provider volumes
    /// reject directory fsync; preserve the successfully validated export but surface that reduced
    /// power-loss assurance instead of silently claiming the same durability.
    private static func synchronizeParentDirectory(of destination: URL) -> String? {
        let directory = destination.deletingLastPathComponent()
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            return "The volume did not allow Mechanician to open the destination directory for a durability check."
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            return "The volume did not confirm the final filename durably; validate the file before relying on it after a power loss."
        }
        return nil
    }

    private static func readPrefix(of url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: maximumBytes) ?? Data()
    }

    private struct Runtime {
        let node: URL
        let script: URL
    }

    private static func resolveRuntime() throws -> Runtime {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        if let resources = Bundle.main.resourceURL {
            let bundledNode = resources.appendingPathComponent("node")
            let bundledScript = resources.appendingPathComponent(
                "agentd/src/convrec/export-experimental.mjs")
            if fileManager.isExecutableFile(atPath: bundledNode.path),
               fileManager.fileExists(atPath: bundledScript.path) {
                return Runtime(node: bundledNode, script: bundledScript)
            }
        }
        // Environment and checkout resolution are explicit development/test seams only. A public
        // or tenant build runs signed bundled bytes and never executes launch-environment code.
        let allowsDevelopmentRuntime = Bundle.main.bundleIdentifier
            == MechanicianEnvironment.devBundleIdentifier
            || Bundle.main.bundleIdentifier == nil
            || NSClassFromString("XCTestCase") != nil
        guard allowsDevelopmentRuntime else {
            throw ExperimentalConversationRecordError.runtimeUnavailable
        }
        let nodeCandidates = [
            environment["MECHANICIAN_NODE"].map { URL(fileURLWithPath: $0) },
            URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node"),
            URL(fileURLWithPath: "/usr/bin/node"),
        ].compactMap { $0 }
        let scriptCandidates = [
            environment["MECHANICIAN_CONVREC_EXPORTER"].map { URL(fileURLWithPath: $0) },
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("agentd/src/convrec/export-experimental.mjs"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .deletingLastPathComponent()
                .appendingPathComponent("agentd/src/convrec/export-experimental.mjs"),
        ].compactMap { $0 }
        guard let node = nodeCandidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }), let script = scriptCandidates.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) else {
            throw ExperimentalConversationRecordError.runtimeUnavailable
        }
        return Runtime(node: node, script: script)
    }
}
