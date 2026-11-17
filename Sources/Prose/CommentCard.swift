import AppKit
import ProseCore
import SwiftUI

/// What one card shows and what the writer is typing in it. The overlay
/// keeps it while the card is out of view.
@MainActor
final class CommentCardModel: ObservableObject {
    /// The fields of a card.
    enum Field: Equatable {
        case draft
        case reply
        case edit
    }

    /// What the card's height depends on.
    struct LayoutKey: Equatable {
        let comment: CommentIndex.Comment?
        let kind: CommentCardItem.Kind
        let active: Bool
        let editing: NSRange?
        let typed: [String]
        let author: String
    }

    let id: String
    @Published var comment: CommentIndex.Comment?
    @Published var kind: CommentCardItem.Kind = .attached
    @Published var isActive = false
    @Published var draftAuthor = ""
    @Published var draftText = ""
    @Published var replyText = ""
    /// The entry being edited, by its record's range, and its new text.
    @Published var editing: CommentIndex.Entry?
    @Published var editText = ""
    /// A request for the keyboard: the field, and a count that changes with
    /// each request.
    @Published var focus: (field: Field, request: Int)?

    init(id: String) {
        self.id = id
    }

    var layoutKey: LayoutKey {
        LayoutKey(
            comment: comment,
            kind: kind,
            active: isActive,
            editing: editing?.range,
            typed: [draftText, replyText, editText],
            author: draftAuthor,
        )
    }

    /// Whether the writer typed something not posted yet.
    var holdsTyping: Bool {
        !draftText.isEmpty || !replyText.isEmpty || editing != nil
    }

    func requestFocus(_ field: Field) {
        focus = (field, (focus?.request ?? 0) + 1)
    }

    func reset() {
        draftText = ""
        replyText = ""
        editing = nil
        editText = ""
        focus = nil
    }
}

/// The date of an entry as a card shows it: in the Mac's time zone, as a
/// short date such as "15 Nov, 14:02" (decision 5).
enum CommentDate {
    static func text(_ timestamp: String, timeZone: TimeZone = .current) -> String {
        guard let date = CommentSyntax.date(timestamp) else {
            return timestamp
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter.string(from: date)
    }
}

/// One comment's card (decision 6): the first entry's author, date and text,
/// the replies under a hairline, and on the active card a Reply field, a
/// Resolve or Reopen button and a menu with Edit and Delete per entry. A
/// damaged comment or one whose text was deleted says so and offers Attach
/// to Selection and Delete.
struct CommentCardView: View {
    @ObservedObject var model: CommentCardModel
    /// Weak: the overlay owns the card's view, which owns this.
    private let owner: WeakCommentOverlay

    init(model: CommentCardModel, overlay: CommentOverlay) {
        self.model = model
        owner = WeakCommentOverlay(overlay)
    }

    private var overlay: CommentOverlay? {
        owner.value
    }

    static let radius: CGFloat = 8

