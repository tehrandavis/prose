import AppKit

/// How wide the text column is in Code and Writing mode (Settings and
/// View › Line Width). Focus mode keeps its own column.
enum LineWidth: String, CaseIterable {
    case narrow
    case medium
    case wide
    case full

    /// The column's width in points; nil lets the column grow with the pane.
    var columnWidth: CGFloat? {
        switch self {
        case .narrow: 560
        case .medium: 680
        case .wide: 820
        case .full: nil
        }
    }

    var title: String {
        switch self {
        case .narrow: "Narrow"
        case .medium: "Medium"
        case .wide: "Wide"
        case .full: "Full"
        }
    }

    static let defaultsKey = "ProseLineWidth"

    /// The stored choice; Full, the column as it always was, when none is stored.
    static var stored: LineWidth {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(LineWidth.init(rawValue:)) ?? .full
    }
}

enum ManuscriptLayout {
    /// The writer's choice of column width. `Workspace.lineWidth` sets it,
    /// on the main thread, where every reader of the layout runs.
    nonisolated(unsafe) static var lineWidth = LineWidth.stored

    /// The smallest margin on each side of the column.
    static let minimumInset: CGFloat = 36
    /// The space above and below the text.
    static let verticalInset: CGFloat = 42
    /// In Focus mode, the space above and below the text as a fraction of
    /// the visible height (decision 5 of the Phase 4 note).
    static let focusVerticalFraction: CGFloat = 0.6
    /// The least space below the text while the floating toolbar can show
    /// (Writing and Focus mode): the toolbar's height and its 16 pt above the
    /// pane's bottom edge, with room to spare (decision 6 of the Phase 4 note).
    static let toolbarClearance: CGFloat = 64

    /// The margin on each side of the column in a pane `paneWidth` wide. In
    /// Focus mode the column is `focusColumnWidth`, never wider than the pane
    /// minus the minimum margins (decision 3 of the Phase 4 note).
    static func horizontalInset(for paneWidth: CGFloat, focus: Bool = false) -> CGFloat {
        if focus {
            let column = min(focusColumnWidth, paneWidth - 2 * minimumInset)
            return max(minimumInset, (paneWidth - column) / 2)
        }
        if let fixed = lineWidth.columnWidth {
            let column = min(fixed, paneWidth - 2 * minimumInset)
            return max(minimumInset, (paneWidth - column) / 2)
        }
        // Keep the familiar column in ordinary panes, then let wider panes
        // use more space while retaining a bounded, centered writing area.
        let preferredWidth = min(1080, max(740, paneWidth * 0.7))
        return max(minimumInset, (paneWidth - preferredWidth) / 2)
    }

    /// Focus mode's measure: 60 average characters of New York at 18 pt.
    static let focusCharacters: CGFloat = 60
    static let focusFontSize: CGFloat = 18

    /// The Focus column's width, measured once from the font.
    static let focusColumnWidth: CGFloat = (focusCharacters * averageCharacterWidth(of: focusFont)).rounded()

    /// New York (the system serif) at 18 pt; Times if the system has no serif design.
    static var focusFont: NSFont {
        let system = NSFont.systemFont(ofSize: focusFontSize)
        let serif = system.fontDescriptor.withDesign(.serif)
        return serif.flatMap { NSFont(descriptor: $0, size: focusFontSize) }
            ?? NSFont(name: "Times New Roman", size: focusFontSize) ?? system
    }

    /// Running English text, spaces and punctuation included, for the average
    /// character width. Dickens, *A Tale of Two Cities* (public domain).
    static let measureSample = "It was the best of times, it was the worst of times, it was the age of wisdom, "
        + "it was the age of foolishness, it was the epoch of belief, it was the epoch of incredulity."

    /// The width of `measureSample` set in `font`, divided by its characters.
    static func averageCharacterWidth(of font: NSFont) -> CGFloat {
        let sample = measureSample as NSString
        let width = sample.size(withAttributes: [.font: font]).width
        return width / CGFloat(sample.length)
    }
}
