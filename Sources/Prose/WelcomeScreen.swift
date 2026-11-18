import AppKit
import ProseCore
import SwiftUI

/// What a row of the welcome screen does. Each action is the one the File
/// menu item of the same name calls; a recent opens as the blank page's
/// sidebar and File › Open Recent open it.
enum WelcomeAction: Equatable {
    case newDocument
    case openFolder
    case newFromTemplate
    case openFile
    case recent(LibraryRow)

    /// The action's name in the operation log; a recent's name and path stay out.
    var name: String {
        switch self {
        case .newDocument: "newDocument"
        case .openFolder: "openFolder"
        case .newFromTemplate: "newFromTemplate"
        case .openFile: "openFile"
        case .recent(.folder): "recentFolder"
        case .recent(.document): "recentDocument"
        }
    }
}

extension Workspace {
    /// At most this many recents show, folders first.
    static let welcomeRecentLimit = 8

    /// The recents the welcome screen lists: the blank page's recents
    /// (`recents()`), cut to `welcomeRecentLimit` rows.
    var welcomeRows: [LibraryRow] {
        Array(recents(documentLimit: Self.welcomeRecentLimit).rows.prefix(Self.welcomeRecentLimit))
    }

    /// Shows the welcome screen over the window. The page beneath gives up
    /// the keyboard, so typing does not reach it while the card is up and Tab
    /// reaches the rows.
    func showWelcome() {
        guard !showsWelcome else {
            return
        }
        recordOperation("welcome.show")
        closePalette()
        checksOpen = false
        showsWelcome = true
        window?.makeFirstResponder(nil)
    }

    /// The close button, Escape or a click outside the card. The page beneath
    /// takes the keyboard back, ready to type in.
    func closeWelcome() {
        guard showsWelcome else {
            return
        }
        showsWelcome = false
        if let editor, let window, window.attachedSheet == nil {
            window.makeFirstResponder(editor)
        }
    }

    /// A row of the welcome screen: the screen closes first.
    func performWelcome(_ action: WelcomeAction) {
        recordOperation("welcome.action", ["action": action.name])
        closeWelcome()
        switch action {
        case .newDocument: newDocument()
        case .openFolder: openFolderPanel()
        case .newFromTemplate: newFromTemplate()
        case .openFile: openPanel()
        case let .recent(row): openLibraryRow(row)
        }
    }
}

/// The welcome screen: a wide card over the window, shown once at launch over
/// the blank page and again from Window › Welcome to Prose. The left column,
/// on the page colour, holds the app icon, the name, the version and the
/// start actions; the right column, on the sidebar colour, the recents.
struct WelcomeScreen: View {
    @ObservedObject var workspace: Workspace
    /// Observed so the recents follow the library.
    @ObservedObject private var library: LibraryController
    @StateObject private var hover = RowHover()

    static let cardSize = CGSize(width: 760, height: 465)
    static let actionsWidth: CGFloat = 480

    init(workspace: Workspace) {
        self.workspace = workspace
        library = workspace.library
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture { workspace.closeWelcome() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(L10n.text("Close Welcome"))
                .accessibilityIdentifier("welcome.backdrop")
            card
        }
    }

    private var card: some View {
        HStack(spacing: 0) {
            actions
                .frame(width: Self.actionsWidth)
                .frame(maxHeight: .infinity)
                .background(Theme.editor)
            Rectangle().fill(Theme.border).frame(width: 1)
            recents
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.panel)
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
        // Intent's `PanelCard` shadow, as on the preview's page cards.
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        // A click inside the card stops at the card, never at the backdrop.
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(L10n.format("Welcome to %@", AppDistribution.current.applicationName))
        .accessibilityIdentifier("welcome")
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

    private var actions: some View {
        VStack(spacing: 0) {
            HStack {
                Button { workspace.closeWelcome() } label: {
                    PhosphorIcon(name: "x", size: 10).foregroundStyle(Theme.secondary)
                        .frame(width: 20, height: 20)
                        .background(Theme.hover, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.border))
                        .contentShape(Circle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("Close Welcome"))
                    .accessibilityIdentifier("welcome.close")
                    .help(L10n.text("Close Welcome"))
                Spacer()
            }.padding(.leading, 14).padding(.top, 14)
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable().interpolation(.high).frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(AppDistribution.current.applicationName)
                .font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.text)
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.format("Version %@", version))
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .padding(.top, 2)
                .accessibilityIdentifier("welcome.version")
            VStack(spacing: 10) {
                actionRow(.newDocument, icon: "file-plus", title: L10n.text("New Document"), id: "new")
                actionRow(.openFolder, icon: "folder-open", title: L10n.text("Open Folder…"), id: "folder")
                actionRow(.newFromTemplate, icon: "layout", title: L10n.text("New from Template…"), id: "template")
                actionRow(.openFile, icon: "file-text", title: L10n.text("Open File…"), id: "file")
            }.padding(.top, 24).padding(.horizontal, 40)
            Text(L10n.text("Press Esc or click outside to go back to the page."))
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 14).padding(.horizontal, 40)
            Spacer(minLength: 0)
        }
    }

    private func actionRow(_ action: WelcomeAction, icon: String, title: String, id: String) -> some View {
        Button { workspace.performWelcome(action) } label: {
            HStack(spacing: 10) {
                PhosphorIcon(name: icon, size: 16).foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).frame(height: 36)
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 8))
            .openRow("welcome.action." + id, hover: hover, radius: 8)
        }.buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityIdentifier("welcome.action." + id)
    }

    private var recents: some View {
        let rows = workspace.welcomeRows
        return VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("Recent"))
                .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                .padding(.horizontal, 20).padding(.top, 44).padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text(L10n.text("Nothing recent yet"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("welcome.recent.empty")
            } else {
                VStack(spacing: 2) {
                    ForEach(rows) { row in
                        recentRow(row)
                    }
                }.padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
        }
    }

    private func recentRow(_ row: LibraryRow) -> some View {
        let item = WelcomeRecent(row)
        return Button { workspace.performWelcome(.recent(row)) } label: {
            HStack(spacing: 10) {
                PhosphorIcon(name: item.icon, size: 16).foregroundStyle(Theme.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        .lineLimit(1).truncationMode(.middle)
                    Text(item.path).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 40)
            .openRow("welcome." + row.id, hover: hover)
        }.buttonStyle(.plain)
            .help(item.fullPath)
            .accessibilityLabel(item.label)
            .accessibilityIdentifier("welcome." + row.id)
    }
}

/// How one recent reads on the welcome screen: its name, its path with the
/// home folder as `~`, an icon and a VoiceOver label.
struct WelcomeRecent: Equatable {
    let title: String
    let path: String
    let fullPath: String
    let icon: String
    let label: String

    init(_ row: LibraryRow) {
        switch row {
        case let .folder(record):
            title = record.name
            fullPath = record.path
            icon = "folder-simple"
            label = L10n.format("%@, folder", record.name)
        case let .document(document):
            title = document.title
            fullPath = document.folderURL.path
            icon = "file-text"
            label = L10n.format("%@, document", document.title)
        }
        path = Self.abbreviated(fullPath)
    }

    /// The path with the home folder as `~`.
    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else {
            return path
        }
        return "~" + path.dropFirst(home.count)
    }
}
