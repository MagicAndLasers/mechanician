import XCTest
@testable import Mechanician

final class NewConversationExamplesTests: XCTestCase {
    func testHomeExamplesAreExplicitAndExerciseDistinctCapabilities() {
        let content = NewConversationExamples.content(projectID: nil, cwd: "", projects: [])

        XCTAssertEqual(content.title, "What should we make happen?")
        XCTAssertTrue(content.subtitle.hasPrefix("Home is"))
        XCTAssertTrue(content.offersFolderPicker)
        XCTAssertEqual(content.examples.count, 4)
        XCTAssertEqual(
            content.examples.map(\.id),
            ["home.catch-up", "home.make-visual", "home.build-tool", "home.automate-morning"])
        XCTAssertTrue(content.examples.contains { $0.prompt.contains("original sources") })
        XCTAssertTrue(content.examples.contains { $0.prompt.contains("illustrated poster") })
        XCTAssertTrue(content.examples.contains { $0.prompt.contains("interactive") })
        XCTAssertTrue(content.examples.contains { $0.prompt.contains("Every weekday") })
    }

    func testHelpExamplesMatchTheClosedProductExpertWithOrWithoutItsProjectLoaded() {
        let withoutProject = NewConversationExamples.content(
            projectID: HelpWorkspace.id,
            cwd: "",
            projects: [])
        let withProject = NewConversationExamples.content(
            projectID: HelpWorkspace.id,
            cwd: "",
            projects: [ReservedWorkspace.help.canonicalProject()])

        XCTAssertEqual(withoutProject, withProject)
        XCTAssertEqual(withoutProject.title, HelpWorkspace.name)
        XCTAssertEqual(withoutProject.subtitle, HelpWorkspace.goal)
        XCTAssertFalse(withoutProject.offersFolderPicker)
        XCTAssertEqual(Set(withoutProject.examples.map(\.id)).count, 4)
        XCTAssertTrue(withoutProject.examples.contains { $0.prompt.contains("conversations and workspaces") })
        XCTAssertTrue(withoutProject.examples.contains { $0.prompt.contains("Explain the conversation controls") })
        XCTAssertTrue(withoutProject.examples.contains { $0.prompt.contains("permissions, approvals, and questions") })
        XCTAssertTrue(withoutProject.examples.contains { $0.prompt.contains("skill, plugin, MCP server") })
        XCTAssertFalse(withoutProject.examples.contains { $0.prompt.contains("latest developments") })
        XCTAssertFalse(withoutProject.examples.contains { $0.prompt.contains("visual brief") })
    }

    func testMissingTopicWorkspaceDoesNotTemporarilyBecomeHome() {
        let content = NewConversationExamples.content(
            projectID: UUID(),
            cwd: "",
            projects: [])

        XCTAssertEqual(content.title, "Workspace")
        XCTAssertFalse(content.subtitle.hasPrefix("Home is"))
        XCTAssertFalse(content.offersFolderPicker)
        XCTAssertEqual(content.examples.map(\.id), [
            "topic.direction", "topic.research", "topic.brief", "topic.pressure-test"
        ])
    }

    func testFolderWorkspaceExamplesUseItsNameAndGoal() {
        let project = Project(
            name: "Mechanician",
            goal: "Make desktop agents feel dependable",
            cwd: "/private/tmp/mechanician")

        let content = NewConversationExamples.content(
            projectID: project.id,
            cwd: project.cwd,
            projects: [project])

        XCTAssertEqual(content.title, "Mechanician")
        XCTAssertFalse(content.offersFolderPicker)
        XCTAssertTrue(content.subtitle.contains("files, code, terminal"))
        XCTAssertTrue(content.examples.allSatisfy { $0.prompt.contains("Mechanician") })
        XCTAssertTrue(content.examples.contains { $0.prompt.contains("Make desktop agents feel dependable") })
        XCTAssertTrue(content.examples.contains { $0.prompt.contains("uncommitted changes") })
    }

    func testTopicWorkspaceExamplesUseStoredContextWithoutOfferingFolderPicker() {
        let project = Project(
            name: "Launch plan",
            goal: "Prepare a clear beta launch",
            instructions: "Keep the audience focused on small teams.")

        let content = NewConversationExamples.content(
            projectID: project.id,
            cwd: "",
            projects: [project])

        XCTAssertEqual(content.title, "Launch plan")
        XCTAssertEqual(content.subtitle, "Prepare a clear beta launch")
        XCTAssertFalse(content.offersFolderPicker)
        XCTAssertTrue(content.examples.allSatisfy { $0.prompt.contains("Launch plan") })
        XCTAssertTrue(content.examples.contains { $0.prompt.contains("Prepare a clear beta launch") })
        XCTAssertTrue(content.examples.contains { $0.prompt.contains("visual brief") })
    }

    func testUnknownFolderStillGetsFolderWorkspaceExamples() {
        let content = NewConversationExamples.content(
            projectID: nil,
            cwd: "/private/tmp/sample-repo",
            projects: [])

        XCTAssertEqual(content.title, "sample-repo")
        XCTAssertFalse(content.offersFolderPicker)
        XCTAssertTrue(content.examples.allSatisfy { $0.prompt.contains("sample-repo") })
        XCTAssertTrue(content.examples.contains { $0.title == "Fix what's broken" })
    }

    func testProductWordmarkTypographyIsScopedToMechanicianTitle() {
        XCTAssertTrue(MechanicianTypography.isProductWordmark("Mechanician"))
        XCTAssertTrue(MechanicianTypography.isProductWordmark("mechanician"))
        XCTAssertFalse(MechanicianTypography.isProductWordmark("What should we make happen?"))
        XCTAssertFalse(MechanicianTypography.isProductWordmark("Launch plan"))
    }
}
