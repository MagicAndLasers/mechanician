import SwiftUI

/// What the app keeps a copy of, how many, and what that costs.
///
/// **This exists because it silently stopped.** The daily backup's only callers lived inside the
/// migration, and retiring the migration took them with it — for fifteen days nothing copied a
/// library that holds every conversation, and there was no surface
/// anywhere that would have shown it. A backup nobody can see the state of is a backup nobody can
/// tell has stopped.
///
/// So the numbers here are read from DISK rather than from a receipt: a receipt says what the app
/// believes, and what a person needs is what is actually there.
struct LibraryBackupSettingsSection: View {
    @State private var enabled = LibraryBackupSettings.isEnabled()
    @State private var generations = LibraryBackupSettings.generations()
    @State private var usage: LibraryBackupSettings.Usage?
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        Section("Backups") {
            Toggle("Keep daily copies of your library", isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    LibraryBackupSettings.setEnabled(on)
                }
            Text("One copy a day, taken shortly after launch. It holds your conversations and the files they refer to.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Keep", selection: $generations) {
                ForEach(LibraryBackupSettings.choices, id: \.self) { count in
                    // Days, because that is the unit the cadence is in. "3 copies" invites the
                    // question this answers.
                    Text(count == 1 ? "the last day" : "the last \(count) days").tag(count)
                }
            }
            .disabled(!enabled)
            .onChange(of: generations) { _, count in
                LibraryBackupSettings.setGenerations(count)
            }

            // THE NUMBER THAT MAKES THE CHOICE INFORMED. Most of a copy is not the database: on a
            // real library it is 651 MB of database and 1.7 GB of retained files, and the files are
            // written into every copy rather than shared between them.
            (usage.map { current in
                current.isEmpty
                    ? Text("No copy has been made yet.")
                    : Text("\(current.generations == 1 ? "1 copy" : "\(current.generations) copies") using \(onDisk(current.bytes))\(current.newest.map { ", newest \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "").")
            } ?? Text("Checking what is on disk…"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // A DATE ON THE LINE ABOVE IS NOT PROOF THE SCHEDULE IS RUNNING. It is the newest copy
            // on disk, and it reads exactly the same whether the last attempt succeeded or threw. On
            // a real machine every daily attempt failed and this panel said "newest 5 August" in a
            // steady voice for sixteen days.
            if let failure = LibraryBackupSettings.lastFailure() {
                Label {
                    Text("The last attempt, \(failure.at.formatted(date: .abbreviated, time: .shortened)), did not finish: \(failure.reason)")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.nWarningText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button(busy ? "Backing up…" : "Back up now") { backUpNow() }
                    .buttonStyle(PillButtonStyle(kind: .accent))
                    .accessibilityLabel(busy ? "Backing up library" : "Back up library now")
                    .disabled(busy)
                Button("Show in Finder") { reveal() }
                    .buttonStyle(PillButtonStyle(kind: .plain))
                    .accessibilityLabel("Show backups in Finder")
                    .disabled(usage?.isEmpty != false)
            }

            if let problem {
                // Interpolated at the Text rather than assembled into a String first, or the whole
                // line becomes a variable a translator can never reach.
                Text("Could not back up: \(problem)")
                    .font(.caption).foregroundStyle(Color.nWarningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { refresh() }
    }

    /// NOT named `…Text`. The localization counter looks for a SwiftUI text view built from a
    /// variable by matching `Text(<identifier>)`, and a helper whose name ends in those four letters
    /// matches it at every call site — which is a note this codebase already wrote once, about a
    /// different helper, and which I walked straight into.
    private func onDisk(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var backupRoot: URL {
        LibraryBackupLifecycle.backupRoot(
            for: StorageAuthorityBootstrap.current.effectiveSupportRoot)
    }

    /// Off the main actor. Measuring a folder of retained files is a walk over many thousands of
    /// them, and a settings pane that stalls while it counts is worse than one that says it is
    /// counting.
    private func refresh() {
        let root = StorageAuthorityBootstrap.current.effectiveSupportRoot
        Task.detached(priority: .utility) {
            let measured = LibraryBackupSettings.usage(for: root)
            await MainActor.run { usage = measured }
        }
    }

    private func backUpNow() {
        busy = true
        problem = nil
        LibraryBackupLauncher.backUpNow { result in
            busy = false
            switch result {
            case .success:
                refresh()
            case let .failure(error):
                // Named, not swallowed. Fifteen days of not backing up produced no message at all,
                // which is exactly how it went unnoticed.
                problem = error.localizedDescription
            }
        }
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([backupRoot])
    }
}
