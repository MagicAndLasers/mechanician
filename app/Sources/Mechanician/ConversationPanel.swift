import SwiftUI
import AppKit
import UniformTypeIdentifiers

// A Mail-style conversation sidebar backed by a real AppKit NSTableView (not SwiftUI List),
// so it behaves like a native Mac app: reliable double-click (→ new window; ⌘-double-click →
// new tab), native multi-select, drag-and-drop including drag-to-Trash, section headers, and a
// context menu — none of which SwiftUI's List does well (its own row explicitly banned tap
// gestures). Rows are rendered as SwiftUI via NSHostingView, so the rich layout stays declarative
// while the table mechanics are AppKit. Mirrors the app's existing AppKit bridge in
// FileBrowserPanelView.swift (NSViewRepresentable + Coordinator + a keyDown-handling subclass).

// MARK: - Sectioned, flattened row model

enum ConvSection: Hashable {
    case pinned, today, yesterday, prev7, prev30, older
    var title: String {
        switch self {
        case .pinned:    return "Pinned"
        case .today:     return "Today"
        case .yesterday: return "Yesterday"
        case .prev7:     return "Previous 7 Days"
        case .prev30:    return "Previous 30 Days"
        case .older:     return "Older"
        }
    }
    var isPinned: Bool { self == .pinned }
}

/// The flat list the table renders: header rows interleaved with conversation rows. Conversations
/// are referenced by id so the row array is cheap to diff; values are looked up live for rendering.
enum ConvRow: Hashable {
    case header(ConvSection)
    case conversation(UUID)
}

/// The complete result of one local sidebar drop. Every accepted drop carries the dragged rows'
/// explicit desired favorite state with the new order; firing a separate toggle first would briefly
/// sort a row by its old position, and omitting an already-matching directive would let an earlier
/// pending drop win against a stale summary.
struct ConversationReorderIntent: Equatable {
    let orderedIDs: [UUID]
    let orderChanged: Bool
    let pinningIDs: Set<UUID>
    let unpinningIDs: Set<UUID>

    static func droppingInSidebar(
        rows: [ConvRow],
        favoriteIDs: Set<UUID>,
        draggedIDs: Set<UUID>,
        aboveTableRow row: Int
    ) -> Self? {
        guard rows.first == .header(.pinned) else { return nil }
        let pinnedBoundaryRow = rows.dropFirst().firstIndex {
            if case .header(let section) = $0 { return !section.isPinned }
            return false
        } ?? rows.endIndex
        guard (0...rows.endIndex).contains(row) else { return nil }

        let pinnedRowIDs = rows[1..<pinnedBoundaryRow].compactMap {
            if case .conversation(let id) = $0 { return id }
            return nil
        }
        let visibleIDs = rows.compactMap {
            if case .conversation(let id) = $0 { return id }
            return nil
        }
        let visibleIDSet = Set(visibleIDs)
        guard !favoriteIDs.isEmpty,
              pinnedRowIDs.count == favoriteIDs.count,
              Set(pinnedRowIDs) == favoriteIDs,
              !draggedIDs.isEmpty,
              draggedIDs.isSubset(of: visibleIDSet) else { return nil }

        let pinningIDs: Set<UUID>
        let unpinningIDs: Set<UUID>
        if row <= pinnedBoundaryRow {
            pinningIDs = draggedIDs
            unpinningIDs = []
        } else {
            // Dated sections are automatic rather than hand-ordered. The one meaningful local
            // transition there is moving pinned rows out of Pinned; ordinary rows cannot be
            // arbitrarily rearranged across Today/Yesterday/etc.
            let crossingIDs = draggedIDs.intersection(favoriteIDs)
            guard !crossingIDs.isEmpty else { return nil }
            pinningIDs = []
            unpinningIDs = draggedIDs
        }

        var orderedIDs = visibleIDs
        let offsets = IndexSet(visibleIDs.indices.filter { draggedIDs.contains(visibleIDs[$0]) })
        let destinationIndex = rows[..<row].reduce(0) {
            if case .conversation = $1 { return $0 + 1 }
            return $0
        }
        orderedIDs.move(fromOffsets: offsets, toOffset: destinationIndex)
        return Self(
            orderedIDs: orderedIDs,
            orderChanged: orderedIDs != visibleIDs,
            pinningIDs: pinningIDs,
            unpinningIDs: unpinningIDs)
    }
}

/// AppKit's source-list feedback proposes `.on` across most of a row and `.above` only in a thin
/// inter-row strip. Resolve both shapes into one insertion plus one mutation so validation and
/// acceptance cannot disagree about a normal row-body drop.
struct ConversationReorderProposal: Equatable {
    let aboveTableRow: Int
    let intent: ConversationReorderIntent

    static func resolve(
        rows: [ConvRow],
        favoriteIDs: Set<UUID>,
        draggedIDs: Set<UUID>,
        proposedRow row: Int,
        operation: NSTableView.DropOperation
    ) -> Self? {
        let canonicalRow: Int
        switch operation {
        case .above:
            canonicalRow = row
        case .on:
            guard rows.indices.contains(row) else { return nil }
            switch rows[row] {
            case .header(.pinned):
                let firstPinnedRow = rows.index(after: row)
                guard rows.indices.contains(firstPinnedRow),
                      case .conversation = rows[firstPinnedRow] else { return nil }
                canonicalRow = firstPinnedRow
            case .header:
                return nil
            case .conversation(let targetID):
                guard !draggedIDs.contains(targetID) else { return nil }
                let draggedRows = rows.indices.filter { index in
                    guard case .conversation(let id) = rows[index] else { return false }
                    return draggedIDs.contains(id)
                }
                guard draggedRows.count == draggedIDs.count,
                      let firstDraggedRow = draggedRows.first,
                      let lastDraggedRow = draggedRows.last else { return nil }
                if lastDraggedRow < row {
                    canonicalRow = rows.index(after: row)
                } else if firstDraggedRow > row {
                    canonicalRow = row
                } else {
                    // A target inside a noncontiguous selection's span has no honest before/after
                    // interpretation without the pointer's sub-row coordinate.
                    return nil
                }
            }
        @unknown default:
            return nil
        }

        guard let intent = ConversationReorderIntent.droppingInSidebar(
            rows: rows,
            favoriteIDs: favoriteIDs,
            draggedIDs: draggedIDs,
            aboveTableRow: canonicalRow
        ) else { return nil }
        return Self(aboveTableRow: canonicalRow, intent: intent)
    }
}

/// Build the flattened, sectioned rows from the already filtered + sorted conversations
/// (pinned-first is guaranteed upstream by AgentBridge.order). Pinned conversations form their own
/// group; the rest bucket by recency into Mail-style date sections. Empty sections are skipped.
func buildConversationRows(_ convos: [ConversationSummary], now: Date) -> [ConvRow] {
    var rows: [ConvRow] = []
    let favs = convos.filter { $0.favorite }
    if !favs.isEmpty {
        rows.append(.header(.pinned))
        rows.append(contentsOf: favs.map { .conversation($0.id) })
    }
    let cal = Calendar.current
    let t0 = cal.startOfDay(for: now)
    let y0 = cal.date(byAdding: .day, value: -1,  to: t0) ?? t0
    let w0 = cal.date(byAdding: .day, value: -7,  to: t0) ?? t0
    let m0 = cal.date(byAdding: .day, value: -30, to: t0) ?? t0
    func bucket(_ d: Date) -> ConvSection {
        if d >= t0 { return .today }
        if d >= y0 { return .yesterday }
        if d >= w0 { return .prev7 }
        if d >= m0 { return .prev30 }
        return .older
    }
    let rest = convos.filter { !$0.favorite }
    for section: ConvSection in [.today, .yesterday, .prev7, .prev30, .older] {
        let items = rest.filter { bucket($0.updatedAt) == section }
        guard !items.isEmpty else { continue }
        rows.append(.header(section))
        rows.append(contentsOf: items.map { .conversation($0.id) })
    }
    return rows
}

// MARK: - Row content helpers

enum ConversationRowFormat {
    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()
    private static let shortDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M/d/yy"; return f
    }()
    /// Mail-style relative stamp: today → time, yesterday → "Yesterday", this week → weekday, else date.
    static func relativeStamp(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return time.string(from: date) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date),
                                         to: cal.startOfDay(for: now)).day, days < 7 {
            return weekday.string(from: date)
        }
        return shortDate.string(from: date)
    }
}

