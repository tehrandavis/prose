import AppKit
import ProseCore
import SwiftUI

/// The row under the pointer in one list of open rows (decision 5 of the
/// Phase 7 note). The rows set it from `.onHover`; tests call `set(_:)`, so
/// no test needs mouse events.
@MainActor
final class RowHover: ObservableObject {
    @Published private(set) var id: String?

    func set(_ id: String?) {
        if self.id != id {
            self.id = id
        }
    }

    /// The pointer entered or left the row `id`. Leaving clears only that row,
    /// so a late exit never clears the row the pointer moved to, and a row
    /// that disappears while hovered leaves no highlight behind.
    func pointer(_ id: String, inside: Bool) {
        if inside {
            set(id)
        } else if self.id == id {
            set(nil)
        }
    }
}

/// An open row: a row that opens a document, folder, file or heading on one
/// click. It draws the hover wash or the selection fill behind the row, and
/// shows the pointing hand over it. Selection wins over hover.
struct OpenRowStyle: ViewModifier {
    let id: String
    @ObservedObject var hover: RowHover
    var selected = false
    /// `Theme.sidebarSelection` in the sidebar, `Theme.selection` on the page.
    var selection = Theme.sidebarSelection
    /// 6 in the sidebar, 8 in the sheet.
    var radius: CGFloat = 6

    static func fill(hovered: Bool, selected: Bool, selection: Color) -> Color {
        selected ? selection : (hovered ? Theme.hover : .clear)
    }

    func body(content: Content) -> some View {
        content
            .background(
                Self.fill(hovered: hover.id == id, selected: selected, selection: selection),
                in: RoundedRectangle(cornerRadius: radius),
            )
            .background(OpenRowPointer(id: id).accessibilityHidden(true))
            .contentShape(Rectangle())
            .onHover { hover.pointer(id, inside: $0) }
            .onDisappear { hover.pointer(id, inside: false) }
    }
}

extension View {
    func openRow(
        _ id: String,
        hover: RowHover,
        selected: Bool = false,
        selection: Color = Theme.sidebarSelection,
        radius: CGFloat = 6,
    ) -> some View {
        modifier(OpenRowStyle(id: id, hover: hover, selected: selected, selection: selection, radius: radius))
    }
}

/// The pointing hand over an open row. AppKit owns the cursor: macOS 14 has no
/// SwiftUI pointer style. The view takes no clicks, so the row gets them.
private struct OpenRowPointer: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> OpenRowArea {
        OpenRowArea()
    }

    func updateNSView(_ view: OpenRowArea, context: Context) {
        view.rowID = id
    }
}

@MainActor
final class OpenRowArea: NSView {
    /// The row's id, as `RowHover` holds it. Tests find a row's frame by it.
    var rowID = ""

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func isAccessibilityElement() -> Bool {
        false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }
}

/// One row of the "Your writing…" sheet: a recent folder or a document.
enum LibraryRow: Equatable, Identifiable {
    case folder(ProjectRecord)
    case document(LibraryDocument)

    var id: String {
        switch self {
        case let .folder(record): "folder:" + record.id.uuidString
        case let .document(document): Self.documentID(document.id)
        }
    }

    static func documentID(_ id: UUID) -> String {
        "document:" + id.uuidString
    }
}

/// The keyboard selection of the "Your writing…" sheet. The search field
/// keeps the focus; Down and Up move the selection through the rows in the
/// order the sheet shows them, and Return opens the selected row
/// (`Workspace.openLibrarySelection()`).
@MainActor
final class LibraryRowSelection: ObservableObject {
    @Published var selected: String?
    /// The rows the sheet shows, folders first. The sheet keeps it current.
    var rows: [LibraryRow] = []
    /// False in Trash, where rows do not open.
    var opensRows = true

    var selectedRow: LibraryRow? {
        rows.first { $0.id == selected }
    }

    /// With no selection (or one no longer shown), Down selects the first row
    /// and Up the last. The selection stops at either end.
    func moveSelection(by step: Int) {
        guard !rows.isEmpty, step != 0 else {
            return
        }
        if let index = rows.firstIndex(where: { $0.id == selected }) {
            selected = rows[min(max(index + step, 0), rows.count - 1)].id
        } else {
            selected = (step > 0 ? rows.first : rows.last)?.id
        }
    }
}

extension Workspace {
    /// One click on a row of the "Your writing…" sheet, or Return on the
    /// selected row.
    func openLibraryRow(_ row: LibraryRow) {
        switch row {
        case let .folder(record):
            libraryOpen = false
            openRecentFolder(record)
        case let .document(document):
            let library = library
            library.perform { try await library.open(document.id) }
        }
    }

    /// Return in the sheet's search field. False when nothing opens.
    @discardableResult
    func openLibrarySelection() -> Bool {
        guard libraryRows.opensRows, let row = libraryRows.selectedRow else {
            return false
        }
        openLibraryRow(row)
        return true
    }
}
