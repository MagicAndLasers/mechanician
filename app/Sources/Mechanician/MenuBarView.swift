import SwiftUI
import AppKit

/// The ambient-agent menu-bar extra — a persistent status item so the background agent is
/// reachable even with no window open: see the scheduled tasks, run one now, enable/disable,
/// pause everything, or jump to a new conversation / the Scheduled window. Reads the live
/// AmbientStore. This is the OS-resident face of "the agent that lives in your Mac."
struct AmbientMenuContent: View {
    @ObservedObject private var store = AmbientStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section("Ambient Agent") {
            if store.tasks.isEmpty {
                Text("No scheduled tasks")
                Button("Create a Scheduled Task…") { open("ambient") }
            } else {
                ForEach(store.tasks) { task in
                    Menu(menuLabel(task)) {
                        Button("Run Now") { store.runNow(task.id) }
                            .disabled(!task.hasSchedulableWorkspace)
                        Toggle("Enabled", isOn: Binding(
                            get: { task.isEffectivelyEnabled },
                            set: { store.setEnabled(task.id, $0) }))
                            .disabled(!task.hasSchedulableWorkspace)
                        Divider()
                        Text(task.triggerSummary)
                        if let next = nextRunText(task) { Text("Next: \(next)") }
                        if let last = task.lastRun { Text("Last run: \(last)") }
                    }
                }
            }
        }

        Divider()
        Button("New Conversation") { open("main") }
        Button("Scheduled & Ambient Tasks…") { open("ambient") }
        Button("Artifacts…") { open("artifacts") }
        Button("Extensions…") { open("extensions") }

        if store.tasks.contains(where: { $0.hasSchedulableWorkspace }) {
            Divider()
            if store.tasks.contains(where: {
                $0.hasSchedulableWorkspace && $0.isEffectivelyEnabled
            }) {
                Button("Pause All Tasks") { store.tasks.forEach { store.setEnabled($0.id, false) } }
            } else {
                Button("Resume All Tasks") { store.tasks.forEach { store.setEnabled($0.id, true) } }
            }
        }

        Divider()
        Button("Quit Mechanician") { NSApp.terminate(nil) }
    }

    private func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        // Workspace windows are hand-built (not a WindowGroup scene) so they all get the flush-left
        // toolbar; the utility windows are still SwiftUI scenes opened by id.
        if id == "main" {
            // Focus an existing workspace window instead of opening a duplicate that would re-restore
            // the same conversation; only make a new one if there is none.
            focusOrOpenWorkspaceAfterSessionRestore()
        } else if id == "projects" {
            // Choosing a Workspace can construct a window. Keep that decision behind saved-session
            // replay just like Dock, Spotlight, and File-menu ingress.
            performWorkspaceCreatingIngress { openWindow(id: id) }
        } else {
            openWindow(id: id)
        }
    }

    private func menuLabel(_ t: ScheduledTask) -> String {
        (t.isEffectivelyEnabled ? "" : "⏸ ") + t.name + "  —  " + t.triggerSummary
    }

    /// The daemon's next-run timestamp as a short time (or date+time if not today).
    private func nextRunText(_ t: ScheduledTask) -> String? {
        guard t.isEffectivelyEnabled, let ts = t.nextRun, ts > 0 else { return nil }
        let d = Date(timeIntervalSince1970: ts)
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = Calendar.current.isDateInToday(d) ? .none : .short
        return f.string(from: d)
    }
}