enum ConversationSwipePresentation {
    static func readActionTitle(unread: Bool) -> String {
        unread ? "Mark Read" : "Mark Unread"
    }

    /// AppKit's row-action title ink is not configurable and can resolve dark even on a saturated
    /// fill. Keep the real title for sizing and accessibility, but present the visible copy as an
    /// original-colour image so every conversation action has deterministic white text.
    @MainActor
    static func action(
        style: NSTableViewRowAction.Style,
        title: String,
        handler: @escaping (NSTableViewRowAction, Int) -> Void
    ) -> NSTableViewRowAction {
        let action = NSTableViewRowAction(style: style, title: title, handler: handler)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let label = NSAttributedString(
            string: title,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
            ])
        let measured = label.size()
        let imageSize = NSSize(
            width: max(1, ceil(measured.width)),
            height: max(1, ceil(measured.height)))
        let image = NSImage(size: imageSize, flipped: false) { rect in
            label.draw(at: NSPoint(
                x: (rect.width - measured.width) / 2,
                y: (rect.height - measured.height) / 2))
            return true
        }
        image.isTemplate = false
        action.image = image
        return action
    }

    /// White swipe copy forces a dark fill — and a dark yellow is mustard by definition, which is
    /// what the previous amber looked like. This is the brand violet, distinct from the blue action
    /// beside it and dark enough to carry the app-owned label.
    static let pinBackgroundColor = NSColor.nPinnedFill
}

/// The one targeting rule every bulk action in the conversation context menu shares, plus the titles
/// that report it. Extracted from the table coordinator so Mark, Move and Delete provably cannot
/// drift apart: `Move to Workspace` once carried only the right-clicked row while its neighbours
/// carried the whole selection, so moving a multi-selection moved one conversation and silently
/// stranded the rest — with a menu title that never admitted it.
enum ConversationBulkAction {
    struct FavoriteMutation: Equatable {
        let conversationIDs: Set<UUID>
        let favorite: Bool
    }

    /// A right-click inside a multi-selection acts on the whole selection; anywhere else acts on the
    /// clicked row alone. The selection deliberately does not follow the cursor, so this fallback is
    /// the only thing that keeps the menu honest about its own scope.
    static func targets(clicked id: UUID, selection: Set<UUID>) -> Set<UUID> {
        (selection.contains(id) && selection.count > 1) ? selection : [id]
    }

    /// Bulk favorite actions converge on one explicit state. A mixed selection offers Pin, matching
    /// the Artifacts browser: one click makes the whole selection pinned instead of inverting every
    /// row independently and leaving the selection mixed in the opposite direction.
    static func favoriteMutation(
        targets: Set<UUID>,
        conversations: [ConversationSummary]
    ) -> FavoriteMutation? {
        guard !targets.isEmpty else { return nil }
        let targeted = conversations.filter { targets.contains($0.id) }
        guard targeted.count == targets.count else { return nil }
        return FavoriteMutation(
            conversationIDs: targets,
            favorite: targeted.contains { !$0.favorite })
    }

    static func favoriteTitle(favorite: Bool, count: Int) -> String {
        if count == 1 {
            return favorite
                ? String(localized: "Pin Conversation")
                : String(localized: "Unpin Conversation")
        }
        return String.localizedStringWithFormat(
            favorite
                ? String(localized: "Pin %lld Conversations")
                : String(localized: "Unpin %lld Conversations"),
            Int64(count))
    }

    static func moveTitle(count: Int) -> String {
        count > 1 ? "Move \(count) Conversations to Workspace" : "Move to Workspace"
    }

    static func deleteTitle(count: Int) -> String {
        count > 1 ? "Delete \(count) Conversations" : "Delete"
    }

    static func markReadTitle(count: Int) -> String {
        count > 1 ? "Mark \(count) as Read" : "Mark as Read"
    }

    static func markUnreadTitle(count: Int) -> String {
        count > 1 ? "Mark \(count) as Unread" : "Mark as Unread"
    }

    /// `.on` means every targeted conversation already lives in that workspace. `.mixed` means only
    /// some do, so the destination must stay clickable — the move still has work to do for the rest.
    /// `nil` in the id set is Home, which this submenu does not offer as a destination.
    static func destinationState(
        targetProjectIDs: Set<UUID?>,
        destination: UUID
    ) -> NSControl.StateValue {
        if targetProjectIDs == [destination] { return .on }
        return targetProjectIDs.contains(destination) ? .mixed : .off
    }
}

enum ConversationRowPresentation {
    /// The selected conversation is the active route for the whole workspace window. Use a fixed
    /// app blue rather than `controlAccentColor`, which can be Graphite (or another user-selected
    /// accent), and keep enough contrast for white row copy in both appearances.
    static let selectionFillColor = NSColor.nSolidActionFill

    /// Keep metadata visually subordinate to the title without dropping small copy below 4.5:1
    /// against either selected-row blue.
    static let selectedSecondaryTextOpacity = 0.96

    /// The inline rename editor paints THIS surface, rather than borrowing whatever happens to be
    /// behind it. A plain `TextField` has no background of its own: the field editor fills only its
    /// own frame while it holds focus, and nothing at all once it does not, so the editor's ink used
    /// to land straight on the row's blue selection fill at 3.8:1 — a black title on a blue row,
    /// which is exactly how it was reported. Painting the field means the ink is measured against a
    /// surface the row controls in both appearances, and a rename always looks like a field.
    static let renameFieldFill = NSColor.textBackgroundColor
    static let renameFieldInk = NSColor.labelColor
    static let renameFieldBorder = NSColor.nMuted
    static let renameFieldBorderOpacity = 0.7
    static let renameFieldCornerRadius: CGFloat = 5
    /// Grown around the text rather than padded inside it, so a row's title does not shift sideways
    /// the moment it becomes editable.
    static let renameFieldInset = NSSize(width: 5, height: 2)

    /// Questions are actionable state, not a generic unread fact. Keep their explicit symbol on
    /// the selected row too: another window may own keyboard focus while this window still shows
    /// the waiting conversation as selected.
    static let questionIndicatorSystemImage = "questionmark.circle.fill"
    static let questionIndicatorHelp = "Waiting on your answer"

    static func showsQuestionIndicator(
        awaitingQuestion: Bool,
        isSelected _: Bool,
        isRunning _: Bool
    ) -> Bool {
        awaitingQuestion
    }

    static func questionIndicatorColor(isSelected: Bool) -> Color {
        isSelected ? .white : .orange
    }

    /// Selected copy stays white while focus is in the composer, transcript, or another window.
    static func usesAccentSelection(windowIsKey _: Bool) -> Bool {
        true
    }

    /// The ordinary activity mark keeps its three brand colors. On the app-blue selection, use
    /// three clean white dots instead of putting the colored mark on a distracting white disc.
    static func activitySpinnerColor(isSelected: Bool) -> Color? {
        isSelected ? .white : nil
    }

    /// A halo helps the three brand colors separate on neutral surfaces. White dots already have
    /// maximum contrast on the selected blue row; a halo there merges them into a pale blob.
    static func activitySpinnerShowsGlow(isSelected: Bool) -> Bool {
        !isSelected
    }

    /// The selected mark can use the complete trailing status slot; its white-on-blue treatment
    /// needs more presence than the ordinary multicolor mark. The normal spinner keeps its compact
    /// size so an unselected row's status does not compete with the title.
    static func activityStatusSlotDiameter(scale: CGFloat = 1) -> CGFloat {
        20 * scale
    }
    static func activitySpinnerDiameter(
        isSelected: Bool,
        scale: CGFloat = 1
    ) -> CGFloat {
        (isSelected ? 20 : 13) * scale
    }
}

// MARK: - SwiftUI row + header bodies

