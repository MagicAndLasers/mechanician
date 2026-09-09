import Foundation

enum HarnessMetricKind: String, Codable, CaseIterable, Hashable {
    case counter
    case gauge
    case histogram
}

enum HarnessMetricUnit: String, Codable, CaseIterable, Hashable {
    case count
    case tokens
    case milliseconds
    case seconds
    case unixSeconds = "unix_seconds"
    case bytes
    case usd
    case ratio
    case percent
    case lines
}

/// Closed attribute names keep provider telemetry from turning prompts, paths, session ids, tool
/// arguments, or arbitrary high-cardinality labels into an analytics surface.
enum HarnessMetricAttributeKey: String, Codable, CaseIterable, Hashable {
    case provider
    case access
    case model
    case lane
    case phase
    case event
    case outcome
    case status
    case scope
    case provenance
    case querySource = "query_source"
    case toolKind = "tool_kind"
    case errorKind = "error_kind"
    case transport
    case agentKind = "agent_kind"
    case safetyCategory = "safety_category"
    case threadAction = "thread_action"
    case outputKind = "output_kind"
    case retryAttempt = "retry_attempt"
    case warm
    case success
    case cached
}

enum HarnessMetricAttributeValue: Codable, Equatable, Hashable {
    case string(String)
    case bool(Bool)
    case number(Double)

    fileprivate var bounded: Self? {
        switch self {
        case .string(let value):
            return agentHarnessBoundedLabel(value, maximum: 128).map(Self.string)
        case .bool:
            return self
        case .number(let value):
            guard value.isFinite, abs(value) <= 1e18 else { return nil }
            return self
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self),
                  value.isFinite, abs(value) <= 1e18 {
            self = .number(value)
        } else if let raw = try? container.decode(String.self),
                  let value = agentHarnessBoundedLabel(raw, maximum: 128) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Metric attribute must be a bounded string, bool, or number.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        }
    }
}

/// Canonical identity for one metric stream. Attribute values remain typed so the string `"true"`,
/// the boolean `true`, and the number `1` can never collapse into the same runtime row. Sorting the
/// closed keys also makes dictionary insertion order irrelevant.
struct HarnessMetricSeriesIdentity: Hashable {
    struct Attribute: Hashable {
        var key: HarnessMetricAttributeKey
        var value: HarnessMetricAttributeValue
    }

    var harnessLaneID: AgentHarnessLaneID?
    var name: String
    var kind: HarnessMetricKind
    var unit: HarnessMetricUnit
    var attributes: [Attribute]
}

/// Account snapshots have independent replacement boundaries. Token usage owns three public name
/// prefixes because its summary contains token, turn-duration, and streak gauges.
enum HarnessMetricAccountFamily: Equatable {
    case rateLimits
    case tokenUsage

    func contains(_ sample: HarnessMetricSample) -> Bool {
        switch self {
        case .rateLimits:
            return sample.name.hasPrefix("codex.account.rate_limits.")
        case .tokenUsage:
            return sample.name.hasPrefix("codex.account.tokens.")
                || sample.name.hasPrefix("codex.account.turn.")
                || sample.name.hasPrefix("codex.account.streak.")
        }
    }
}

/// One bounded provider-neutral aggregate point. It intentionally carries no prompt, response,
/// path, tool argument/result, provider session id, or free-form error text. This makes it suitable
/// for a short-lived runtime ledger without quietly becoming a second transcript.
struct HarnessMetricSample: Identifiable, Codable, Equatable {
    private static let maximumAttributeCount = 16

    var id: UUID
    var name: String
    var kind: HarnessMetricKind
    var at: Date
    var unit: HarnessMetricUnit
    var harnessLaneID: AgentHarnessLaneID?
    var value: Double?
    var count: Int?
    var sum: Double?
    var min: Double?
    var max: Double?
    var attributes: [HarnessMetricAttributeKey: HarnessMetricAttributeValue]

