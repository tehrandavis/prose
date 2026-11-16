import AppKit
import Foundation
@testable import ProseApp
import ProseCore
import SwiftUI
import Testing

/// Phase 7 step A, acceptance tests 1 to 4: open rows highlight under the
/// pointer and when selected, open on one click, work from the keyboard in the
/// "Your writing…" sheet, and are buttons for VoiceOver. Hover is set through
/// `RowHover.set`; no test posts mouse-moved events.
extension WritingFlowTests {
    /// Acceptance test 1.
    @Test func openRowsHighlightUnderThePointerAndWhenSelected() async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        let folder = try openRowThesis(in: app.root)
        #expect(app.workspace.openFolder(folder))
        let hover = app.workspace.sidebarHover
        let root = try #require(app.window.contentView)
        let main = "item:" + folder.appendingPathComponent("main.typ").path
        let figures = "item:" + folder.appendingPathComponent("figures").path
        let others = ["sections", "references.bib"].map { "item:" + folder.appendingPathComponent($0).path }

        // The fill the style resolves: selection wins over hover.
        #expect(OpenRowStyle.fill(hovered: false, selected: false, selection: Theme.sidebarSelection) == .clear)
        #expect(OpenRowStyle.fill(hovered: true, selected: false, selection: Theme.sidebarSelection) == Theme.hover)
        #expect(OpenRowStyle.fill(hovered: true, selected: true, selection: Theme.sidebarSelection) == Theme
            .sidebarSelection)
        #expect(OpenRowStyle.fill(hovered: false, selected: true, selection: Theme.selection) == Theme.selection)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            app.window.appearance = NSAppearance(named: appearance)
            hover.set(nil)
            await app.layout()
            let areas = openRowAreas(root)
            for id in [main, figures] + others {
                let area = try #require(areas[id], "No open row \(id) in \(areas.keys.sorted())")
                #expect(area.bounds.height == 26, "\(id) is \(area.bounds.height) pt high")
            }
            let page = try swatch(Theme.nativeBackground, in: root)
            let selectionFill = try swatch(Theme.nativeSidebarSelection, in: root)
            let hoverFill = try swatch(Theme.nativeHover, in: root, over: Theme.nativeBackground)
            var before: [String: [Int]] = [:]
            for id in [figures] + others {
                before[id] = try rowColour(root, #require(areas[id]))
                #expect(near(before[id] ?? [], page), "\(appearance.rawValue) \(id): \(before[id] ?? []) not \(page)")
            }
            let open = try rowColour(root, #require(areas[main]))
            #expect(near(open, selectionFill), "\(appearance.rawValue): open file \(open), not \(selectionFill)")

            hover.set(figures)
            await app.layout()
            let hovered = try rowColour(root, #require(openRowAreas(root)[figures]))
            #expect(near(hovered, hoverFill), "\(appearance.rawValue): hovered \(hovered), not \(hoverFill)")
            for id in others {
                let colour = try rowColour(root, #require(openRowAreas(root)[id]))
                #expect(colour == before[id], "\(appearance.rawValue) \(id) changed to \(colour)")
            }
            #expect(try rowColour(root, #require(openRowAreas(root)[main])) == open)

            // Selection wins over hover.
            hover.set(main)
            await app.layout()
            #expect(try near(rowColour(root, #require(openRowAreas(root)[main])), selectionFill))
            #expect(try rowColour(root, #require(openRowAreas(root)[figures])) == before[figures])
        }

        // The pointer's own path: entering one row and leaving another in
        // either order leaves the row the pointer is in.
        hover.set(nil)
        hover.pointer(figures, inside: true)
        hover.pointer(main, inside: true)
        hover.pointer(figures, inside: false)
        #expect(hover.id == main)
        // A hovered row that disappears leaves no highlight.
        let sections = folder.appendingPathComponent("sections")
        app.workspace.toggleProjectFolder(sections)
        await app.layout()
        let method = "item:" + sections.appendingPathComponent("method.typ").path
        hover.set(method)
        app.workspace.toggleProjectFolder(sections)
        await app.layout()
        #expect(!app.workspace.sidebarRows.contains { $0.id == method })
        #expect(hover.id == nil, "The hidden row \(hover.id ?? "") stayed hovered")
    }

    /// Acceptance test 2.
    @Test func yourWritingRowsOpenOnOneClick() async throws {
        let app = try WritingFixture(text: "= Keep the manuscript\n", startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        let library = app.workspace.library
        await library.start()
        try await library.create(title: "Notebook", text: "= Notebook\n")
        let notebook = try #require(app.workspace.managedDocumentID)
        try await library.create(title: "Scratch", text: "= Scratch\n")
        let scratch = try #require(app.workspace.managedDocumentID)
        try await library.create(title: "Field notes", text: "= Field notes\n")
        let fieldNotes = try #require(app.workspace.managedDocumentID)
        let folder = try openRowThesis(in: app.root)
        #expect(app.workspace.openFolder(folder))
        try await library.open(fieldNotes)
        await app.layout()

        // A click on a hovered row's trash button trashes it and opens nothing.
        let sheet = try await openYourWriting(app, rows: 4)
        let content = try #require(sheet.contentView)
        let scratchArea = try #require(openRowAreas(content)[LibraryRow.documentID(scratch)])
        app.workspace.libraryHover.set(LibraryRow.documentID(scratch))
        await app.layout()
        let scratchFrame = scratchArea.convert(scratchArea.bounds, to: nil)
        let trash = try #require(descendantViews(content).compactMap { $0 as? HelpAnchor }.first {
            $0.title == L10n.text("Move to Trash") && scratchFrame.contains($0.convert(
                NSPoint(x: $0.bounds.midX, y: $0.bounds.midY),
                to: nil,
            ))
        })
        try openRowClick(sheet, trash, x: 0.5)
        try await app.wait { library.documents.first { $0.id == scratch }?.isTrashed == true && !library.busy }
        #expect(app.workspace.managedDocumentID == fieldNotes)
        #expect(app.window.attachedSheet === sheet)
        try await app.wait { app.workspace.libraryRows.rows.count == 3 }

        // One click on a document's title opens it and closes the sheet; no
        // rename starts.
        let notebookRow = LibraryRow.documentID(notebook)
        #expect(!descendantViews(content).contains { $0 is DocumentTitleField }, "Rows rename from the menu only")
        try openRowClick(sheet, #require(openRowAreas(content)[notebookRow]), x: 0.1)
        try await app.wait { app.workspace.managedDocumentID == notebook && !library.busy }
        try await app.wait { app.window.attachedSheet == nil }
        #expect(!app.workspace.libraryOpen)
        #expect(try await library.store.read(notebook).document.title == "Notebook")
        #expect(app.workspace.editor?.string == "= Notebook\n")

        // One click on a folder row opens the folder.
        let again = try await openYourWriting(app, rows: 3)
        let record = try #require(app.workspace.projectStore.recent().first)
        let againContent = try #require(again.contentView)
        try openRowClick(again, #require(openRowAreas(againContent)["folder:" + record.id.uuidString]), x: 0.5)
        try await app.wait { app.workspace.project?.root.path == folder.path && app.window.attachedSheet == nil }
        #expect(app.workspace.fileURL == folder.appendingPathComponent("main.typ"))
        #expect(!app.workspace.libraryOpen)
    }

    /// Acceptance test 3.
    @Test func yourWritingRowsWorkFromTheKeyboard() async throws {
        let app = try WritingFixture(text: "= Keep the manuscript\n", startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        app.window.appearance = NSAppearance(named: .aqua)
        let library = app.workspace.library
        await library.start()
        let folder = try openRowThesis(in: app.root)
        #expect(app.workspace.openFolder(folder))
        try await library.create(title: "Older", text: "= Older\n")
        let older = try #require(app.workspace.managedDocumentID)
        try await library.create(title: "Newer", text: "= Newer\n")
        let newer = try #require(app.workspace.managedDocumentID)
        let record = try #require(app.workspace.projectStore.recent().first)
        let sheet = try await openYourWriting(app, rows: 3)
        let rows = app.workspace.libraryRows
        try await app.wait { rows.rows.count == 3 }
        let order = rows.rows.map(\.id)
        #expect(order.first == "folder:" + record.id.uuidString, "Folders come first")
        #expect(Set(order.dropFirst()) == [LibraryRow.documentID(older), LibraryRow.documentID(newer)])
        // The open document's row is selected when the sheet opens.
        #expect(rows.selected == LibraryRow.documentID(newer))

        let content = try #require(sheet.contentView)
        let field = try #require(descendantViews(content).compactMap { $0 as? FocusTextField }.first)
        try await app.wait { sheet.firstResponder === field.currentEditor() }
        func press(_ characters: String, _ code: UInt16) {
            let arrow = code == 125 || code == 126
            sheet.sendEvent(sheetKey(sheet, characters, code: code, modifiers: arrow ? [.numericPad, .function] : []))
        }
        let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey)).map(Character.init) ?? " ")
        let up = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey)).map(Character.init) ?? " ")

        let first = try #require(order.firstIndex { $0 == rows.selected })
        press(down, 125)
        #expect(rows.selected == order[min(first + 1, 2)])
        press(up, 126)
        press(up, 126)
        press(up, 126)
        #expect(rows.selected == order[0], "The selection stops at the first row")
        press(down, 125)
        press(down, 125)
        press(down, 125)
        #expect(rows.selected == order[2], "The selection stops at the last row")

        // The selected row draws the selection fill.
        await app.layout()
        let page = try swatch(Theme.nativeEditor, in: content)
        let selectionFill = try swatch(Theme.nativeSelection, in: content)
        let areas = openRowAreas(content)
        let selectedColour = try rowColour(content, #require(areas[order[2]]), inset: 90)
        let otherColour = try rowColour(content, #require(areas[order[1]]), inset: 90)
        #expect(near(selectedColour, selectionFill), "Selected row \(selectedColour), not \(selectionFill)")
        #expect(near(otherColour, page), "Unselected row \(otherColour), not \(page)")

        // With no selection, Down selects the first row.
        rows.selected = nil
        press(down, 125)
        #expect(rows.selected == order[0])
        press(down, 125)

        // Typing still goes to the search field and keeps the selection.
        press("z", 6)
        #expect(field.stringValue == "z")
        #expect(rows.selected == order[1])
        #expect(sheet.firstResponder === field.currentEditor())
        field.currentEditor()?.selectAll(nil)
        field.currentEditor()?.delete(nil)
        try await app.wait { rows.rows.count == 3 }

        // Return opens the selected row and closes the sheet.
        let target = try #require(rows.selectedRow)
        guard case let .document(document) = target else {
            Issue.record("Row \(target.id) is not a document")
            return
        }
        press("\r", 36)
        try await app.wait { app.workspace.managedDocumentID == document.id && app.window.attachedSheet == nil }
        #expect(!app.workspace.libraryOpen)

        // In Trash, Return opens nothing.
        rows.opensRows = false
        rows.selected = target.id
        #expect(!app.workspace.openLibrarySelection())
        rows.opensRows = true
    }

    /// Acceptance test 4. The recents rows on a blank page are step D's.
    @Test func openRowsAreButtonsForVoiceOver() async throws {
        let app = try WritingFixture(text: "= Keep the manuscript\n", startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        let library = app.workspace.library
        await library.start()
        try await library.create(title: "Notes", text: "= Notes\n")
        let notes = try #require(app.workspace.managedDocumentID)
        let folder = try openRowThesis(in: app.root)
        #expect(app.workspace.openFolder(folder))
        app.workspace.outline = [
            OutlineItem(title: "Thesis", level: 1, offset: 0),
            OutlineItem(title: "Aims", level: 2, offset: 10),
        ]
        await app.layout()

        // The sidebar: files and folders are buttons that name their kind;
        // the open file is selected. Headings are buttons too.
        let root = try #require(app.window.contentView)
        // SwiftUI builds its accessibility tree only for an assistive app;
        // VoiceOver asks for it through this attribute.
        let setter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        NSApp.perform(setter, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        defer { NSApp.perform(setter, with: NSNumber(value: false), with: "AXEnhancedUserInterface") }
        var sidebar: [AXNode] = []
        try await app.wait {
            root.layoutSubtreeIfNeeded()
            sidebar = AXNode.tree(root)
            return sidebar.contains { $0.identifier == "sidebar.heading.1" }
        }
        func element(_ identifier: String, in tree: [AXNode]) throws -> AXNode {
            try #require(
                tree.first { $0.identifier == identifier },
                "No accessibility element \(identifier) in \(tree.compactMap(\.identifier))",
            )
        }
        let mainRow = try element("sidebar.row.main.typ", in: sidebar)
        #expect(mainRow.role == NSAccessibility.Role.button.rawValue)
        #expect(mainRow.label == "main.typ, file")
        #expect(mainRow.selected)
        let sectionsRow = try element("sidebar.row.sections", in: sidebar)
        #expect(sectionsRow.role == NSAccessibility.Role.button.rawValue)
        #expect(sectionsRow.label == "sections, folder")
        #expect(!sectionsRow.selected)
        let heading = try element("sidebar.heading.1", in: sidebar)
        #expect(heading.role == NSAccessibility.Role.button.rawValue)
        #expect(heading.label == "Aims, heading")

        // The sheet: one element per row, a button that names its kind; the
        // open document's row is selected, and its trash action is there.
        try await library.open(notes)
        let sheet = try await openYourWriting(app, rows: 2)
        let content = try #require(sheet.contentView)
        var tree: [AXNode] = []
        try await app.wait {
            content.layoutSubtreeIfNeeded()
            tree = AXNode.tree(content)
            return tree.contains { $0.identifier == "library.document.\(notes)" }
        }
        let record = try #require(app.workspace.projectStore.recent().first)
        let folderRow = try element("library.folder.Thesis", in: tree)
        #expect(folderRow.role == NSAccessibility.Role.button.rawValue)
        #expect(folderRow.label == "\(record.name), folder")
        #expect(!folderRow.selected)
        let documentRow = try element("library.document.\(notes)", in: tree)
        #expect(documentRow.role == NSAccessibility.Role.button.rawValue)
        let label = documentRow.label ?? ""
        #expect(label.hasPrefix("Notes, document, edited "), "Label: \(label)")
        #expect(documentRow.selected)
        #expect(documentRow.actions.contains(L10n.text("Move to Trash")), "Actions: \(documentRow.actions)")
        #expect(
            documentRow.children.isEmpty,
            "The row is one element: its title, snippet and date are not separate",
        )
        #expect(!tree.contains { $0.label == L10n.text("Move to Trash") }, "The trash button is the row's action")
        let label2h = LibraryBrowser.label(
            title: "Notes",
            modifiedAt: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 7200),
        )
        #expect(label2h == "Notes, document, edited 2 hours ago")
        app.workspace.libraryOpen = false
        try await app.wait { app.window.attachedSheet == nil }
    }

    private func openRowThesis(in root: URL) throws -> URL {
        let folder = root.appendingPathComponent("Thesis")
        let manager = FileManager.default
        try manager.createDirectory(at: folder.appendingPathComponent("sections"), withIntermediateDirectories: true)
        try manager.createDirectory(at: folder.appendingPathComponent("figures"), withIntermediateDirectories: true)
        try Data("= Thesis\n".utf8).write(to: folder.appendingPathComponent("main.typ"))
        try Data("= Method\n".utf8).write(to: folder.appendingPathComponent("sections/method.typ"))
        try Data("@book{a, title={A}}".utf8).write(to: folder.appendingPathComponent("references.bib"))
        return folder.standardizedFileURL
    }
}