/// The rich Mail-like row. Kept hit-transparent (no .contentShape / gestures) EXCEPT the star
/// Button, so the enclosing NSTableView still owns click-to-select and double-click — see
/// ConvHostCell.hitTest. The pin is a real Button (a control), so it keeps its own click.
struct ConversationRowView: View {
    let convo: ConversationSummary
    let isSelected: Bool
    let selectionIsEmphasized: Bool
    let now: Date
    @ObservedObject var active: ActiveWorkspace
    let onToggleFavorite: () -> Void
    var isEditing: Bool = false
    var editText: Binding<String> = .constant("")
    var onCommit: () -> Void = {}
    var onCancel: () -> Void = {}
    @State private var hovered = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.uiScale) private var uiScale
    private var titleColor: Color {
        guard isSelected else { return .nText }
        return selectionIsEmphasized ? .white : .nSelectedText
    }
    /// The editor's ink belongs to the field it paints (`renameFieldFill`), not to the row: the row's
    /// white would vanish against that field in Light mode, and label colour would vanish against the
    /// blue row if the field were not painted. The two are only ever correct together.
    private var editingTitleColor: Color { Color(nsColor: ConversationRowPresentation.renameFieldInk) }

    /// The rename editor's own field. It is grown outward from the text's frame, so entering and
    /// leaving rename mode does not move the title, and it is drawn whether or not the editor holds
    /// focus — an unfocused editor is still an editor, and must not read as a black title.
    private var renameFieldSurface: some View {
        let shape = RoundedRectangle(
            cornerRadius: ConversationRowPresentation.renameFieldCornerRadius,
            style: .continuous)
        return shape
            .fill(Color(nsColor: ConversationRowPresentation.renameFieldFill))
            .overlay(
                shape.strokeBorder(
                    Color(nsColor: ConversationRowPresentation.renameFieldBorder)
                        .opacity(ConversationRowPresentation.renameFieldBorderOpacity),
                    lineWidth: 1))
            .padding(.horizontal, -ConversationRowPresentation.renameFieldInset.width)
            .padding(.vertical, -ConversationRowPresentation.renameFieldInset.height)
    }
    private var subColor: Color {
        guard isSelected else { return .secondary }
        return selectionIsEmphasized
            ? Color.white.opacity(ConversationRowPresentation.selectedSecondaryTextOpacity)
            : .nSelectedSecondaryText
    }

    private func activitySpinner(helpText: String) -> some View {
        OrbitingDots(
            color: ConversationRowPresentation.activitySpinnerColor(isSelected: isSelected),
            diameter: ConversationRowPresentation.activitySpinnerDiameter(
                isSelected: isSelected,
                scale: uiScale),
            allowsVisualOverflow: true,
            showsGlow: ConversationRowPresentation.activitySpinnerShowsGlow(
                isSelected: isSelected))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(helpText))
        .help(helpText)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // A question remains explicit even on a selected row: selection in a non-key
                    // window does not mean the person saw it. Other attention facts stay as compact
                    // dots and remain hidden on the selected row.
                    if ConversationRowPresentation.showsQuestionIndicator(
                        awaitingQuestion: convo.awaitingQuestion,
                        isSelected: isSelected,
                        isRunning: active.runningConversations.contains(convo.id)
                    ) {
                        Image(systemName: ConversationRowPresentation.questionIndicatorSystemImage)
                            .scaledFont(11, weight: .semibold)
                            .foregroundStyle(
                                ConversationRowPresentation.questionIndicatorColor(
                                    isSelected: isSelected))
                            .accessibilityLabel(
                                Text(verbatim: ConversationRowPresentation.questionIndicatorHelp))
                            .help(ConversationRowPresentation.questionIndicatorHelp)
                    } else if !isSelected {
                        if convo.providerAccessName != nil {
                            Circle().fill(Color.orange).frame(width: 7, height: 7)
                                .help("Provider access needed")
                        } else if convo.errored {
                            Circle().fill(Color.red).frame(width: 7, height: 7)
                                .help("The last turn ended with an error")
                        } else if convo.unread {
                            Circle().fill(Color.nAccent).frame(width: 7, height: 7)
                                .help("Unread: a new result arrived")
                        }
                    }
                    if isEditing {
                        TextField("Title", text: editText)
                            .textFieldStyle(.plain)
                            .scaledFont(13, weight: .semibold)
                            .foregroundStyle(editingTitleColor)
                            .focused($fieldFocused)
                            .onSubmit(onCommit)
                            .onExitCommand(perform: onCancel)
                            .onAppear { fieldFocused = true }
                            .onChange(of: fieldFocused) { _, focused in if !focused { onCommit() } } // commit on blur
                            .background(renameFieldSurface)
                    } else {
                        Text(convo.displayTitle).scaledFont(13, weight: .semibold)
                            .foregroundStyle(titleColor).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(ConversationRowFormat.relativeStamp(convo.updatedAt, now: now))
                        .scaledFont(10).foregroundStyle(subColor).lineLimit(1).fixedSize()
                }
                Text(convo.snippet)
                    .scaledFont(11).foregroundStyle(subColor).lineLimit(1)
                HStack(spacing: 6) {
                    // Workspace identity is already shown in the title bar, and every sidebar row is
                    // local to that workspace, so a per-row location badge would only repeat it.
                    let n = convo.messageCount
                    if n > 0 {
                        Label("\(n)", systemImage: "bubble.left.and.bubble.right")
                            .scaledFont(10).labelStyle(.titleAndIcon).foregroundStyle(subColor)
                    }
                    Spacer(minLength: 0)
                    Group {
                        if active.runningConversations.contains(convo.id) {
                            activitySpinner(helpText: "Running")
                        } else if convo.hasRunningDelegate {
                            activitySpinner(
                                helpText: "A workflow or agent is running in the background")
                        } else if let waitSummary = convo.armedWaitSummary {
                            Image(systemName: "hourglass")
                                .font(.system(size: 11))
                                .foregroundStyle(isSelected ? titleColor : Color.nWarningText)
                                .help("Waiting \(waitSummary), will resume automatically")
                        } else if let providerName = convo.providerAccessName {
                            Image(systemName: "person.crop.circle.badge.exclamationmark")
                                .font(.system(size: 11))
                                .foregroundStyle(isSelected ? titleColor : Color.nWarningText)
                                .help("Connect to \(providerName) to continue")
                        } else if convo.errored {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(isSelected ? titleColor : Color.nErrorText)
                                .help("The last turn ended in an error. Review the conversation for details")
                        } else {
                            Color.clear
                        }
                    }
                    .frame(
                        width: ConversationRowPresentation.activityStatusSlotDiameter(scale: uiScale),
                        height: ConversationRowPresentation.activityStatusSlotDiameter(scale: uiScale))
                    Group {
                        if convo.favorite || hovered {
                            Button(action: onToggleFavorite) {
                                Image(systemName: convo.favorite
                                      ? (hovered ? "pin.slash" : "pin.fill") : "pin")
                                    .font(.system(size: 11))
                                    // Pinned rows get the pin accent; the hover-revealed pin on an
                                    // unpinned row stays grey, so colour means "pinned" rather than
                                    // "your cursor is here". Selection copy follows the appearance
                                    // because the selected row itself is accent-filled.
                                    .foregroundStyle(isSelected
                                                     ? subColor
                                                     : (convo.favorite
                                                        ? Color.nPinned : Color.secondary.opacity(0.55)))
                            }
                            .buttonStyle(.plain)
                            .help(convo.favorite ? "Unpin conversation" : "Pin conversation")
                            .accessibilityLabel(convo.favorite ? "Unpin conversation" : "Pin conversation")
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 16, height: 16)
                }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onHover { hovered = $0 }
        // The pin button is intentionally hidden on unpinned rows until hover to keep the
        // sidebar quiet. Keep the same action available to keyboard and VoiceOver users even
        // when the visual control is not currently realized.
        .accessibilityAction(named: Text(convo.favorite
                                         ? "Unpin conversation"
                                         : "Pin conversation")) {
            onToggleFavorite()
        }
    }
}

