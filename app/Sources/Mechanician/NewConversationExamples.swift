import Foundation

/// Copy and prompts for an empty conversation. Keeping this outside the view makes the distinction
/// between Home, Help, topic workspaces, and folder-backed workspaces explicit and easy to test.
struct NewConversationExample: Identifiable, Equatable {
    let id: String
    let title: String
    let prompt: String
    let systemImage: String
}

struct NewConversationExampleContent: Equatable {
    let title: String
    let subtitle: String
    let examples: [NewConversationExample]
    let offersFolderPicker: Bool
}

enum NewConversationExamples {
    static func content(projectID: UUID?, cwd: String, projects: [Project]) -> NewConversationExampleContent {
        // Home and Help are first-class product places, not merely two folderless Project shapes.
        // Resolve their exact identities before consulting the Project inventory so Help never
        // flashes generic topic suggestions while its lazily-created row is still arriving.
        switch WorkspacePlace.showing(projectID: projectID, cwd: cwd) {
        case .home: return home
        case .help: return help
        case nil: break
        }
        if let project = project(for: projectID, cwd: cwd, projects: projects) {
            return project.isWorkspace || !cwd.isEmpty
                ? folderWorkspace(project: project)
                : topicWorkspace(project)
        }
        if !cwd.isEmpty {
            return folderWorkspace(
                project: Project(name: URL(fileURLWithPath: cwd).lastPathComponent, cwd: cwd))
        }
        if projectID != nil {
            return unresolvedTopicWorkspace
        }
        return home
    }

    private static func project(for projectID: UUID?, cwd: String, projects: [Project]) -> Project? {
        if let projectID, let project = projects.first(where: { $0.id == projectID }) { return project }
        guard !cwd.isEmpty else { return nil }
        return projects.first(where: { $0.cwd == cwd })
    }

    private static let home = NewConversationExampleContent(
        title: String(localized: "What should we make happen?"),
        subtitle: String(localized: "Home is your starting place for research, creation, planning, and automation across the web, apps, files, and your Mac."),
        examples: [
            NewConversationExample(
                id: "home.catch-up",
                title: String(localized: "Catch me up"),
                prompt: String(localized: "Research the biggest developments in AI this week and give me a concise briefing with links to the original sources."),
                systemImage: "sparkle.magnifyingglass"),
            NewConversationExample(
                id: "home.make-visual",
                title: String(localized: "Make something visual"),
                prompt: String(localized: "Create an illustrated poster of a cozy robot repair shop at night, with warm windows and a cinematic blue city outside."),
                systemImage: "photo.on.rectangle.angled"),
            NewConversationExample(
                id: "home.build-tool",
                title: String(localized: "Build an interactive tool"),
                prompt: String(localized: "Build an interactive trip-planning artifact for a long weekend in Montréal, with a map-friendly itinerary and a simple budget."),
                systemImage: "macwindow.badge.plus"),
            NewConversationExample(
                id: "home.automate-morning",
                title: String(localized: "Automate my morning"),
                prompt: String(localized: "Every weekday at 8:00 AM, brief me on today's calendar, urgent email, and my top three priorities."),
                systemImage: "clock.badge.checkmark")
        ],
        offersFolderPicker: true)

    /// Help runs with a deliberately closed product-expert profile. These starters stay inside
    /// signed product knowledge, reviewed guidance, and explanation instead of promising files,
    /// web research, artifacts, or external automation that the Help conversation cannot use.
    private static let help = NewConversationExampleContent(
        title: HelpWorkspace.name,
        subtitle: HelpWorkspace.goal,
        examples: [
            NewConversationExample(
                id: "help.get-started",
                title: String(localized: "Get started"),
                prompt: String(localized: "Explain the best way to organize work with conversations and workspaces in Mechanician."),
                systemImage: "map"),
            NewConversationExample(
                id: "help.learn-controls",
                title: String(localized: "Learn the controls"),
                prompt: String(localized: "Explain the conversation controls and when to use each one."),
                systemImage: "slider.horizontal.3"),
            NewConversationExample(
                id: "help.work-safely",
                title: String(localized: "Work safely"),
                prompt: String(localized: "Explain how permissions, approvals, and questions work in Mechanician."),
                systemImage: "lock.shield.fill"),
            NewConversationExample(
                id: "help.extend",
                title: String(localized: "Extend Mechanician"),
                prompt: String(localized: "How should I choose between a skill, plugin, MCP server, saved capability, and built-in tool?"),
                systemImage: "puzzlepiece.extension")
        ],
        offersFolderPicker: false)