/// Opens the "Your writing…" sheet over a document and returns its window
/// once its rows are laid out.
@MainActor
private func openYourWriting(_ app: WritingFixture, rows: Int) async throws -> NSWindow {
    app.workspace.openLibrary()
    try await app.wait { app.window.attachedSheet != nil }
    let sheet = try #require(app.window.attachedSheet)
    try await app.wait {
        sheet.contentView?.layoutSubtreeIfNeeded()
        return app.workspace.libraryRows.rows.count == rows && openRowAreas(sheet.contentView).count >= rows
    }
    return sheet
}

@MainActor
private func descendantViews(_ view: NSView?) -> [NSView] {
    guard let view else {
        return []
    }
    return [view] + view.subviews.flatMap { descendantViews($0) }
}

/// Each open row's pointer area, by row id: the row's frame on screen.
@MainActor
private func openRowAreas(_ view: NSView?) -> [String: NSView] {
    var areas: [String: NSView] = [:]
    for case let area as OpenRowArea in descendantViews(view) where area.window != nil {
        areas[area.rowID] = area
    }
    return areas
}

/// A click on a row at `x` (a fraction of its width) through the window, as
/// AppKit delivers it.
@MainActor
private func openRowClick(_ window: NSWindow, _ area: NSView, x: CGFloat) throws {
    let point = area.convert(NSPoint(x: area.bounds.width * x, y: area.bounds.midY), to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        try window.sendEvent(#require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1,
        )))
    }
}