struct ConvSectionHeaderView: View {
    let section: ConvSection
    var body: some View {
        HStack(spacing: 4) {
            Text(section.title.uppercased()).scaledFont(10, weight: .semibold).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 9).padding(.top, 8).padding(.bottom, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Hosting cell (hit-transparent except real controls)

/// An NSTableCellView whose body is a SwiftUI view via NSHostingView. Its hitTest passes plain-row
/// clicks (title/snippet/background) through to the table so single-click selection and the table's
/// doubleAction still fire; only real SwiftUI controls (the star Button) keep their own hits.
final class ConvHostCell: NSTableCellView {
    var convId: UUID?
    private var hosting: NSHostingView<AnyView>?

    func host<V: View>(_ view: V) {
        let root = AnyView(view)
        if let h = hosting { h.rootView = root; return }
        let h = NSHostingView(rootView: root)
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: leadingAnchor),
            h.trailingAnchor.constraint(equalTo: trailingAnchor),
            h.topAnchor.constraint(equalTo: topAnchor),
            h.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hosting = h
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        // A transparent SwiftUI area resolves to the CELL itself (no subview claimed the point) →
        // return nil so the table owns click-to-select + double-click. A real SwiftUI control (the
        // star Button) makes the hosting view claim the hit → return it so the button fires. (The
        // row body deliberately has no .contentShape/gesture, so only controls are hit-opaque.)
        return v === self ? nil : v
    }
}

// MARK: - Table subclass (right-click selection + ⌫ / ⏎)

/// A drag-out pasteboard type identifying our own conversation rows (reorder + trash payload).
extension NSPasteboard.PasteboardType {
    static let mechConversationRow = NSPasteboard.PasteboardType("com.mechanician.conversation-row")
}

/// A Mail-style hairline between conversation rows: drawn at the row's bottom, inset from the left,
/// and hidden while the row is selected. Section-header rows use the default row view (no line).
final class SeparatorRowView: NSTableRowView {
    static let selectionInset = NSSize(width: 3, height: 1)
    static let selectionCornerRadius: CGFloat = 6

    static func selectionRect(in bounds: NSRect) -> NSRect {
        bounds.insetBy(dx: selectionInset.width, dy: selectionInset.height)
    }

    /// This row draws the one selected capsule itself. Suppress AppKit's gray/accent-dependent
    /// selection so no second shape can show around it as focus or system Accent Color changes.
    override var selectionHighlightStyle: NSTableView.SelectionHighlightStyle {
        get { .none }
        set {}
    }

    override func drawSelection(in _: NSRect) {}

    // drawSeparator(in:) isn't invoked for view-based source-list rows, so draw the hairline in
    // draw(_:) directly (after the background/selection). The row's NSHostingView cell is transparent,
    // so a line on the row view shows at the bottom edge.
    // A clearly-visible-but-tasteful hairline (separatorColor is too faint on the dark surface).
    private static let line = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.11) : NSColor.black.withAlphaComponent(0.10)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isSelected {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ConversationRowPresentation.selectionFillColor.setFill()
                NSBezierPath(
                    roundedRect: Self.selectionRect(in: bounds),
                    xRadius: Self.selectionCornerRadius,
                    yRadius: Self.selectionCornerRadius
                ).fill()
            }
            return
        }
        let y = bounds.maxY - 0.5
        Self.line.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: 11, y: y))
        path.line(to: NSPoint(x: bounds.maxX, y: y))
        path.stroke()
    }

}

final class ConversationNSTableView: NSTableView {
    var onDeleteKey: (() -> Void)?
    var onReturnKey: (() -> Void)?
    /// The standard Edit ▸ Select All responder action reaches this table only while the list is
    /// first responder. Text fields (search and inline rename) remain their own first responders,
    /// so ⌘A keeps selecting text there instead of conversation rows.
    var onSelectAll: (() -> Void)?

    func useAppOwnedSelectionAppearance() {
        // Source-list style adds its own horizontal cell padding and background decoration. That
        // decoration remains visible as pale gutters even when its selection painter is disabled.
        // Plain style leaves the complete row surface to SeparatorRowView.
        style = .plain
        selectionHighlightStyle = .none
    }

    // A right-click shows the context menu for the row under the cursor WITHOUT moving the selection.
    // Selecting here would navigate THIS tab to that conversation (the sidebar selection drives
    // `currentID`), so "Open in New Tab" / rename / delete on another conversation would also switch
    // the current tab onto it — surprising, and the reported "the original tab jumps to the requested
    // conversation" bug. `menuNeedsUpdate` and `actionTargets` both key off `clickedRow` (set by AppKit
    // from the right-click location), so the menu still targets the row under the cursor; a right-click
    // inside a multi-selection still acts on the whole selection via that same `clickedRow` fallback.
    override func menu(for event: NSEvent) -> NSMenu? {
        super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        // AppKit normally resolves ⌘A through the standard Edit menu and then invokes
        // `selectAll(_:)` on this responder. Keep the direct-event fallback for the cases where a
        // menu is not tracking (for example, an app-hosted dev window); because this method runs
        // only for the table's first responder, it cannot hijack a text editor's Select All.
        if Self.isSelectAllCommand(event) {
            selectAll(nil)
            return
        }
        // `where` binds to the LAST pattern in a comma-separated case, not to all of them. Written
        // as `case 51, 117 where selectedRow >= 0` the guard covered only ⌦, so plain ⌫ invoked the
        // delete handler with nothing selected — and that handler falls back to `clickedRow`.
        // Guarding inside the case applies one condition to every key it lists.
        switch event.keyCode {
        case 51, 117:                                          // ⌫ / ⌦
            guard selectedRow >= 0 else { return super.keyDown(with: event) }
            onDeleteKey?()
        case 36:                                               // ⏎
            guard selectedRow >= 0 else { return super.keyDown(with: event) }
            onReturnKey?()
        default:
            super.keyDown(with: event)
        }
    }

    override func selectAll(_ sender: Any?) {
        guard let onSelectAll else {
            super.selectAll(sender)
            return
        }
        onSelectAll()
    }

    static func isSelectAllCommand(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
        guard modifiers.contains(.command),
              modifiers.intersection([.option, .control, .shift]).isEmpty,
              event.charactersIgnoringModifiers?.lowercased() == "a"
        else { return false }
        return true
    }
}

// MARK: - NSViewRepresentable

/// A double-click arrives after AppKit has already delivered the first click's row selection. The
/// sidebar uses this receipt to undo that immediate navigation before opening the target in a new
/// tab, preserving Finder-style double-click behavior without delaying every ordinary single click.
struct ConversationTabOpenIntent: Equatable {
    let conversationID: UUID
    let replacedSelection: Bool
    let replacedConversationID: UUID?

    static func resolve(
        conversationID: UUID,
        pendingTargetID: UUID?,
        replacedConversationID: UUID?
    ) -> ConversationTabOpenIntent {
        let replacesSelection = pendingTargetID == conversationID
        return ConversationTabOpenIntent(
            conversationID: conversationID,
            replacedSelection: replacesSelection,
            replacedConversationID: replacesSelection ? replacedConversationID : nil)
    }
}

/// The smallest safe invalidation for one representable update. Typing into the inline editor is
/// SwiftUI state too, but it changes exactly one hosted row; rebuilding every visible host on every
/// keystroke makes rename cost grow with the height of the sidebar.
enum ConversationTableRowRefreshScope: Equatable {
    case none
    case conversations(Set<UUID>)
    case allVisible

    static func resolve(
        semanticPresentationChanged: Bool,
        previousEditingID: UUID?,
        previousEditText: String,
        editingID: UUID?,
        editText: String
    ) -> Self {
        guard !semanticPresentationChanged else { return .allVisible }
        if previousEditingID != editingID {
            let ids = Set([previousEditingID, editingID].compactMap { $0 })
            return ids.isEmpty ? .none : .conversations(ids)
        }
        guard previousEditText != editText, let editingID else { return .none }
        return .conversations([editingID])
    }
}

