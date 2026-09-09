import SwiftUI

/// The provider/account lane whose skill inventory the user has acknowledged.
///
/// This deliberately matches the command cache's ownership boundary: built-in lanes are separated
/// by `ModelAccess`, while managed enterprise lanes additionally carry the tenant route identity.
/// A Claude inventory must never clear Codex's badge, and changing a managed backend must not inherit
/// the prior backend's acknowledgement.
struct SkillInventoryScope: Hashable {
    var access: ModelAccess
    var routeIdentity: String?

    @MainActor
    static func current(for bridge: AgentBridge) -> Self {
        let access = bridge.currentModelAccess
        return Self(
            access: access,
            routeIdentity: TenantProfile.current.routeIdentity(for: access))
    }

    fileprivate var persistenceKey: String {
        [
            "mech.skills.seen.v1",
            access.rawValue,
            routeIdentity ?? "built-in",
        ].joined(separator: ".")
    }
}

struct SkillInventoryGroup: Identifiable, Equatable {
    var id: String
    var title: String
    var plugin: String?
    var skills: [SlashCommandInfo]

    var isPlugin: Bool { plugin != nil }
}

/// One presentation policy shared by the panel, its search count, and the unseen badge.
///
/// Claude reports a mixture of useful commands and terminal-only controls. Codex does not expose
/// ordinary slash commands through this surface: its supported inventory is the `$`-prefixed
/// system, user, repository, and plugin skills App Server reports. Keeping that distinction here
/// prevents a stale or malformed catalog from promising a command the conversation cannot invoke.
enum SkillInventoryPresentation {
    static func visibleCommands(
        _ commands: [SlashCommandInfo],
        access: ModelAccess,
        showTerminalCommands: Bool = false
    ) -> [SlashCommandInfo] {
        if access == .codexSubscription {
            return commands.filter { $0.prefix == "$" }
        }
        return commands.filter {
            showTerminalCommands || !SkillVisibility.isTerminalOnly($0.name)
        }
    }

    static func groups(_ commands: [SlashCommandInfo]) -> [SkillInventoryGroup] {
        var byPlugin: [String: [SlashCommandInfo]] = [:]
        var codexSkills: [SlashCommandInfo] = []
        var builtIn: [SlashCommandInfo] = []
        for command in commands {
            if let colon = command.name.firstIndex(of: ":") {
                byPlugin[String(command.name[..<colon]), default: []].append(command)
            } else if command.prefix == "$" {
                codexSkills.append(command)
            } else {
                builtIn.append(command)
            }
        }

        var result = byPlugin.map { plugin, skills in
            SkillInventoryGroup(
                id: "plugin:\(plugin)",
                title: plugin,
                plugin: plugin,
                skills: skills.sorted { $0.name < $1.name })
        }
        .sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        if !codexSkills.isEmpty {
            result.append(SkillInventoryGroup(
                id: "codex-skills",
                // Plugin skills carry a namespace. The bridge's compact command payload intentionally
                // omits App Server's scope/path, so unnamespaced entries stay provenance-neutral.
                title: "Codex skills",
                plugin: nil,
                skills: codexSkills.sorted { $0.name < $1.name }))
        }
        if !builtIn.isEmpty {
            result.append(SkillInventoryGroup(
                id: "built-in",
                title: "Built in",
                plugin: nil,
                skills: builtIn.sorted { $0.name < $1.name }))
        }
        return result
    }

    static func availabilityDescription(access: ModelAccess) -> String {
        if access == .codexSubscription {
            return "Skills available to this conversation through Codex. "
                + "Codex App Server does not report its regular slash-command catalog, "
                + "so this list contains only the $ skills it exposes."
        }
        return "Skills and commands available to this conversation from \(access.displayName). "
            + "Select one to apply it to your next message."
    }
}

/// Persist the invocation identities the user has actually seen, rather than a count watermark.
///
/// A catalog can replace one skill with another without changing its size; comparing counts would
/// miss that new skill. The cumulative set also makes transient empty catalogs harmless and ensures
/// removing and later restoring the same invocation does not manufacture another unread item.
@MainActor
final class SkillInventorySeenState: ObservableObject {
    static let shared = SkillInventorySeenState()

    @Published private(set) var revision = 0
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func unseenInvocationIDs(
        in commands: [SlashCommandInfo],
        scope: SkillInventoryScope
    ) -> Set<String> {
        invocationIDs(in: commands, scope: scope)
            .subtracting(seenInvocationIDs(in: scope))
    }

