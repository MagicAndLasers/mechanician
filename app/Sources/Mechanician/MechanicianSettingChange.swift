import Foundation

/// One app-setting change an agent has proposed and the person has not answered yet.
///
/// The agent supplies no copy. Everything shown is composed by the app from its own state, so a
/// provider cannot dress a change up as something milder than it is, and the card can always say
/// what the value is now as well as what it would become.
struct MechanicianSettingChangeRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The turn that asked, so a request cannot outlive it or be answered for a different one.
    let turnID: String
    let title: String
    let detail: String
    let confirmLabel: String
    /// What the person is told happened when they decline. Kept beside the request so the decline
    /// path never has to invent a sentence at the moment it is used.
    let declineText: String
    let approveText: String

    init(
        id: UUID = UUID(),
        turnID: String,
        title: String,
        detail: String,
        confirmLabel: String,
        approveText: String,
        declineText: String
    ) {
        self.id = id
        self.turnID = turnID
        self.title = title
        self.detail = detail
        self.confirmLabel = confirmLabel
        self.approveText = approveText
        self.declineText = declineText
    }
}

/// How a pending settings confirmation ended.
enum MechanicianSettingChangeOutcome: Equatable, Sendable {
    case approved
    case declined
    /// The turn ended, was interrupted, or drifted before the person answered. Nothing changed, and
    /// this is deliberately distinct from a decline: the person did not refuse, they never saw it
    /// through, and telling the agent otherwise would put words in their mouth.
    case abandoned
    /// Nothing was shown at all, because another change was already waiting. The person has not
    /// seen this proposal, so it is not abandoned either — it was never put to them. Folding this
    /// into a decline is how a duplicate call became "you declined the confirmation" in a
    /// conversation where only one card was ever displayed.
    case notAsked
}