struct ConversationTable: NSViewRepresentable {
    let conversations: [ConversationSummary] // already workspace/state-filter/search filtered + sorted
    @Binding var selection: Set<UUID>
    /// Incremented by the sidebar overflow menu. The coordinator consumes each token exactly once,
    /// preserving AppKit's native selection timing and excluding section-header rows.
    var selectAllVisibleRequest: UInt64 = 0
    let scale: CGFloat
    let active: ActiveWorkspace
    let now: Date
    /// The active value before a native selection callback mutates SwiftUI state. It lets the
    /// coordinator retain exactly what the first click displaced if a second click follows.
    var activeConversationID: UUID? = nil
    /// Projected launch rows may select one destination, but every mutation/export/window action
    /// waits for the authoritative inventory. This keeps the first click useful without turning a
    /// disposable projection into authority.
    var allowsActions = true
    var requestExportDocument: (
        UUID,
        @escaping @MainActor (
            Result<ConversationMarkdownDocument, ConversationHydrationError>
        ) -> Void
    ) -> Void = { _, completion in completion(.failure(.deleted)) }
    var onOpenInWindow: (UUID) -> Void
    var onOpenInTab: (UUID) -> Void
    var onOpenInTabWithIntent: ((ConversationTabOpenIntent) -> Void)? = nil
    var onDelete: (Set<UUID>) -> Void        // single = immediate, many = confirm (parent policy)
    var onReorder: (ConversationReorderIntent) -> Void
    var allowsReordering = true
    var onSetFavorite: (Set<UUID>, Bool) -> Void
    var onRename: (UUID) -> Void
    var onRegenerateTitle: (UUID) -> Void
    var onCopyTranscript: (UUID) -> Void
    var onMarkRead: (Set<UUID>) -> Void
    var onMarkUnread: (Set<UUID>) -> Void
    var onResumeWait: (UUID) -> Void
    var onCancelWait: (UUID) -> Void
    var onMoveToProject: (Set<UUID>, UUID) -> Void  // (conversations, project) — re-file into a project
    /// Open the new-workspace editor and re-file these conversations into whatever it creates.
    var onMoveToNewProject: (Set<UUID>) -> Void
    var onMoveToWorkspace: (Set<UUID>) -> Bool  // drop from another window into this workspace
    @Binding var editingID: UUID?            // the conversation being inline-renamed (nil = none)
    @Binding var editText: String
    var onCommitRename: (UUID) -> Void       // rename `id` to editText, then clear editingID

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ConversationNSTableView()
        let coord = context.coordinator
        coord.table = table