    func unseenCount(
        in commands: [SlashCommandInfo],
        scope: SkillInventoryScope
    ) -> Int {
        unseenInvocationIDs(in: commands, scope: scope).count
    }

    func markViewed(
        _ commands: [SlashCommandInfo],
        scope: SkillInventoryScope
    ) {
        let previous = seenInvocationIDs(in: scope)
        let updated = previous.union(invocationIDs(in: commands, scope: scope))
        guard updated != previous else { return }
        defaults.set(updated.sorted(), forKey: scope.persistenceKey)
        revision &+= 1
    }

    private func invocationIDs(
        in commands: [SlashCommandInfo],
        scope: SkillInventoryScope
    ) -> Set<String> {
        Set(SkillInventoryPresentation.visibleCommands(
            commands,
            access: scope.access
        ).map(\.invocation))
    }

    private func seenInvocationIDs(in scope: SkillInventoryScope) -> Set<String> {
        Set(defaults.stringArray(forKey: scope.persistenceKey) ?? [])
    }
}

/// Skills for this conversation, grouped by the plugin that supplied them.
///
/// The fourth destination from EXTENSIONS-DESIGN.md, and deliberately NOT a window. A skill is only
/// meaningful relative to the next message you send, so it belongs beside Files / Changes /
/// Artifacts / Agents rather than in a shopping screen. That placement also settles the provider
/// question without a selector: the conversation already declares its lane, so whatever is listed
/// here is what *this* conversation can actually run.
///
/// Claude namespaces a plugin's skills as `plugin:skill`, so those groups follow provider data.
/// Codex App Server reports enabled skills for the current working directory, including namespaced
/// plugin skills. The compact command event does not carry its scope/path metadata, so unnamespaced
/// `$` entries stay in the provenance-neutral "Codex skills" group.
struct SkillsPanel: View {
    @EnvironmentObject private var bridge: AgentBridge
    @ObservedObject private var seenState = SkillInventorySeenState.shared
    @State private var search = ""
    /// Which plugin groups are open. Empty = everything collapsed, which is the default.
    @State private var expanded: Set<String> = []
    @AppStorage("skillsShowTerminalCommands") private var showTerminalCommands = false

