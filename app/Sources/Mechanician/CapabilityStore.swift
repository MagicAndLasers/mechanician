import SwiftUI
import AppKit

/// The capability store — one `<uuid>.json` per capability under `<support>/capabilities/`,
/// mirroring ArtifactStore. The daemon writes back `verification`/`runCount` on each save/run;
/// a directory watcher reloads those live. Honors MECHANICIAN_SUPPORT_DIR (dev/stable isolation).
@MainActor
final class CapabilityStore: ObservableObject {
    static let shared = CapabilityStore()

    @Published private(set) var capabilities: [Capability] = []

    private let io = DispatchQueue(label: "ai.mechanician.capability-io", qos: .utility)
    private var watch: DispatchSourceFileSystemObject?
    private var reloadPending = false
    /// Bumped by every main-actor mutation so a racing dir-watcher reload can't clobber a user
    /// toggle/delete with a stale disk snapshot (see ArtifactStore for the full rationale).
    private var mutationGeneration: UInt = 0

    private init() {
        seedIfNeeded()
        load()
        startWatching()
    }

    // MARK: paths

    private var supportBase: URL {
        return MechanicianEnvironment.currentSupportRoot()
    }
    private var dir: URL {
        let d = supportBase.appendingPathComponent("capabilities", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func fileURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }

    nonisolated private static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }
    // The daemon (Node) stamps fractional-second ISO dates, which Foundation's `.iso8601` rejects
    // on the macOS 13/14 floor — decode both forms. (Same gotcha as the artifact store.)
    //
    // `nonisolated` because `load()` builds the decoder on the `io` queue; the shared formatters are
    // safe to use from there (see SendableISO8601Formatter).
    nonisolated private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = SendableISO8601Formatter.fractional.date(from: s)
                ?? SendableISO8601Formatter.plain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad ISO8601: \(s)"))
        }
        return d
    }

    // MARK: load / persist

    func load() {
        let dir = self.dir
        let capturedGeneration = mutationGeneration
        io.async { [weak self] in
            let dec = Self.decoder()
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            var list: [Capability] = []
            for f in files where f.pathExtension == "json" {
                guard let data = try? Data(contentsOf: f), let c = try? dec.decode(Capability.self, from: data) else { continue }
                list.append(c)
            }
            let sorted = list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            Task { @MainActor in
                guard let self, self.mutationGeneration == capturedGeneration else { return }
                self.capabilities = sorted
            }
        }
    }

    private func persist(_ c: Capability) {
        mutationGeneration &+= 1
        let url = fileURL(c.uuid), enc = Self.encoder()
        io.async { if let data = try? enc.encode(c) { try? data.write(to: url, options: .atomic) } }
    }

    // MARK: CRUD (UI side; the agent's SaveCapability writes JSON directly, picked up by the watcher)

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = capabilities.firstIndex(where: { $0.uuid == id }) else { return }
        capabilities[i].enabled = on; capabilities[i].updatedAt = Date()
        persist(capabilities[i])
    }

    func delete(_ id: UUID) {
        mutationGeneration &+= 1
        capabilities.removeAll { $0.uuid == id }
        let url = fileURL(id)
        io.async { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: seed the flagship on first launch

    private func seedIfNeeded() {
        let marker = dir.appendingPathComponent(".seeded-v1")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        var cap = Capability(
            name: "add_to_reminders",
            title: "Add to Reminders",
            description: "Add an item to the macOS Reminders app. Use when the user wants a reminder or a to-do added.",
            mechanism: .appleScript,
            target: Target(appName: "Reminders", bundleID: "com.apple.reminders"),
            params: [
                CapabilityParam(name: "title", title: "Title", type: "string", optional: false,
                                description: "the reminder text"),
                CapabilityParam(name: "due", title: "Due", type: "date", optional: true,
                                description: "optional due date/time (ISO8601 or natural language)"),
            ],
            backing: Backing(language: "javascript", script: Self.remindersJXA),
            safety: .additive, origin: "user")
        cap.verification.state = "untested"
        if let data = try? Self.encoder().encode(cap) { try? data.write(to: fileURL(cap.uuid)) }
        FileManager.default.createFile(atPath: marker.path, contents: Data())
    }

    // JXA reads a single argv[0] = JSON string of the arguments (never interpolated into source).
    private static let remindersJXA = """
    function run(argv) {
      const args = JSON.parse(argv[0] || '{}');
      const app = Application('Reminders');
      const props = { name: args.title || 'Untitled reminder' };
      if (args.due) { const d = new Date(args.due); if (!isNaN(d)) props.dueDate = d; }
      const list = app.defaultList();
      const r = app.Reminder(props);
      list.reminders.push(r);
      return 'Added reminder: ' + props.name;
    }
    """

    // MARK: directory watch (daemon write-backs of verification/runCount)

    private func startWatching() {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        src.setEventHandler { [weak self] in self?.debouncedReload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watch = src
    }
    private func debouncedReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.reloadPending = false; self?.load()
        }
    }
}