    init?(
        id: UUID = UUID(),
        name: String,
        kind: HarnessMetricKind,
        at: Date = Date(),
        unit: HarnessMetricUnit,
        harnessLaneID: AgentHarnessLaneID? = nil,
        value: Double? = nil,
        count: Int? = nil,
        sum: Double? = nil,
        min: Double? = nil,
        max: Double? = nil,
        attributes: [HarnessMetricAttributeKey: HarnessMetricAttributeValue] = [:]
    ) {
        guard let name = agentHarnessBoundedToken(name, maximum: 160),
              [value, sum, min, max].compactMap({ $0 }).allSatisfy({
                  $0.isFinite && abs($0) <= 1e18
              }),
              count.map({ $0 >= 0 && $0 <= 1_000_000_000_000 }) != false,
              !(min != nil && max != nil && min! > max!),
              value != nil || count != nil || sum != nil || min != nil || max != nil
        else { return nil }

        var boundedAttributes: [HarnessMetricAttributeKey: HarnessMetricAttributeValue] = [:]
        for key in HarnessMetricAttributeKey.allCases {
            guard boundedAttributes.count < Self.maximumAttributeCount else { break }
            if let bounded = attributes[key]?.bounded {
                boundedAttributes[key] = bounded
            }
        }
        self.id = id
        self.name = name
        self.kind = kind
        self.at = at
        self.unit = unit
        self.harnessLaneID = harnessLaneID
        self.value = value
        self.count = count
        self.sum = sum
        self.min = min
        self.max = max
        self.attributes = boundedAttributes
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, at, unit, harnessLaneID, value, count, sum, min, max, attributes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawAttributes = (try? container.decodeIfPresent(
            [String: HarnessMetricAttributeValue].self, forKey: .attributes)) ?? [:]
        var typedAttributes: [HarnessMetricAttributeKey: HarnessMetricAttributeValue] = [:]
        for key in HarnessMetricAttributeKey.allCases {
            guard typedAttributes.count < Self.maximumAttributeCount else { break }
            if let value = rawAttributes[key.rawValue] {
                typedAttributes[key] = value
            }
        }
        guard let decoded = Self(
            id: (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
            name: try container.decode(String.self, forKey: .name),
            kind: try container.decode(HarnessMetricKind.self, forKey: .kind),
            at: (try? container.decodeIfPresent(Date.self, forKey: .at)) ?? Date(),
            unit: try container.decode(HarnessMetricUnit.self, forKey: .unit),
            harnessLaneID: (try? container.decodeIfPresent(
                AgentHarnessLaneID.self, forKey: .harnessLaneID)) ?? nil,
            value: try? container.decodeIfPresent(Double.self, forKey: .value),
            count: try? container.decodeIfPresent(Int.self, forKey: .count),
            sum: try? container.decodeIfPresent(Double.self, forKey: .sum),
            min: try? container.decodeIfPresent(Double.self, forKey: .min),
            max: try? container.decodeIfPresent(Double.self, forKey: .max),
            attributes: typedAttributes)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: container,
                debugDescription: "Harness metric sample is missing or exceeds its bounds.")
        }
        self = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(at, forKey: .at)
        try container.encode(unit, forKey: .unit)
        try container.encodeIfPresent(harnessLaneID, forKey: .harnessLaneID)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(count, forKey: .count)
        try container.encodeIfPresent(sum, forKey: .sum)
        try container.encodeIfPresent(min, forKey: .min)
        try container.encodeIfPresent(max, forKey: .max)
        let rawAttributes = Dictionary(uniqueKeysWithValues: attributes.map {
            ($0.key.rawValue, $0.value)
        })
        if !rawAttributes.isEmpty {
            try container.encode(rawAttributes, forKey: .attributes)
        }
    }

    var seriesIdentity: HarnessMetricSeriesIdentity {
        HarnessMetricSeriesIdentity(
            harnessLaneID: harnessLaneID,
            name: name,
            kind: kind,
            unit: unit,
            attributes: attributes
                .map { HarnessMetricSeriesIdentity.Attribute(key: $0.key, value: $0.value) }
                .sorted { $0.key.rawValue < $1.key.rawValue })
    }

    var isCodexAccountMetric: Bool {
        name.hasPrefix("codex.account.")
    }
}

/// The fields that make two observations byte-for-byte repeats for ledger purposes. Timestamp and
/// UUID deliberately remain outside this key: a repeated export refreshes those presentation facts
/// while replacing the prior equal point. Computing the canonical series identity once per sample
/// keeps batch application linear instead of sorting attributes inside a nested ledger scan.
private struct HarnessMetricLedgerValueIdentity: Hashable {
    var series: HarnessMetricSeriesIdentity
    var value: Double?
    var count: Int?
    var sum: Double?
    var min: Double?
    var max: Double?

    init(_ sample: HarnessMetricSample) {
        series = sample.seriesIdentity
        value = sample.value
        count = sample.count
        sum = sample.sum
        min = sample.min
        max = sample.max
    }
}

/// Apply one bounded runtime batch. A complete account snapshot first discards its whole family,
/// including gauges omitted because the provider cleared them. Ordinary runtime batches retain
/// changed points for the session trend while refreshing byte-for-byte repeated snapshots.
func agentHarnessUpdatedMetricLedger(
    _ existing: [HarnessMetricSample],
    appending samples: [HarnessMetricSample],
    replacingAccountFamily: HarnessMetricAccountFamily? = nil,
    maximumSamples: Int = 2_048
) -> [HarnessMetricSample] {
    guard maximumSamples > 0 else { return [] }
    let retainedExisting = replacingAccountFamily.map { family in
        existing.filter { !family.contains($0) }
    } ?? existing
    var removedExisting = Array(repeating: false, count: retainedExisting.count)
    var appended: [HarnessMetricSample] = []
    var removedAppended: [Bool] = []
    appended.reserveCapacity(min(512, samples.count))
    removedAppended.reserveCapacity(min(512, samples.count))

    // Locations use one logical index space: retained existing points first, then this batch. A
    // later equal point marks the previous latest point and takes its place, exactly matching the
    // old sequential remove-then-append behavior even when a batch repeats one series.
    var latestByValue: [HarnessMetricLedgerValueIdentity: Int] = [:]
    latestByValue.reserveCapacity(retainedExisting.count + min(512, samples.count))
    for (index, sample) in retainedExisting.enumerated() {
        latestByValue[HarnessMetricLedgerValueIdentity(sample)] = index
    }
    for sample in samples.prefix(512) {
        let identity = HarnessMetricLedgerValueIdentity(sample)
        if let previous = latestByValue[identity] {
            if previous < retainedExisting.count {
                removedExisting[previous] = true
            } else {
                removedAppended[previous - retainedExisting.count] = true
            }
        }
        latestByValue[identity] = retainedExisting.count + appended.count
        appended.append(sample)
        removedAppended.append(false)
    }

    var updated: [HarnessMetricSample] = []
    updated.reserveCapacity(retainedExisting.count + appended.count)
    for (index, sample) in retainedExisting.enumerated() where !removedExisting[index] {
        updated.append(sample)
    }
    for (index, sample) in appended.enumerated() where !removedAppended[index] {
        updated.append(sample)
    }
    if updated.count > maximumSamples {
        updated.removeFirst(updated.count - maximumSamples)
    }
    return updated
}

func agentHarnessMetricLedgerClearingCodexAccountSamples(
    _ samples: [HarnessMetricSample]
) -> [HarnessMetricSample] {
    samples.filter { !$0.isCodexAccountMetric }
}