        let col = NSTableColumn(identifier: .init("conversation"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        // SeparatorRowView owns the complete selected appearance. Plain table style avoids the
        // source-list cell gutters that otherwise cut through its one blue capsule.
        table.useAppOwnedSelectionAppearance()
        // Hosted section rows are transparent. Floating them places their labels over the first
        // conversation row beneath, so keep every header in the table's normal row flow.
        table.floatsGroupRows = false
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false     // deterministic per-kind heights (heightOfRow)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnResizing = false
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.draggingDestinationFeedbackStyle = .sourceList
        table.dataSource = coord
        table.delegate = coord

        // The single `action` is used ONLY to start inline rename when you click an already-selected
        // row (Finder-style) — it fires AFTER selection, so it never cannibalizes click-to-select.
        table.target = coord
        table.action = #selector(Coordinator.singleClicked)
        table.doubleAction = #selector(Coordinator.doubleClicked)

        // Finder/apps copy the generated Markdown file; Trash remains a deliberate conversation
        // delete. The table itself still uses .move for reorder and cross-workspace filing.
        table.setDraggingSourceOperationMask([.copy, .delete], forLocal: false)
        table.setDraggingSourceOperationMask(.move,   forLocal: true)
        table.registerForDraggedTypes([.mechConversationRow])

        let menu = NSMenu(); menu.delegate = coord; table.menu = menu
        table.onDeleteKey = { [weak coord] in
            guard coord?.parent.allowsActions == true,
                  let ids = coord?.selectedConversationIDs(), !ids.isEmpty else { return }
            coord?.parent.onDelete(ids)
        }
        table.onReturnKey = { [weak coord] in
            guard coord?.parent.allowsActions == true else { return }
            let ids = coord?.selectedConversationIDs() ?? []
            if ids.count == 1, let id = ids.first { coord?.parent.onRename(id) }
        }
        table.onSelectAll = { [weak coord] in
            coord?.selectAllVisibleConversations()
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        coord.rows = buildConversationRows(conversations, now: now)
        table.reloadData()
        coord.syncSelection(selection)
        coord.recordPresentationSnapshot()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.adopt(self)
        let newRows = buildConversationRows(conversations, now: now)
        if newRows != coord.rows {
            coord.rows = newRows
            coord.endRenameOrphanedByReload()
            coord.table?.reloadData()
            coord.recordPresentationSnapshot()
        } else {
            coord.refreshVisibleRows(coord.presentationRefreshScope())
        }
        coord.syncSelection(selection)
        coord.performPendingSelectAllVisibleRequest()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        private struct SemanticPresentation: Equatable {
            let conversations: [ConversationSummary]
            let selection: Set<UUID>
            let scale: CGFloat
            let activeIdentity: ObjectIdentifier
            let calendarDay: Date
            let windowIsKey: Bool
        }

        private struct PresentationSnapshot {
            let semantic: SemanticPresentation
            let editingID: UUID?
            let editText: String
        }

        var parent: ConversationTable
        weak var table: ConversationNSTableView?
        var rows: [ConvRow] = []
        private var presentationSnapshot: PresentationSnapshot?
        private var observedEditingID: UUID?
        /// Submit and loss of focus can be delivered back-to-back by the same field editor. Keep
        /// the first terminal action as the owner until SwiftUI publishes a new rename session.
        private var endingRenameID: UUID?
        private var syncing = false
        private var selectionJustChanged = false     // did the last click change the selection?
        private var pendingEditWork: DispatchWorkItem? // delayed inline-rename start (cancelled by dbl-click)
        private struct PendingDoubleClickSelection {
            let targetID: UUID
            let replacedConversationID: UUID?
            let token: UUID
        }
        private var pendingDoubleClickSelection: PendingDoubleClickSelection?
        private var pendingDoubleClickExpiry: DispatchWorkItem?
        private var sharingPicker: NSSharingServicePicker? // retain while its service menu is open
        private var consumedSelectAllVisibleRequest: UInt64

        init(_ parent: ConversationTable) {
            self.parent = parent
            observedEditingID = parent.editingID
            consumedSelectAllVisibleRequest = parent.selectAllVisibleRequest
        }

        func adopt(_ parent: ConversationTable) {
            self.parent = parent
            let editingID = parent.editingID
            if editingID != observedEditingID {
                observedEditingID = editingID
                if editingID != nil { endingRenameID = nil }
            }
        }

        private func currentPresentationSnapshot() -> PresentationSnapshot {
            PresentationSnapshot(
                semantic: SemanticPresentation(
                    conversations: parent.conversations,
                    selection: parent.selection,
                    scale: parent.scale,
                    activeIdentity: ObjectIdentifier(parent.active),
                    calendarDay: Calendar.current.startOfDay(for: parent.now),
                    windowIsKey: table?.window?.isKeyWindow ?? false),
                editingID: parent.editingID,
                editText: parent.editText)
        }

        func recordPresentationSnapshot() {
            presentationSnapshot = currentPresentationSnapshot()
        }

        func presentationRefreshScope() -> ConversationTableRowRefreshScope {
            let next = currentPresentationSnapshot()
            defer { presentationSnapshot = next }
            guard let previous = presentationSnapshot else { return .allVisible }
            return ConversationTableRowRefreshScope.resolve(
                semanticPresentationChanged: previous.semantic != next.semantic,
                previousEditingID: previous.editingID,
                previousEditText: previous.editText,
                editingID: next.editingID,
                editText: next.editText)
        }

        private func convo(_ id: UUID) -> ConversationSummary? {
            parent.conversations.first { $0.id == id }
        }
        private func conversation(atRow r: Int) -> ConversationSummary? {
            guard rows.indices.contains(r), case .conversation(let id) = rows[r] else { return nil }
            return convo(id)
        }
        private var favoriteIDs: Set<UUID> {
            Set(parent.conversations.lazy.filter(\.favorite).map(\.id))
        }
        func localReorderProposal(
            dragging draggedIDs: Set<UUID>,
            proposedRow row: Int,
            operation: NSTableView.DropOperation
        ) -> ConversationReorderProposal? {
            ConversationReorderProposal.resolve(
                rows: rows,
                favoriteIDs: favoriteIDs,
                draggedIDs: draggedIDs,
                proposedRow: row,
                operation: operation)
        }

        @discardableResult
        func acceptLocalReorder(
            dragging draggedIDs: Set<UUID>,
            proposedRow row: Int,
            operation: NSTableView.DropOperation
        ) -> ConversationReorderProposal? {
            guard let proposal = localReorderProposal(
                dragging: draggedIDs,
                proposedRow: row,
                operation: operation
            ) else { return nil }
            parent.onReorder(proposal.intent)
            return proposal
        }

        // MARK: rendering
        @ViewBuilder
        private func rowView(for id: UUID, selected: Bool) -> some View {
            if let summary = convo(id) {
                ConversationRowView(
                    convo: summary,
                    isSelected: selected,
                    selectionIsEmphasized: selectionIsEmphasized(id),
                    now: parent.now,
                    active: parent.active,
                    onToggleFavorite: { [weak self] in
                        guard let self, self.parent.allowsActions else { return }
                        self.parent.onSetFavorite([id], !summary.favorite)
                    },
                    isEditing: parent.editingID == id,
                    editText: Binding(
                        get: { self.parent.editText },
                        set: { self.parent.editText = $0 }),
                    onCommit: { [weak self] in self?.commitRenameIfNeeded(id) },
                    onCancel: { [weak self] in self?.cancelRenameIfNeeded(id) })
                    .environment(\.uiScale, parent.scale)
            }
        }

        private func selectionIsEmphasized(_ id: UUID) -> Bool {
            ConversationRowPresentation.usesAccentSelection(
                windowIsKey: table?.window?.isKeyWindow ?? false)
        }
        func refreshVisibleRows(_ scope: ConversationTableRowRefreshScope) {
            switch scope {
            case .none:
                return
            case .conversations(let ids):
                refreshVisibleRows(ids: ids)
            case .allVisible:
                refreshVisibleRows()
            }
        }

        func refreshVisibleRows(ids: Set<UUID>? = nil) {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            for r in visible.location..<(visible.location + visible.length) where r < rows.count {
                guard case .conversation(let id) = rows[r],
                      ids?.contains(id) ?? true,
                      let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? ConvHostCell
                else { continue }
                let selected = table.selectedRowIndexes.contains(r)
                cell.host(rowView(for: id, selected: selected))
            }
        }

        /// End one rename session at most once. Return can submit and then resign the field editor,
        /// while Escape can resign it after cancellation; both sequences must have one owner.
        func commitRenameIfNeeded(_ id: UUID) {
            guard parent.editingID == id, endingRenameID != id else { return }
            endingRenameID = id
            parent.onCommitRename(id)
        }

        func cancelRenameIfNeeded(_ id: UUID) {
            guard parent.editingID == id, endingRenameID != id else { return }
            endingRenameID = id
            parent.editingID = nil
        }

        // MARK: data source / delegate
        func numberOfRows(in _: NSTableView) -> Int { rows.count }

        func tableView(_ t: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
            switch rows[row] {
            case .header(let s):
                let id = NSUserInterfaceItemIdentifier("header")
                let cell = (t.makeView(withIdentifier: id, owner: self) as? ConvHostCell)
                        ?? { let c = ConvHostCell(); c.identifier = id; return c }()
                cell.convId = nil
                cell.host(ConvSectionHeaderView(section: s).environment(\.uiScale, parent.scale))
                return cell
            case .conversation(let cid):
                let id = NSUserInterfaceItemIdentifier("convo")
                let cell = (t.makeView(withIdentifier: id, owner: self) as? ConvHostCell)
                        ?? { let c = ConvHostCell(); c.identifier = id; return c }()
                cell.convId = cid
                cell.host(rowView(for: cid, selected: t.selectedRowIndexes.contains(row)))
                return cell
            }
        }

        func tableView(_ t: NSTableView, heightOfRow row: Int) -> CGFloat {
            switch rows[row] {
            case .header: return round(26 * parent.scale)
            case .conversation: return round(62 * parent.scale)
            }
        }
        func tableView(_ t: NSTableView, isGroupRow row: Int) -> Bool {
            if case .header = rows[row] { return true }; return false
        }
        func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            if case .conversation = rows[row] {
                return SeparatorRowView()
            }
            return nil
        }
        func tableView(_ t: NSTableView, shouldSelectRow row: Int) -> Bool {
            if case .header = rows[row] { return false }; return true
        }
        func tableView(_ t: NSTableView, selectionIndexesForProposedSelection p: IndexSet) -> IndexSet {
            p.filteredIndexSet { if case .conversation = rows[$0] { return true }; return false }
        }

        // MARK: selection sync
        func tableViewSelectionDidChange(_: Notification) {
            guard !syncing else { return }
            selectionJustChanged = true          // so singleClicked knows this click moved the selection
            let selected = selectedConversationIDs()
            if selected.count == 1,
               let targetID = selected.first,
               targetID != parent.activeConversationID {
                retainDoubleClickOrigin(
                    targetID: targetID,
                    replacedConversationID: parent.activeConversationID)
            } else {
                clearDoubleClickOrigin()
            }
            parent.selection = selected
            refreshVisibleRows()   // re-color text for the new highlight
        }
        func selectedConversationIDs() -> Set<UUID> {
            guard let table else { return [] }
            return Set(table.selectedRowIndexes.compactMap { conversation(atRow: $0)?.id })
        }
        func syncSelection(_ ids: Set<UUID>) {
            guard let table else { return }
            let target = IndexSet(rows.indices.filter {
                if case .conversation(let id) = rows[$0] { return ids.contains(id) }; return false
            })
            guard target != table.selectedRowIndexes else { return }
            clearDoubleClickOrigin()
            syncing = true
            if target.isEmpty { table.deselectAll(nil) }
            else { table.selectRowIndexes(target, byExtendingSelection: false) }
            syncing = false
            refreshVisibleRows()
        }

        /// Select every actual conversation row currently rendered by the sidebar. Section headers
        /// deliberately have no selection identity, and the row model was already constrained by
        /// the current workspace, state filter, and text search before it reached this table.
        func selectAllVisibleConversations() {
            guard let table else { return }
            let targets = IndexSet(rows.indices.filter {
                if case .conversation = rows[$0] { return true }
                return false
            })
            guard !targets.isEmpty else { return }
            table.selectRowIndexes(targets, byExtendingSelection: false)
        }

        /// Header-menu requests arrive during SwiftUI's update pass. Consume the latest token only
        /// after the native rows have been reconciled, so a just-changed search/filter cannot select
        /// an id that is no longer visible.
        func performPendingSelectAllVisibleRequest() {
            guard parent.selectAllVisibleRequest != consumedSelectAllVisibleRequest else { return }
            consumedSelectAllVisibleRequest = parent.selectAllVisibleRequest
            selectAllVisibleConversations()
        }

        /// `reloadData()` rebuilds every hosted row, and the rebuilt SwiftUI `TextField` comes back
        /// WITHOUT focus — so commit-on-blur can never fire again and the editor sits on the row
        /// forever, its ink on the selection fill, reading as a title someone coloured wrong. That is
        /// the reported bug, and the reload behind it is routine: a new conversation, a reorder, a
        /// pin, or a row crossing a date section as time passes all change the row set. A rename
        /// therefore ends AT the reload, keeping what was typed.
        ///
        /// The commit is published on the next runloop turn because this runs inside `updateNSView`,
        /// and `onCommitRename` writes SwiftUI state that this same update is already reading.
        func endRenameOrphanedByReload() {
            guard let id = parent.editingID else { return }
            let stillListed = parent.conversations.contains { $0.id == id }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.editingID == id else { return }
                // A conversation that left the list (deleted, or filed into another workspace) has
                // nothing left to rename; the editor still has to go.
                if stillListed {
                    self.commitRenameIfNeeded(id)
                } else {
                    self.cancelRenameIfNeeded(id)
                }
            }
        }

        // Click an ALREADY-selected row (no selection change) → start inline rename after a short
        // delay. A double-click cancels the pending edit and opens instead (Finder/Mail behavior).
        @objc func singleClicked() {
            guard parent.allowsActions else { return }
            let changed = selectionJustChanged
            selectionJustChanged = false
            guard let t = table, t.clickedRow >= 0,
                  case .conversation(let id) = rows[t.clickedRow],
                  !changed, t.selectedRowIndexes == [t.clickedRow],
                  parent.editingID != id else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.parent.selection == [id] else { return }
                self.parent.editText = self.convo(id)?.displayTitle ?? ""
                self.parent.editingID = id
            }
            pendingEditWork?.cancel(); pendingEditWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }

        // MARK: double-click → window / ⌘ tab
        @objc func doubleClicked() {
            guard parent.allowsActions else { return }
            pendingEditWork?.cancel(); pendingEditWork = nil   // a double-click opens, never renames
            guard let t = table, t.clickedRow >= 0,
                  case .conversation(let id) = rows[t.clickedRow] else { return }
            let displaced = pendingDoubleClickSelection.flatMap {
                $0.targetID == id ? $0 : nil
            }
            clearDoubleClickOrigin()
            let intent = ConversationTabOpenIntent.resolve(
                conversationID: id,
                pendingTargetID: displaced?.targetID,
                replacedConversationID: displaced?.replacedConversationID)
            if let onOpenInTabWithIntent = parent.onOpenInTabWithIntent {
                onOpenInTabWithIntent(intent)
            } else {
                parent.onOpenInTab(id)
            }
        }

        private func retainDoubleClickOrigin(
            targetID: UUID,
            replacedConversationID: UUID?
        ) {
            pendingDoubleClickExpiry?.cancel()
            let pending = PendingDoubleClickSelection(
                targetID: targetID,
                replacedConversationID: replacedConversationID,
                token: UUID())
            pendingDoubleClickSelection = pending
            let work = DispatchWorkItem { [weak self] in
                guard self?.pendingDoubleClickSelection?.token == pending.token else { return }
                self?.pendingDoubleClickSelection = nil
                self?.pendingDoubleClickExpiry = nil
            }
            pendingDoubleClickExpiry = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + NSEvent.doubleClickInterval,
                execute: work)
        }

        private func clearDoubleClickOrigin() {
            pendingDoubleClickExpiry?.cancel()
            pendingDoubleClickExpiry = nil
            pendingDoubleClickSelection = nil
        }

        // MARK: drag source + trash
        func tableView(_ t: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.allowsActions,
                  case .conversation(let id) = rows[row],
                  let summary = convo(id) else {
                return nil // headers undraggable
            }
            return ConversationMarkdownFilePromiseProvider(
                conversationID: id,
                filename: ConversationMarkdownDocument.filename(for: summary.displayTitle),
                requestDocument: parent.requestExportDocument)
        }
        private func draggedIDs(_ pb: NSPasteboard) -> Set<UUID> {
            Set((pb.pasteboardItems ?? []).compactMap {
                $0.string(forType: .mechConversationRow).flatMap(UUID.init(uuidString:))
            })
        }
        func tableView(_ t: NSTableView, draggingSession s: NSDraggingSession,
                       endedAt p: NSPoint, operation: NSDragOperation) {
            guard operation == .delete else { return }   // dropped on the Dock Trash
            let ids = draggedIDs(s.draggingPasteboard)
            if !ids.isEmpty { parent.onDelete(ids) }
        }

        // MARK: swipe actions (Mail-style) — trailing reveals Delete; leading reveals state actions.
        func tableView(_ t: NSTableView, rowActionsForRow row: Int,
                       edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
            guard parent.allowsActions, let c = conversation(atRow: row) else { return [] }
            switch edge {
            case .trailing:
                // Single-row gesture: delete just the swiped conversation (parent policy: one = immediate).
                return [ConversationSwipePresentation.action(
                    style: .destructive,
                    title: "Delete"
                ) { [weak self] _, _ in
                    self?.parent.onDelete([c.id])
                }]
            case .leading:
                let fav = ConversationSwipePresentation.action(
                    style: .regular,
                    title: c.favorite ? "Unpin" : "Pin"
                ) { [weak self] _, _ in
                    self?.parent.onSetFavorite([c.id], !c.favorite)
                    t.rowActionsVisible = false   // collapse the swipe after toggling
                }
                fav.backgroundColor = ConversationSwipePresentation.pinBackgroundColor

                let readState = ConversationSwipePresentation.action(
                    style: .regular,
                    title: ConversationSwipePresentation.readActionTitle(unread: c.unread)
                ) { [weak self] _, _ in
                    guard let self else { return }
                    if c.unread {
                        self.parent.onMarkRead([c.id])
                    } else {
                        self.parent.onMarkUnread([c.id])
                    }
                    t.rowActionsVisible = false
                }
                readState.backgroundColor = .systemBlue
                return [fav, readState]
            @unknown default:
                return []
            }
        }

        // MARK: drag destination — cross-window workspace move + intra-list reorder
        func tableView(_ t: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            guard parent.allowsActions else { return [] }
            let dragged = draggedIDs(info.draggingPasteboard)
            guard !dragged.isEmpty else { return [] }
            if (info.draggingSource as? NSTableView) === t {
                guard parent.allowsReordering,
                      let proposal = localReorderProposal(
                        dragging: dragged,
                        proposedRow: row,
                        operation: op) else {
                    return []
                }
                if proposal.aboveTableRow != row || op != .above {
                    t.setDropRow(proposal.aboveTableRow, dropOperation: .above)
                }
                return .move
            }
            return .move
        }
        func tableView(_ t: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard parent.allowsActions else { return false }
            let dragged = draggedIDs(info.draggingPasteboard)
            guard !dragged.isEmpty else { return false }
            guard (info.draggingSource as? NSTableView) === t else {
                return parent.onMoveToWorkspace(dragged)
            }
            guard parent.allowsReordering,
                  acceptLocalReorder(
                    dragging: dragged,
                    proposedRow: row,
                    operation: dropOperation) != nil else {
                return false
            }
            return true
        }

        // MARK: context menu
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard parent.allowsActions,
                  let t = table, t.clickedRow >= 0,
                  let c = conversation(atRow: t.clickedRow) else { return }
            populate(menu, clicked: c, targets: actionTargets(clicked: c.id))
        }

        /// Split out of `menuNeedsUpdate` so the built menu can be inspected without an AppKit
        /// right-click: `clickedRow` is set by the event system and cannot be staged from a test,
        /// which is how a bulk item once shipped carrying the wrong target set unnoticed.
        @MainActor
        func populate(
            _ menu: NSMenu,
            clicked c: ConversationSummary,
            targets bulkTargets: Set<UUID>
        ) {
            func add(_ title: String, _ sel: Selector, _ obj: Any, separatorAfter: Bool = false) {
                let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                it.target = self; it.representedObject = obj; menu.addItem(it)
                if separatorAfter { menu.addItem(.separator()) }
            }
            func addEnabled(_ title: String, _ sel: Selector, _ obj: Any, enabled: Bool,
                            separatorAfter: Bool = false) {
                let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                it.target = self; it.representedObject = obj; it.isEnabled = enabled; menu.addItem(it)
                if separatorAfter { menu.addItem(.separator()) }
            }
            add("Go to Conversation", #selector(miOpenWindow(_:)), c.id)
            add("Open in New Tab",    #selector(miOpenTab(_:)),    c.id, separatorAfter: true)
            if let mutation = ConversationBulkAction.favoriteMutation(
                targets: bulkTargets,
                conversations: parent.conversations
            ) {
                add(
                    ConversationBulkAction.favoriteTitle(
                        favorite: mutation.favorite,
                        count: mutation.conversationIDs.count),
                    #selector(miFavorite(_:)),
                    mutation)
            }
            add("Rename",          #selector(miRename(_:)), c.id)
            addEnabled(
                "Regenerate Title",
                #selector(miRegenerateTitle(_:)),
                c.id,
                enabled: c.hasUserMessage)
            add("Copy Transcript", #selector(miCopy(_:)),   c.id)
            add("Copy Link",       #selector(miCopyLink(_:)), c.id)
            add("Share…",          #selector(miShare(_:)),  c.id)
            add("Save…",           #selector(miSave(_:)),   c.id, separatorAfter: true)
            addEnabled(
                ConversationBulkAction.markReadTitle(count: bulkTargets.count),
                #selector(miMarkRead(_:)),
                Array(bulkTargets),
                enabled: parent.conversations.contains { bulkTargets.contains($0.id) && $0.unread }
            )
            addEnabled(
                ConversationBulkAction.markUnreadTitle(count: bulkTargets.count),
                #selector(miMarkUnread(_:)),
                Array(bulkTargets),
                enabled: parent.conversations.contains { bulkTargets.contains($0.id) && !$0.unread },
                separatorAfter: true
            )
            if c.armedWaitSummary != nil {
                add("Resume Now",  #selector(miResumeWait(_:)), c.id)
                add("Cancel Wait", #selector(miCancelWait(_:)), c.id, separatorAfter: true)
            }
            // Re-file the targeted conversations into another project. This carries the whole bulk
            // target set: moving one row and silently stranding the rest of a multi-selection is the
            // worst outcome available here, because nothing on screen says it happened.
            // "New Workspace…" always leads: conversations that have outgrown wherever they started
            // are exactly when a new workspace is wanted, and it is also the only entry available
            // before any workspace exists — so this submenu no longer hides itself on an empty list.
            if let projects = ConversationMovePresentation.destinationProjects(
                for: bulkTargets,
                conversations: parent.conversations,
                projects: ProjectStore.shared.projects
            ) {
                let moveItem = NSMenuItem(
                    title: ConversationBulkAction.moveTitle(count: bulkTargets.count),
                    action: nil,
                    keyEquivalent: "")
                let sub = NSMenu()
                let newItem = NSMenuItem(
                    title: "New Workspace…",
                    action: #selector(miMoveToNewProject(_:)),
                    keyEquivalent: "")
                newItem.target = self
                newItem.representedObject = Array(bulkTargets)
                sub.addItem(newItem)
                if !projects.isEmpty { sub.addItem(.separator()) }
                let currentProjectIDs: Set<UUID?> = Set(
                    parent.conversations.filter { bulkTargets.contains($0.id) }.map {
                        conversation -> UUID? in
                        guard case .project(let id)? = WorkspaceScope.resolve(
                            summary: conversation,
                            projects: ProjectStore.shared.projects) else { return nil }
                        return id
                    })
                for p in projects {
                    let mi = NSMenuItem(
                        title: p.displayName,
                        action: #selector(miMoveToProject(_:)),
                        keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = ConvProjectMove(
                        convs: Array(bulkTargets),
                        project: p.id)
                    mi.state = ConversationBulkAction.destinationState(
                        targetProjectIDs: currentProjectIDs,
                        destination: p.id)
                    sub.addItem(mi)
                }
                moveItem.submenu = sub
                menu.addItem(moveItem)
            }
            menu.addItem(.separator())
            add(ConversationBulkAction.deleteTitle(count: bulkTargets.count),
                #selector(miDelete(_:)), Array(bulkTargets))
        }
        private struct ConvProjectMove { let convs: [UUID]; let project: UUID }
        @objc private func miMoveToProject(_ s: NSMenuItem) {
            if let m = s.representedObject as? ConvProjectMove {
                parent.onMoveToProject(Set(m.convs), m.project)
            }
        }
        @objc private func miMoveToNewProject(_ s: NSMenuItem) {
            if let ids = s.representedObject as? [UUID] { parent.onMoveToNewProject(Set(ids)) }
        }
        private func actionTargets(clicked id: UUID) -> Set<UUID> {
            ConversationBulkAction.targets(clicked: id, selection: selectedConversationIDs())
        }
        private func id(_ s: Any?) -> UUID? { (s as? NSMenuItem)?.representedObject as? UUID }
        @objc private func miOpenWindow(_ s: NSMenuItem) { id(s).map(parent.onOpenInWindow) }
        @objc private func miOpenTab(_ s: NSMenuItem)    { id(s).map(parent.onOpenInTab) }
        @objc private func miFavorite(_ s: NSMenuItem) {
            guard let mutation = s.representedObject as? ConversationBulkAction.FavoriteMutation
            else { return }
            parent.onSetFavorite(mutation.conversationIDs, mutation.favorite)
        }
        @objc private func miRename(_ s: NSMenuItem)     { id(s).map(parent.onRename) }
        @objc private func miRegenerateTitle(_ s: NSMenuItem) {
            id(s).map(parent.onRegenerateTitle)
        }
        @objc private func miCopy(_ s: NSMenuItem)       { id(s).map(parent.onCopyTranscript) }
        // A menu action always fires on the main thread, so this can state the isolation the
        // pasteboard write needs rather than hopping and losing the click's ordering.
        @MainActor @objc private func miCopyLink(_ s: NSMenuItem) {
            if let id = id(s) { MechanicianURL.copyLink(to: .conversation(id)) }
        }
        @objc private func miShare(_ s: NSMenuItem) {
            guard let conversationID = id(s), let table else { return }
            let row = table.clickedRow
            let rowRect = row >= 0 ? table.rect(ofRow: row) : table.visibleRect
            let anchor = NSRect(x: rowRect.maxX - 18, y: rowRect.midY, width: 1, height: 1)
            parent.requestExportDocument(conversationID) { [weak self, weak table] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.showExportError(error)
                case .success(let document):
                    do {
                        let url = try ConversationMarkdownExport.temporaryFile(
                            for: document,
                            conversationID: conversationID)
                        let picker = NSSharingServicePicker(items: [url])
                        self.sharingPicker = picker
                        // Wait for the context menu to close before opening the system sharing
                        // picker. The anchor was captured before asynchronous hydration because
                        // AppKit clears `clickedRow` when the menu closes.
                        DispatchQueue.main.async { [weak self, weak table] in
                            guard let self, let table,
                                  self.sharingPicker === picker else { return }
                            picker.show(relativeTo: anchor, of: table, preferredEdge: .maxX)
                        }
                    } catch {
                        self.showExportError(error)
                    }
                }
            }
        }
        @objc private func miSave(_ s: NSMenuItem) {
            guard let conversationID = id(s) else { return }
            parent.requestExportDocument(conversationID) { [weak self, weak table] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.showExportError(error)
                case .success(let document):
                    let panel = NSSavePanel()
                    panel.title = "Save Conversation"
                    panel.prompt = "Save"
                    panel.nameFieldStringValue = document.filename
                    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
                    panel.canCreateDirectories = true
                    panel.isExtensionHidden = false

                    let completion: (NSApplication.ModalResponse) -> Void = {
                        [weak self] response in
                        guard response == .OK, let url = panel.url else { return }
                        do {
                            try ConversationMarkdownExport.write(document, to: url)
                        } catch {
                            self?.showExportError(error)
                        }
                    }
                    if let window = table?.window {
                        panel.beginSheetModal(for: window, completionHandler: completion)
                    } else {
                        panel.begin(completionHandler: completion)
                    }
                }
            }
        }
        private func showExportError(_ error: Error) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t Export Conversation"
            NSLog("[export] conversation export failed: %@", error.localizedDescription)
            // `String(localized:)` rather than a bare literal: AppKit does no automatic
            // localization, so an alert set from a Swift literal can never be translated.
            alert.informativeText = String(localized: """
                Mechanician could not write the file. Check that the destination still exists \
                and that you can write to it.
                """)
            alert.addButton(withTitle: "OK")
            if let window = table?.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
        @objc private func miMarkRead(_ s: NSMenuItem) {
            if let ids = (s.representedObject as? [UUID]) { parent.onMarkRead(Set(ids)) }
        }
        @objc private func miMarkUnread(_ s: NSMenuItem) {
            if let ids = (s.representedObject as? [UUID]) { parent.onMarkUnread(Set(ids)) }
        }
        @objc private func miResumeWait(_ s: NSMenuItem) { id(s).map(parent.onResumeWait) }
        @objc private func miCancelWait(_ s: NSMenuItem) { id(s).map(parent.onCancelWait) }
        @objc private func miDelete(_ s: NSMenuItem) {
            if let ids = (s.representedObject as? [UUID]) { parent.onDelete(Set(ids)) }
        }
    }
}

/// Product-owned Workspaces carry provider authority, not filing metadata. Generic conversation
/// moves may organize ordinary Workspaces, but must never turn that organizational action into a
/// Memory/Help profile transition. The lower WorkspaceAdoption boundary independently enforces the
/// same rule for drags, intents, stale menus, and future callers.
enum ConversationMovePresentation {
    static func destinationProjects(
        for conversationIDs: Set<UUID>,
        conversations: [ConversationSummary],
        projects: [Project]
    ) -> [Project]? {
        guard !conversationIDs.isEmpty else { return nil }
        let summaries = conversations.filter { conversationIDs.contains($0.id) }
        guard summaries.count == conversationIDs.count,
              summaries.allSatisfy({ !ReservedWorkspace.owns($0.workspaceID) }) else {
            return nil
        }
        return projects.filter { !ReservedWorkspace.owns($0.id) }
    }
}
