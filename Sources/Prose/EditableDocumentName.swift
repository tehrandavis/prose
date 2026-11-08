import AppKit
import ProseCore
import SwiftUI

struct EditableDocumentName: NSViewRepresentable {
    let title: String
    let documentID: UUID?
    var fontSize: CGFloat = 12
    var identifier = "document-title"
    var help = "Click to rename. Double-click to open your writing."
    var onOpen: () -> Void
    var onRename: (String) -> Void
    var onFinish: (() -> Void)?

    func makeNSView(context: Context) -> DocumentTitleField {
        DocumentTitleField()
    }

    func updateNSView(_ field: DocumentTitleField, context: Context) {
        field.update(title: title, documentID: documentID)
        field.font = .systemFont(ofSize: fontSize, weight: .medium)
        field.onOpenLibrary = onOpen
        field.onRename = onRename
        field.onFinish = onFinish
        field.setAccessibilityIdentifier(identifier)
        field.setAccessibilityLabel(L10n.text("Current Document"))
        field.setAccessibilityHelp(L10n.text(help))
    }
}

/// Delay the single click by the system's double-click interval so opening the
/// library never flashes a text editor first. Editing uses AppKit's field editor.
@MainActor
final class DocumentTitleField: NSTextField, NSTextFieldDelegate {
    var onOpenLibrary: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onFinish: (() -> Void)?
    private(set) var renaming = false
    private var documentID: UUID?
    private var originalTitle = ""
    private var pendingClick: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        isBezeled = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        font = .systemFont(ofSize: 12, weight: .medium)
        textColor = Theme.nativeText
        lineBreakMode = .byTruncatingMiddle
        usesSingleLineMode = true
        focusRingType = .none
        delegate = self
        setAccessibilityIdentifier("document-title")
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, documentID: UUID?) {
        if self.documentID != documentID {
            pendingClick?.cancel()
            finish(commit: false)
        }
        self.documentID = documentID
        if !renaming {
            stringValue = title
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !renaming else {
            super.mouseDown(with: event)
            return
        }
        pendingClick?.cancel()
        if event.clickCount >= 2 {
            onOpenLibrary?()
            return
        }
        pendingClick = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval)) } catch { return }
            guard let self, window != nil else {
                return
            }
            guard documentID != nil else {
                onOpenLibrary?()
                return
            }
            originalTitle = stringValue
            renaming = true
            isEditable = true
            isSelectable = true
            selectText(nil)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finish(commit: false)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finish(commit: true)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finish(commit: true, restoreFocus: false)
    }

    private func finish(commit: Bool, restoreFocus: Bool = true) {
        guard renaming else {
            return
        }
        let title = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = false
        // End the field editor before resetting the label or publishing metadata.
        abortEditing()
        isEditable = false
        isSelectable = false
        stringValue = originalTitle
        if commit, !title.isEmpty, title != originalTitle {
            onRename?(title)
        }
        if restoreFocus {
            onFinish?()
        }
    }
}