    private var workspace: Workspace? {
        overlay?.workspace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.kind == .draft {
                draft
            } else if let comment = model.comment {
                thread(comment)
            }
        }
        .padding(10)
        .frame(width: CommentOverlay.cardWidth, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Self.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius)
                .strokeBorder(model.isActive ? Theme.accent : Theme.border, lineWidth: 1),
        )
        .contentShape(RoundedRectangle(cornerRadius: Self.radius))
        .simultaneousGesture(TapGesture().onEnded { workspace?.activateComment(model.id, reveal: true) })
        .accessibilityAddTraits(.isButton)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let first = model.comment?.entries.first else {
            return L10n.text("New comment")
        }
        return L10n.format("Comment by %@", first.author)
    }

    // MARK: Parts

    private var draft: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.draftAuthor).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            field(.draft, text: $model.draftText, placeholder: L10n.text("Add a comment"))
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L10n.text("Cancel")) { workspace?.cancelDraft() }
                    .accessibilityLabel(L10n.text("Cancel"))
                Button(L10n.text("Post")) { workspace?.postDraft() }
                    .disabled(model.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(L10n.text("Post"))
            }.controlSize(.small)
        }
    }

    private func thread(_ comment: CommentIndex.Comment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if comment.state == .damaged || model.kind == .emptyAnchor {
                problem(comment)
            }
            ForEach(Array(comment.entries.enumerated()), id: \.offset) { offset, entry in
                if offset > 0 {
                    Rectangle().fill(Theme.border).frame(height: 1).accessibilityHidden(true)
                }
                self.entry(entry, of: comment, first: offset == 0)
            }
            if model.isActive {
                if comment.isResolved {
                    HStack {
                        Text(L10n.text("Resolved")).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        Spacer(minLength: 0)
                        iconButton("arrow-counter-clockwise", L10n.text("Reopen")) {
                            workspace?.reopenComment(comment.id)
                        }
                    }
                } else {
                    field(.reply, text: $model.replyText, placeholder: L10n.text("Reply"))
                    HStack(spacing: 6) {
                        iconButton("check-circle", L10n.text("Resolve")) { workspace?.resolveComment(comment.id) }
                        Spacer(minLength: 0)
                        if !model.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button(L10n.text("Reply")) { workspace?.postReply(to: comment.id) }
                                .controlSize(.small)
                                .accessibilityLabel(L10n.text("Post Reply"))
                        }
                    }
                }
            }
        }
    }

    private func problem(_ comment: CommentIndex.Comment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(comment.state == .damaged ? L10n.text("The marked text is damaged") :
                L10n.text("The marked text was deleted"))
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            HStack(spacing: 8) {
                Button(L10n.text("Attach to Selection")) { workspace?.attachComment(comment.id) }
                Button(L10n.text("Delete")) { workspace?.deleteComment(comment.id) }
            }.controlSize(.small)
        }
    }

    private func entry(_ entry: CommentIndex.Entry, of comment: CommentIndex.Comment, first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.author).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(CommentDate.text(entry.date)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if model.isActive {
                    Menu {
                        Button(L10n.text("Edit")) { workspace?.beginEdit(comment.id, entry: entry) }
                        Button(L10n.text("Delete")) {
                            if first {
                                workspace?.deleteComment(comment.id)
                            } else {
                                workspace?.deleteReply(comment.id, entry: entry)
                            }
                        }
                    } label: {
                        PhosphorIcon(name: "dots-three", size: 16).foregroundStyle(Theme.secondary)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(L10n.text("Comment Actions"))
                }
            }
            if model.editing?.range == entry.range {
                field(.edit, text: $model.editText, placeholder: L10n.text("Edit"))
            } else {
                Text(entry.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func iconButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                PhosphorIcon(name: icon, size: 16)
                Text(title).font(.system(size: 11))
            }.foregroundStyle(Theme.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func field(_ field: CommentCardModel.Field, text: Binding<String>, placeholder: String) -> some View {
        CommentTextField(
            text: text,
            placeholder: placeholder,
            identifier: "comment.field.\(model.id).\(field)",
            focus: model.focus?.field == field ? model.focus?.request ?? 0 : 0,
            onSubmit: { submit(field) },
            onCancel: { cancel(field) },
            onChange: { overlay?.cardContentChanged(model.id) },
        )
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Theme.editor, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
    }

    private func submit(_ field: CommentCardModel.Field) {
        switch field {
        case .draft: workspace?.postDraft()
        case .reply: workspace?.postReply(to: model.id)
        case .edit: workspace?.saveEdit(model.id)
        }
    }

    private func cancel(_ field: CommentCardModel.Field) {
        switch field {
        case .draft: workspace?.cancelDraft()
        case .reply:
            model.replyText = ""
            workspace?.returnKeyboardToEditor()
        case .edit:
            model.editing = nil
            model.editText = ""
            workspace?.returnKeyboardToEditor()
        }
        overlay?.cardContentChanged(model.id)
    }
}

/// A weak reference to the overlay, for the cards it owns.
final class WeakCommentOverlay {
    weak var value: CommentOverlay?

    init(_ value: CommentOverlay) {
        self.value = value
    }
}

/// A card's text field: wraps, Return makes a new line, `⌘Return` posts and
/// `Esc` cancels (decision 7).
struct CommentTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let identifier: String
    /// Takes the keyboard when this changes to a value above zero.
    let focus: Int
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onChange: () -> Void

    func makeNSView(context: Context) -> CommentFieldView {
        let field = CommentFieldView()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    func updateNSView(_ field: CommentFieldView, context: Context) {
        context.coordinator.parent = self
        field.submit = onSubmit
        field.cancel = onCancel
        if field.stringValue != text {
            field.stringValue = text
        }
        if focus > 0, focus != context.coordinator.focus {
            context.coordinator.focus = focus
            Task { @MainActor in
                field.window?.makeFirstResponder(field)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: CommentFieldView, context _: Context) -> CGSize? {
        let width = proposal.width ?? (CommentOverlay.cardWidth - 32)
        let height = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10000)).height ?? 18
        return CGSize(width: width, height: max(18, ceil(height)))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommentTextField
        var focus = 0

        init(_ parent: CommentTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }
            parent.text = field.stringValue
            parent.onChange()
        }

        func control(_: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                    parent.onSubmit()
                } else {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

/// The AppKit field behind `CommentTextField`: plain text that wraps, at
/// 13 pt, with `⌘Return` caught before the menus see it.
@MainActor
final class CommentFieldView: NSTextField {
    var submit: (() -> Void)?
    var cancel: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 190, height: 18))
        font = .systemFont(ofSize: 13)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = false
        lineBreakMode = .byWordWrapping
        cell?.wraps = true
        cell?.isScrollable = false
        maximumNumberOfLines = 0
        allowsEditingTextAttributes = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if currentEditor() != nil, modifiers == .command, event.keyCode == 36 || event.keyCode == 76 {
            submit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