@MainActor
private func sheetKey(
    _ window: NSWindow,
    _ characters: String,
    code: UInt16,
    modifiers: NSEvent.ModifierFlags,
) -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: code,
    ) else {
        preconditionFailure("Could not create a test key event")
    }
    return event
}

/// The colour drawn at `inset` points from the row's right end, at its
/// vertical middle, in sRGB 0 to 255.
@MainActor
private func rowColour(_ root: NSView, _ area: NSView, inset: CGFloat = 26) throws -> [Int] {
    let rect = area.convert(area.bounds, to: root)
    let sample = NSRect(x: rect.maxX - inset - 1, y: rect.midY - 1, width: 2, height: 2).integral
    let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: sample))
    root.cacheDisplay(in: sample, to: bitmap)
    let colour = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
        .usingColorSpace(.sRGB))
    return [colour.redComponent, colour.greenComponent, colour.blueComponent].map { Int(($0 * 255).rounded()) }
}

/// The colour `fill` composed over the opaque `base` reads as when drawn
/// in `root` and read back as `rowColour` reads a row: the bitmap holds
/// display colours, so the expected colour goes through the same path.
@MainActor
private func swatch(_ fill: NSColor, in root: NSView, over base: NSColor? = nil) throws -> [Int] {
    let view = Swatch(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
    view.fill = fill
    view.base = base
    root.addSubview(view)
    defer { view.removeFromSuperview() }
    view.display()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let colour = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
        .usingColorSpace(.sRGB))
    return [colour.redComponent, colour.greenComponent, colour.blueComponent].map { Int(($0 * 255).rounded()) }
}

