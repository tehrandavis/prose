import Foundation

enum ManuscriptLayout {
    static func horizontalInset(for paneWidth: CGFloat) -> CGFloat {
        // Keep the familiar column in ordinary panes, then let wider panes
        // use more space while retaining a bounded, centered writing area.
        let preferredWidth = min(1080, max(740, paneWidth * 0.7))
        return max(36, (paneWidth - preferredWidth) / 2)
    }
}
