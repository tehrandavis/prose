import AppKit
import ProseCore

/// The recents a blank page offers (Phase 7, decisions 4 and 6): recent
/// folders, most recent first, then recent library documents. The sidebar of
/// an untouched blank page and File › Open Recent both read this one value.
struct SidebarRecents: Equatable {
    static let folderLimit = 5
    static let sidebarDocumentLimit = 8
    static let menuDocumentLimit = 10

    var folders: [ProjectRecord]
    var documents: [LibraryDocument]

    var isEmpty: Bool {
        folders.isEmpty && documents.isEmpty
    }

    /// The rows in the order they show, folders first.
    var rows: [LibraryRow] {
        folders.map(LibraryRow.folder) + documents.map(LibraryRow.document)
    }

    /// The parent folder of a recent folder, with the home folder as `~`:
    /// the row's hover help.
    static func parentPath(_ record: ProjectRecord) -> String {
        (record.path as NSString).deletingLastPathComponent
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

extension LibraryController {
    /// Recent documents: the reopenable recents first (most recently opened),
    /// then the other listed documents by date, newest first. Never the
    /// untouched blank page, never a trashed document.
    func recentDocuments(limit: Int) -> [LibraryDocument] {
        let listed = listedDocuments.filter { !$0.isTrashed }
        let byID = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recent = reopenableRecentIDs.compactMap { byID[$0] }
        let opened = Set(recent.map(\.id))
        // The library's own order: newest first, ties by id.
        let rest = listed.filter { !opened.contains($0.id) }.sorted {
            $0.modifiedAt == $1.modifiedAt ? $0.id.uuidString < $1.id.uuidString : $0.modifiedAt > $1.modifiedAt
        }
        return Array((recent + rest).prefix(limit))
    }
}

extension Workspace {
    /// The sidebar shows recents in place of the file tree while the open
    /// document is the untouched blank page. A blank page has a `.library`
    /// project (its own folder), so this, not `project`, decides.
    var showsSidebarRecents: Bool {
        isOnUntouchedBlankPage
    }

    func recents(documentLimit: Int = SidebarRecents.sidebarDocumentLimit) -> SidebarRecents {
        SidebarRecents(
            folders: Array(projectStore.recent().prefix(SidebarRecents.folderLimit)),
            documents: library.recentDocuments(limit: documentLimit),
        )
    }
}
