import SwiftUI
import AppKit

/// Mac automation is intentionally separate from Connections. Saved capabilities are reusable
/// local behavior; App Actions is an experimental inventory of what installed apps expose.
struct CapabilitiesView: View {
    @State private var showAppActions = false

    var body: some View {
        // No second tab bar. This view is already inside Extensions' tab bar, so a nested one made
        // the same screen answer to three names — the tab said "Automation", the sub-tab said
        // "Library", the header said "Capabilities" — and two rows of pills competed for the same
        // job. App Actions is a discovery detour (browse what installed apps expose, then teach one
        // as a capability), not a peer destination, so it opens as a sheet from where you'd want it.
        CapabilityLibraryView(showAppActions: $showAppActions)
            .frame(minWidth: 780, minHeight: 500)
            .background(Color.nBg)
            .background(WindowConfigurator())
            .sheet(isPresented: $showAppActions) {
                VStack(spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("What your apps can do").font(.headline)
                            // The panel showed a list of app actions and never said what it was
                            // for. Nobody can guess that "Teach as capability" means "hand this to
                            // the agent, have it write and test a script, and save the result".
                            Text("Actions your installed apps publish. Pick one and the agent will "
                                 + "work out how to do it, test it, and save it as an automation.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 16)
                        Button("Done") { showAppActions = false }
                            .buttonStyle(PillButtonStyle(kind: .accent))
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(12)
                    Divider()
                    AppCapabilitiesView()
                }
                .frame(minWidth: 820, minHeight: 560)
                .background(Color.nBg)
            }
    }

}

/// The Library tab — the saved macOS "verbs" the agent can run. Two panes: the list of
/// capabilities with a verification dot, and a detail view (what it does, params, the script,
/// health). Capabilities are created by the agent (SaveCapability) during a conversation; this
/// tab is where you see, trust, and prune them.
struct CapabilityLibraryView: View {
    @Binding var showAppActions: Bool
    @ObservedObject private var store = CapabilityStore.shared
    @ObservedObject private var runner = CapabilityRunner.shared
    @ObservedObject private var active = ActiveWorkspace.shared
    @State private var selected: UUID?
    @State private var search = ""
    @State private var showDelete = false
    /// Argument text per capability, so switching selection and coming back keeps what you typed.
    @State private var arguments: [UUID: [String: String]] = [:]