    /// Skills a plugin supplied, plus honest provider-owned groups for unnamespaced inventory.
    private var groups: [SkillInventoryGroup] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = visibleCommands.filter { command in
            guard !needle.isEmpty else { return true }
            return command.name.lowercased().contains(needle)
                || command.description.lowercased().contains(needle)
        }
        return SkillInventoryPresentation.groups(matching)
    }

    private var visibleCommands: [SlashCommandInfo] {
        SkillInventoryPresentation.visibleCommands(
            bridge.slashCommands,
            access: bridge.currentModelAccess,
            showTerminalCommands: showTerminalCommands)
    }

    private var hiddenCount: Int {
        guard bridge.currentModelAccess != .codexSubscription else { return 0 }
        return bridge.slashCommands.count - SkillInventoryPresentation.visibleCommands(
            bridge.slashCommands,
            access: bridge.currentModelAccess
        ).count
    }

    private var inventoryScope: SkillInventoryScope {
        .current(for: bridge)
    }

    private var viewedInventory: ViewedSkillInventory {
        ViewedSkillInventory(
            scope: inventoryScope,
            invocationIDs: SkillInventoryPresentation.visibleCommands(
                bridge.slashCommands,
                access: bridge.currentModelAccess
            ).map(\.invocation))
    }

    var body: some View {
        VStack(spacing: 0) {
            if visibleCommands.isEmpty {
                empty
                if hiddenCount > 0 { hiddenFooter }
            } else {
                availabilityHeader
                Divider()
                searchField
                Divider()
                list
                if hiddenCount > 0 { hiddenFooter }
            }
        }
        .onAppear { markCurrentInventoryViewed() }
        .onChange(of: viewedInventory) { _, _ in markCurrentInventoryViewed() }
    }

    private var availabilityHeader: some View {
        Text(SkillInventoryPresentation.availabilityDescription(
            access: bridge.currentModelAccess))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
    }

    private func markCurrentInventoryViewed() {
        seenState.markViewed(bridge.slashCommands, scope: inventoryScope)
    }

    /// Says what was hidden and offers it back. A filter the user cannot see is indistinguishable
    /// from a bug, and these Claude commands do still work if typed with "/" in the composer.
    private var hiddenFooter: some View {
        HStack(spacing: 5) {
            Text(showTerminalCommands
                 ? "Showing \(hiddenCount) terminal commands"
                 : "\(hiddenCount) terminal commands hidden")
                .font(.caption2).foregroundStyle(.tertiary)
            Button(showTerminalCommands ? "Hide" : "Show") {
                showTerminalCommands.toggle()
            }
            .buttonStyle(.plain).font(.caption2).foregroundStyle(Color.nInfoText)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar)
        .help("Claude Code commands that drive its terminal UI, or that Mechanician already has "
            + "its own interface for. They still work if you type them in the composer.")
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles").font(.title2).foregroundStyle(.tertiary)
            // Two different situations, and it matters which: a conversation that has not started
            // has not been TOLD its skills yet, which is not the same as having none.
            Text(bridge.currentID == nil ? "Start a conversation to see its skills."
                                         : "This conversation reports no skills yet.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Install a plugin from Extensions to add more.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField("Filter \(visibleCommands.count) skills", text: $search)
                .textFieldStyle(.plain).font(.caption)
                .accessibilityLabel("Filter skills")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(groups) { group in
                    disclosure(group)
                }
            }
            .padding(.vertical, 8)
        }
    }

    /// Collapsed by default, because this list grows with every plugin you install. Ten plugins at a
    /// dozen skills each is 120 rows, and a flat list of 120 is not something you can see.
    ///
    /// A search term expands everything: when you are filtering, matches you cannot see are worse
    /// than useless — you would conclude the search found nothing.
    private func disclosure(_ group: SkillInventoryGroup) -> some View {
        let key = group.id
        let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
        let isOpen = searching || expanded.contains(key)
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: group.isPlugin ? "puzzlepiece.extension" : "shippingbox")
                        .font(.caption2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.title)
                            .font(.caption.weight(.semibold)).foregroundStyle(Color.nText)
                        // The summary is what makes a collapsed group useful: you should not have to
                        // open it to know whether it is worth opening.
                        Text(summary(group)).font(.caption2).foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if armedCount(group) > 0 {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2).foregroundStyle(Color.nInfoText)
                    }
                    Text("\(group.skills.count)").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.title)
            .accessibilityValue("\(group.skills.count) skills")
            .accessibilityHint(isOpen ? "Collapse" : "Expand")

            if isOpen {
                VStack(spacing: 3) {
                    ForEach(group.skills) { skill in row(skill) }
                }
                .padding(.leading, 12)
            }
        }
        .padding(.horizontal, 6)
    }

    /// A one-line answer to "what is in here?" without opening it. Names the first few skills, then
    /// says how many more, so the group is legible while collapsed.
    private func summary(_ group: SkillInventoryGroup) -> String {
        let names = group.skills.prefix(3).map { displayName($0).dropFirst() }
        let rest = group.skills.count - names.count
        let listed = names.joined(separator: ", ")
        return rest > 0 ? "\(listed) +\(rest) more" : listed
    }

    private func armedCount(_ group: SkillInventoryGroup) -> Int {
        group.skills.filter { $0.name == bridge.armedSkill?.name }.count
    }

    private func row(_ skill: SlashCommandInfo) -> some View {
        let armed = bridge.armedSkill?.name == skill.name
        return Button {
            // Arming, not running. Selecting a skill says "apply this to what I am about to type",
            // which is the common case; it can also be invoked directly with its displayed prefix.
            bridge.armedSkill = armed ? nil : skill
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: armed ? "checkmark.circle.fill" : "sparkle")
                    .font(.caption)
                    .foregroundStyle(armed ? Color.nInfoText : .secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(displayName(skill))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(armed ? Color.nInfoText : Color.nText)
                        if !skill.argumentHint.isEmpty {
                            Text(skill.argumentHint)
                                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(armed ? Color.nAccent.opacity(0.16) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .help(skill.description.isEmpty ? skill.invocation : skill.description)
        .accessibilityLabel(skill.invocation)
        .accessibilityHint(armed ? "Armed for your next message. Select to disarm."
                                 : "Arm for your next message.")
        .accessibilityAddTraits(armed ? [.isSelected] : [])
    }

    /// Inside a plugin's group the namespace is already the header, so repeating it on every row
    /// would be noise: `docs:review` under "docs" reads as `/review`.
    private func displayName(_ skill: SlashCommandInfo) -> String {
        guard let colon = skill.name.firstIndex(of: ":") else { return skill.invocation }
        return skill.prefix + String(skill.name[skill.name.index(after: colon)...])
    }
}

private struct ViewedSkillInventory: Equatable {
    var scope: SkillInventoryScope
    var invocationIDs: [String]
}