    /// A topic workspace's row can briefly lag behind its window binding during launch or restore.
    /// Keep that exact binding out of Home while the project inventory catches up.
    private static let unresolvedTopicWorkspace = NewConversationExampleContent(
        title: String(localized: "Workspace"),
        subtitle: String(localized: "Start from this workspace's shared context and instructions."),
        examples: [
            NewConversationExample(
                id: "topic.direction",
                title: String(localized: "Set the direction"),
                prompt: String(localized: "Use this workspace's context and standing instructions to summarize what we're trying to accomplish and propose the next three concrete steps."),
                systemImage: "arrow.triangle.branch"),
            NewConversationExample(
                id: "topic.research",
                title: String(localized: "Research what's new"),
                prompt: String(localized: "Research the latest developments relevant to this workspace. Cite original sources, then connect the findings to its goal, context, and decisions."),
                systemImage: "globe.americas"),
            NewConversationExample(
                id: "topic.brief",
                title: String(localized: "Create a working brief"),
                prompt: String(localized: "Turn this workspace's current context into a polished visual brief as an artifact, including its goal, key decisions, open questions, and next steps."),
                systemImage: "doc.richtext"),
            NewConversationExample(
                id: "topic.pressure-test",
                title: String(localized: "Pressure-test the plan"),
                prompt: String(localized: "Challenge the assumptions in this workspace, identify the biggest unresolved risks to its goal, and recommend practical ways to reduce them."),
                systemImage: "exclamationmark.bubble")
        ],
        offersFolderPicker: false)

    private static func folderWorkspace(project: Project) -> NewConversationExampleContent {
        let name = project.displayName
        let promptName = concise(name, limit: 80)
        let goal = concise(project.goal)
        let moveForwardPrompt: String
        if goal.isEmpty {
            moveForwardPrompt = String(localized: "Inspect the \"\(promptName)\" workspace, choose the highest-impact improvement you can safely make, implement it, and verify the result.")
        } else {
            moveForwardPrompt = String(localized: "Move the \"\(promptName)\" workspace toward its goal, \"\(goal)\", by choosing the highest-impact improvement you can safely make, implementing it, and verifying the result.")
        }
        return NewConversationExampleContent(
            title: name,
            subtitle: String(localized: "Work directly with this workspace's files, code, terminal, and version-control context."),
            examples: [
                NewConversationExample(
                    id: "folder.orient",
                    title: String(localized: "Orient me"),
                    prompt: String(localized: "Give me a concise tour of the \"\(promptName)\" workspace: its structure, how to run it, and where the important code lives."),
                    systemImage: "map"),
                NewConversationExample(
                    id: "folder.move-forward",
                    title: String(localized: "Move the work forward"),
                    prompt: moveForwardPrompt,
                    systemImage: "hammer"),
                NewConversationExample(
                    id: "folder.fix",
                    title: String(localized: "Fix what's broken"),
                    prompt: String(localized: "Run the relevant tests in the \"\(promptName)\" workspace, diagnose any failures, fix what you can, and summarize what changed."),
                    systemImage: "wrench.and.screwdriver"),
                NewConversationExample(
                    id: "folder.review",
                    title: String(localized: "Review my changes"),
                    prompt: String(localized: "Review the uncommitted changes in the \"\(promptName)\" workspace for bugs, regressions, security issues, and missing tests. Give me findings in priority order."),
                    systemImage: "checkmark.seal")
            ],
            offersFolderPicker: false)
    }

    private static func topicWorkspace(_ project: Project) -> NewConversationExampleContent {
        let name = project.displayName
        let promptName = concise(name, limit: 80)
        let goal = concise(project.goal)
        let directionPrompt = goal.isEmpty
            ? String(localized: "Use the context and standing instructions in the \"\(promptName)\" workspace to summarize what we're trying to accomplish and propose the next three concrete steps.")
            : String(localized: "Use the context and standing instructions in the \"\(promptName)\" workspace to advance its goal, \"\(goal)\". Propose the next three concrete steps and explain which one should happen first.")
        return NewConversationExampleContent(
            title: name,
            subtitle: goal.isEmpty
                ? String(localized: "Start from this workspace's shared context and instructions.")
                : goal,
            examples: [
                NewConversationExample(
                    id: "topic.direction",
                    title: String(localized: "Set the direction"),
                    prompt: directionPrompt,
                    systemImage: "arrow.triangle.branch"),
                NewConversationExample(
                    id: "topic.research",
                    title: String(localized: "Research what's new"),
                    prompt: String(localized: "Research the latest developments relevant to the \"\(promptName)\" workspace. Cite original sources, then connect the findings to its goal, context, and decisions."),
                    systemImage: "globe.americas"),
                NewConversationExample(
                    id: "topic.brief",
                    title: String(localized: "Create a working brief"),
                    prompt: String(localized: "Turn the \"\(promptName)\" workspace's current context into a polished visual brief as an artifact, including its goal, key decisions, open questions, and next steps."),
                    systemImage: "doc.richtext"),
                NewConversationExample(
                    id: "topic.pressure-test",
                    title: String(localized: "Pressure-test the plan"),
                    prompt: String(localized: "Challenge the assumptions in the \"\(promptName)\" workspace, identify the biggest unresolved risks to its goal, and recommend practical ways to reduce them."),
                    systemImage: "exclamationmark.bubble")
            ],
            offersFolderPicker: false)
    }

    private static func concise(_ value: String, limit: Int = 140) -> String {
        let collapsed = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