private final class Swatch: NSView {
    var fill = NSColor.clear
    var base: NSColor?

    override func draw(_ dirtyRect: NSRect) {
        if let base {
            base.setFill()
            bounds.fill()
        }
        fill.setFill()
        bounds.fill(using: .sourceOver)
    }
}

private func near(_ left: [Int], _ right: [Int], within tolerance: Int = 3) -> Bool {
    left.count == 3 && right.count == 3 && zip(left, right).allSatisfy { abs($0 - $1) <= tolerance }
}

/// One element of the accessibility tree as an assistive app reads it.
/// SwiftUI's elements answer the informal NSAccessibility getters but are not
/// `NSAccessibilityProtocol` values in Swift, so the getters go through KVC.
@MainActor
private struct AXNode {
    let object: NSObject

    private func value(_ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }

    var identifier: String? {
        value("accessibilityIdentifier") as? String
    }

    var role: String? {
        value("accessibilityRole") as? String
    }

    var label: String? {
        value("accessibilityLabel") as? String
    }

    var selected: Bool {
        object.responds(to: NSSelectorFromString("isAccessibilitySelected"))
            && (object.value(forKey: "accessibilitySelected") as? Bool ?? false)
    }

    var actions: [String] {
        (value("accessibilityCustomActions") as? [NSAccessibilityCustomAction] ?? []).map(\.name)
    }

    var children: [AXNode] {
        (value("accessibilityChildren") as? [Any] ?? []).compactMap { ($0 as? NSObject).map(AXNode.init) }
    }

    /// Every element under `view`, depth first.
    static func tree(_ view: NSView) -> [AXNode] {
        var found: [AXNode] = []
        func walk(_ node: AXNode, depth: Int) {
            guard depth < 40 else {
                return
            }
            found.append(node)
            for child in node.children {
                walk(child, depth: depth + 1)
            }
        }
        walk(AXNode(object: view), depth: 0)
        return found
    }
}