    private var filtered: [Capability] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.capabilities }
        return store.capabilities.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.name.localizedCaseInsensitiveContains(q)
                || $0.description.localizedCaseInsensitiveContains(q)
        }
    }
    private var current: Capability? { store.capabilities.first { $0.uuid == selected } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) { header; Divider(); if filtered.isEmpty { empty } else { list } }
                .frame(minWidth: 260)
            detail.frame(minWidth: 420)
        }
        .onAppear { store.load() }
        .confirmationDialog("Delete this capability?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let id = selected { store.delete(id); selected = nil } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The agent will no longer be able to run it. You can re-teach it anytime.") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                // NOT "13 things your agent can do on this Mac" — that was my copy and it was
                // false. It reads as a ceiling, when the agent can drive any scriptable app and
                // run any Shortcut on demand. These are SAVED verbs: quicker, already tested, and
                // approved once instead of every time. The distinction is the whole mental model,
                // so it is stated here rather than left to be inferred from an empty-ish list.
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.capabilities.isEmpty
                         ? "No saved automations yet"
                         : "\(store.capabilities.count) saved automation\(store.capabilities.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Your agent can also automate any app on demand. These are the ones it remembers.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Button { showAppActions = true } label: {
                    Label("Add from an app", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(Color.nInfoText)
                .help("Browse the actions your installed apps publish, and have the agent turn one into a saved automation")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .cardSurface(cornerRadius: 7)
        }
        .padding(10)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "wand.and.stars").font(.system(size: 26)).foregroundStyle(.tertiary)
            Text("No capabilities yet.\nAsk the agent to do something on your Mac, then say \u{201C}save that as a capability.\u{201D}")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
    }

    private var list: some View {
        List(selection: $selected) {
            ForEach(filtered) { c in
                HStack(spacing: 8) {
                    appIcon(c).resizable().frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title).lineLimit(1)
                        // What it does, in the user's language. The snake_case name is the key an
                        // agent invokes it by — real, but implementation vocabulary, and it was
                        // occupying the one line that could have answered "what is this?".
                        // It moves to the detail pane, where someone writing a prompt can find it.
                        Text(c.description.isEmpty ? c.name : c.description)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    verificationDot(c.verification.state)
                    if !c.enabled { Text("off").font(.caption2).foregroundStyle(.secondary) }
                }
                .tag(c.uuid)
                .help(c.description)
            }
        }
        .listStyle(.inset).scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var detail: some View {
        if let c = current {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        appIcon(c).resizable().frame(width: 38, height: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(.title3.weight(.semibold))
                            HStack(spacing: 6) {
                                badge(c.mechanism.rawValue == "appleScript" ? "AppleScript" : c.mechanism.rawValue, .nAccent)
                                if let t = c.target?.appName { badge(t, .secondary) }
                                badge(c.safety.rawValue, c.safety == .destructive ? .red : .secondary)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { c.enabled }, set: { store.setEnabled(c.uuid, $0) }))
                            .toggleStyle(.switch).labelsHidden().help(c.enabled ? "Enabled" : "Disabled")
                            .accessibilityLabel("Enable capability")
                    }
                    Text(c.description).foregroundStyle(.secondary)

                    // Health
                    HStack(spacing: 6) {
                        verificationDot(c.verification.state)
                        Text(healthText(c)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let err = c.verification.lastError, !err.isEmpty {
                        Text(err).font(.caption2.monospaced())
                            .foregroundStyle(Color.nErrorText).lineLimit(3)
                    }

                    runSection(c)

                    askInChat(c)

                    // The script is the least-used thing on this pane and was the largest, sitting
                    // between the Run button and everything else. Collapsed by default: it matters
                    // when you are auditing what a verb really does, not when you are using it.
                    DisclosureGroup {
                        Text(c.backing.script ?? "(no script)")
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.nSurface))
                    } label: {
                        Text(c.backing.language == "javascript"
                             ? "Show the script (JXA)" : "Show the script (AppleScript)")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    HStack {
                        Text(c.runCount == 0 ? "Never run" : "Run \(c.runCount) time\(c.runCount == 1 ? "" : "s")")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button { showDelete = true } label: { Label("Delete", systemImage: "trash") }
                            .buttonStyle(PillButtonStyle(kind: .destructive))
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a capability").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: run

    /// Fill in the arguments and run it, right here. The library was previously the only screen in
    /// the app dedicated to capabilities and the only place you could not invoke one — the sole
    /// affordance was asking an agent in chat to call it by name.
    @ViewBuilder
    private func runSection(_ c: Capability) -> some View {
        let isRunning = runner.running == c.name
        let busyElsewhere = runner.running != nil && !isRunning
        let missing = c.params.filter {
            !$0.optional
                && binding(c, $0.name).wrappedValue
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        sectionLabel(c.params.isEmpty ? "Run" : "Parameters")

        VStack(alignment: .leading, spacing: 8) {
            ForEach(c.params, id: \.name) { p in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(p.title.isEmpty ? p.name : p.title).font(.system(size: 12, weight: .medium))
                        Text(p.name).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.nInfoText)
                        if p.optional { Text("optional").font(.caption2).foregroundStyle(.tertiary) }
                    }
                    TextField(p.description.isEmpty ? p.type : p.description,
                              text: binding(c, p.name))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .accessibilityLabel("\(p.title.isEmpty ? p.name : p.title) — \(p.description)")
                }
            }

            HStack(spacing: 10) {
                Button {
                    runner.run(c, arguments: arguments[c.uuid] ?? [:], bridge: active.bridge)
                } label: {
                    Label(isRunning ? "Running…" : "Run",
                          systemImage: isRunning ? "hourglass" : "play.fill")
                }
                .buttonStyle(PillButtonStyle(kind: c.safety == .destructive ? .destructive : .accent))
                .disabled(isRunning || busyElsewhere || !missing.isEmpty || !c.enabled)
                .keyboardShortcut(.return, modifiers: .command)
                .help(runHelp(c, missing: missing, busyElsewhere: busyElsewhere))

                if !missing.isEmpty {
                    Text("Fill in \(missing.map(\.name).joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !c.enabled {
                    Text("This capability is turned off.").font(.caption).foregroundStyle(.secondary)
                } else if c.safety == .destructive {
                    Text("Marked destructive: it modifies or deletes.")
                        .font(.caption).foregroundStyle(Color.nWarningText)
                } else if busyElsewhere {
                    Text("Another capability is running.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let result = runner.results[c.name] {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(
                                result.ok ? Color.nSuccessText : Color.nErrorText)
                        Text(result.ok ? "Ran successfully" : "Did not run")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Button("Clear") { runner.clear(c.name) }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView {
                        Text(result.output)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.nSurface))
            }
        }
    }

    /// The bridge between "I can see this row" and "how do I actually use it?".
    ///
    /// Running from this pane is the manual path; the point of a capability is that an agent calls
    /// it mid-conversation. Nothing anywhere told a user that, or what to type — so the library
    /// read as a list of things the app could do to itself. A copyable example closes that.
    @ViewBuilder
    private func askInChat(_ c: Capability) -> some View {
        let phrase = exampleAsk(c)
        VStack(alignment: .leading, spacing: 5) {
            sectionLabel("Or just ask in a conversation")
            HStack(alignment: .top, spacing: 8) {
                Text("“\(phrase)”")
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(phrase, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Copy this prompt")
                    .accessibilityLabel("Copy example prompt")
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.nSurface))

            if let app = c.target?.appName {
                Text("Uses \(app). The first run asks for permission to control it.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// Derive something a person could actually type from the capability's own description, which
    /// was written to tell an agent WHEN to use this — so it is already close to the sentence a
    /// user would say, once it stops referring to them in the third person.
    ///
    /// The failure worth guarding: a description whose first sentence runs long (these routinely
    /// enumerate everything the verb returns, past a colon). Truncating at that colon reliably
    /// leaves the intent — "Analyse the whole Music library on this Mac" — while the full sentence
    /// is unusable. Falling through to `Title — snake_case_name` puts back exactly the
    /// implementation vocabulary this pane is trying to get rid of, so it is the last resort.
    private func exampleAsk(_ c: Capability) -> String {
        if let stated = c.examplePrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stated.isEmpty { return stated }
        func humanize(_ s: String) -> String {
            s.replacingOccurrences(of: "the user's own", with: "my")
                .replacingOccurrences(of: "the user's", with: "my")
                .replacingOccurrences(of: "the user", with: "me")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let sentences = c.description
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let use = sentences.first(where: { $0.lowercased().hasPrefix("use when the user wants") }) {
            let want = humanize(String(use.dropFirst("Use when the user wants".count)))
            if !want.isEmpty, want.count <= 140 { return want.prefix(1).capitalized + want.dropFirst() }
        }
        if var first = sentences.first.map(humanize) {
            // Descriptions commonly read "<what it does>: <everything it returns>". The clause
            // before the colon is the request; the list after it is reference material.
            if first.count > 140, let colon = first.firstIndex(of: ":") {
                first = String(first[first.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            }
            if !first.isEmpty, first.count <= 140 { return first }
        }
        return "Use \(c.title)"
    }

    private func runHelp(_ c: Capability, missing: [CapabilityParam], busyElsewhere: Bool) -> String {
        if !c.enabled { return "Turn this capability on to run it." }
        if busyElsewhere { return "Wait for the running capability to finish." }
        if !missing.isEmpty { return "Required: \(missing.map(\.name).joined(separator: ", "))" }
        return "Run \(c.title) now (⌘↩)"
    }

    private func binding(_ c: Capability, _ param: String) -> Binding<String> {
        Binding(
            get: { arguments[c.uuid]?[param] ?? "" },
            set: { arguments[c.uuid, default: [:]][param] = $0 })
    }

    // MARK: bits

    private func appIcon(_ c: Capability) -> Image {
        if let bid = c.target?.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        }
        if let name = c.target?.appName,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple." + name.lowercased()) {
            return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        }
        return Image(systemName: "wand.and.stars")
    }

    private func verificationDot(_ state: String) -> some View {
        Circle().fill(state == "passed" ? Color.green : state == "failed" ? Color.red : Color.secondary.opacity(0.5))
            .frame(width: 8, height: 8)
    }

    private func healthText(_ c: Capability) -> String {
        switch c.verification.state {
        case "passed": return "Verified" + (c.verification.lastTestedAt != nil ? " · ran successfully" : "")
        case "failed": return "Last run failed. Needs a retest"
        default: return "Not yet run"
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary).padding(.top, 2)
    }
}
