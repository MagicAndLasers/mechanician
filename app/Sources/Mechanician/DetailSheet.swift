import SwiftUI

/// Standard chrome for the app's information sheets.
///
/// Replaces a floating `xmark.circle.fill` pinned to the top-right corner, which is an iOS idiom
/// and read as sloppy on a Mac: it hovered over the content, sat beside a primary button it had no
/// relationship to, and gave no keyboard route out. A Mac sheet ends in a button bar, its default
/// button is the one you press to leave, and Escape closes it.
///
/// Actions supplied by the caller sit to the LEFT of Done, in the platform's trailing-cluster
/// order, so the safe dismissal is always in the same place regardless of what else the sheet offers.
struct DetailSheet<Content: View, Actions: View>: View {
    var width: CGFloat = 520
    var height: CGFloat = 460
    /// Whether to add the standard Done button. A sheet whose own actions already include the way
    /// out — a prompt answered with Deny or Not Now — would otherwise show two ways to dismiss it
    /// and leave the reader deciding which is safe.
    var showsDone = true
    let onClose: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            Divider()
            HStack(spacing: 10) {
                Spacer()
                actions
                // Mechanician's own pill, not SwiftUI's default bordered button. A sheet is not
                // where the app should suddenly look like a stock dialog.
                if showsDone {
                    Button("Done", action: onClose)
                        .buttonStyle(PillButtonStyle(kind: .accent))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: width, height: height)
        .background(Color.nBg)
        // Escape leaves, as it does in every other Mac sheet.
        .onExitCommand(perform: onClose)
    }
}

extension DetailSheet where Actions == EmptyView {
    init(width: CGFloat = 520, height: CGFloat = 460, showsDone: Bool = true,
         onClose: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.init(width: width, height: height, showsDone: showsDone, onClose: onClose,
                  content: content, actions: { EmptyView() })
    }
}
