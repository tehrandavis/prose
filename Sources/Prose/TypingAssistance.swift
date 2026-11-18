import AppKit
import ProseCore

extension ManuscriptTextView {
    func scheduleTypingAssistance() {
        dismissTypingAssistance()
        guard isEditable, !hasMarkedText(), selectedRange().length == 0 else {
            return
        }
        let request = typingRequestID
        typingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled, request == typingRequestID else {
                return
            }
            typingTask = nil
            if !hasMarkedText() {
                workspace?.requestCompletion(automatic: true)
            }
        }
    }

    func dismissTypingAssistance() {
        typingListNavigated = false
        typingTask?.cancel()
        typingTask = nil
        typingRequestID = UUID()
        typingList = CompletionList(items: [], prefix: "")
        typingSignature = nil
        if let typingPanel {
            window?.removeChildWindow(typingPanel)
            typingPanel.orderOut(nil)
        }
        typingPanel = nil
    }

    func presentTypingAssistance(
        _ items: [SourceCompletion], signature: LanguageSignature?, source: String,
        selection: NSRange, requestID: UUID, prefix: String = "",
    ) {
        guard requestID == typingRequestID, string == source, selectedRange() == selection,
              !hasMarkedText(), isEditable
        else {
            return
        }
        typingSource = source
        typingSelection = selection
        typingList = CompletionList(items: items, prefix: prefix)
        typingSignature = signature
        renderTypingAssistance()
    }

    /// Rows that arrive after the list shows, such as Zotero's for `@`:
    /// they go below the others, and the chosen row stays chosen. Dropped
    /// when the writer typed or moved on.
    func appendTypingCompletions(_ rows: [SourceCompletion], requestID: UUID) {
        guard !rows.isEmpty, requestID == typingRequestID, string == typingSource,
              selectedRange() == typingSelection, !hasMarkedText(), isEditable
        else {
            return
        }
        typingList.append(rows)
        renderTypingAssistance()
    }

    private func renderTypingAssistance() {
        guard let window else {
            return
        }
        if typingList.items.isEmpty, typingSignature == nil {
            return
        }
        let panel: NSPanel
        if let existing = typingPanel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = true
            panel.hasShadow = true
            panel.backgroundColor = .windowBackgroundColor
            panel.level = .floating
            typingPanel = panel
            window.addChildWindow(panel, ordered: .above)
        }
        let stack = NSStackView()
        stack.setAccessibilityIdentifier("typing-assistance")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        // Citation rows are two lines tall (after RStudio's), so fewer show.
        let citations = typingList.items.contains { $0.entry != nil }
        let width: CGFloat = citations ? 420 : 360
        let shown = citations ? 6 : 8
        let start = max(0, typingList.index - (shown - 3))
        for index in start ..< min(start + shown, typingList.items.count) {
            let item = typingList.items[index]
            if let entry = item.entry {
                let row = CitationCompletionRow(
                    entry: entry,
                    zotero: workspace?.isZoteroEntry(entry) == true,
                    selected: index == typingList.index,
                    width: width,
                ) { [weak self] in
                    self?.chooseTypingCompletion(at: index)
                }
                row.setAccessibilityIdentifier("completion-item-\(index)")
                stack.addArrangedSubview(row)
                continue
            }
            let button = NSButton(
                title: (index == typingList.index ? "› " : "  ") + item.label,
                target: self,
                action: #selector(chooseTypingCompletion(_:)),
            )
            button.tag = index
            button.isBordered = false
            button.alignment = .left
            button.font = .monospacedSystemFont(ofSize: 12, weight: index == typingList.index ? .semibold : .regular)
            button.setAccessibilityIdentifier("completion-item-\(index)")
            button.widthAnchor.constraint(equalToConstant: width).isActive = true
            stack.addArrangedSubview(button)
        }
        if let selected = typingList.selected, !selected.detail.isEmpty {
            addTypingLabel(String(selected.detail.prefix(240)), to: stack, width: width)
        }
        if let signature = typingSignature {
            addTypingLabel(signature.label, to: stack, width: width)
            if let parameter = signature.activeParameter {
                addTypingLabel(
                    L10n.format("Parameter: %@", parameter),
                    to: stack,
                    width: width,
                )
            }
            if !signature.parameterDocumentation.isEmpty {
                addTypingLabel(String(signature.parameterDocumentation.prefix(240)), to: stack, width: width)
            }
        }
        panel.contentView = stack
        let size = stack.fittingSize
        let caret = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        let screen = window.screen?.visibleFrame ?? window.frame
        let x = min(max(caret.minX, screen.minX), screen.maxX - size.width)
        let y = caret.minY - size.height >= screen.minY ? caret.minY - size.height : caret.maxY
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        panel.orderFront(nil)
    }

    private func addTypingLabel(_ text: String, to stack: NSStackView, width: CGFloat) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 3
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(label)
    }

    func handleTypingKey(_ event: NSEvent) -> Bool {
        guard !hasMarkedText(),
              event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift])
        else {
            return false
        }
        if event.keyCode == 53, typingPanel != nil || typingTask != nil {
            // Only visible assistance consumes Escape. A pending request is cancelled silently,
            // so the key still reaches placeholders and the rest of the editor.
            let visible = typingPanel != nil
            dismissTypingAssistance()
            return visible
        }
        guard typingList.selected != nil else {
            return false
        }
        switch event.keyCode {
        case 125: typingList.move(1)
            typingListNavigated = true
            renderTypingAssistance()
            return true
        case 126: typingList.move(-1)
            typingListNavigated = true
            renderTypingAssistance()
            return true
        // Return and Enter use the chosen item when the writer chose it with
        // the arrow keys, or when the list completes a citation or reference
        // (`@key`). Otherwise Return stays a new line, since the list opens
        // by itself while the writer types.
        case 36 where typingPanel != nil && (typingListNavigated || typingCompletesReference),
             76 where typingPanel != nil && (typingListNavigated || typingCompletesReference):
            if let selected = typingList.selected {
                acceptTypingCompletion(selected)
            }
            return true
        case 48 where !event.modifierFlags.contains(.shift):
            if let selected = typingList.selected {
                acceptTypingCompletion(selected)
            }
            return true
        default: return false
        }
    }

    /// Whether the word at the caret starts with `@`: a citation or a
    /// reference to a label.
    private var typingCompletesReference: Bool {
        let text = string as NSString
        var index = selectedRange().location
        guard selectedRange().length == 0, index <= text.length else {
            return false
        }
        while index > 0 {
            let unit = text.character(at: index - 1)
            if unit == 64 {
                return true
            }
            guard let scalar = Unicode.Scalar(unit),
                  CharacterSet.alphanumerics.contains(scalar) || "_-:.".unicodeScalars.contains(scalar)
            else {
                return false
            }
            index -= 1
        }
        return false
    }

    @objc private func chooseTypingCompletion(_ sender: NSButton) {
        chooseTypingCompletion(at: sender.tag)
    }

    private func chooseTypingCompletion(at index: Int) {
        guard typingList.items.indices.contains(index) else {
            return
        }
        acceptTypingCompletion(typingList.items[index])
    }

    func acceptTypingCompletion(_ item: SourceCompletion) {
        guard typingList.items.contains(item), string == typingSource, selectedRange() == typingSelection,
              !hasMarkedText(), isEditable, let workspace, workspace.text == string
        else {
            return
        }
        if let result = item.zotero, let range = item.edits.first?.range {
            // A Zotero item the project lacks: its entry is exported first,
            // then the citation replaces the typed `@prefix`.
            dismissTypingAssistance()
            workspace.citeZoteroItem(result, replacing: range)
            return
        }
        do {
            let updated = try TextEditing.applying(item.edits, to: string)
            let start = item.edits.map(\.range.location).min() ?? 0
            let end = item.edits.map { NSMaxRange($0.range) }.max() ?? start
            let length = end - start + updated.utf16.count - string.utf16.count
            let replacement = (updated as NSString).substring(with: NSRange(location: start, length: length))
            dismissTypingAssistance()
            insertSnippet(Snippet(text: replacement), replacing: NSRange(location: start, length: end - start))
            setCompletionPlaceholders(item.selections)
            setSelectedRange(item.selections.first ?? NSRange(location: item.insertionEnd, length: 0))
            workspace.selection = selectedRange()
            if item.entry != nil {
                // A citation is finished: compile at once, as the picker
                // does, so the block never shows `??`.
                writing.refreshNow()
                workspace.recordOperation("citation.completed", ["key": item.entry?.key ?? ""])
            } else {
                scheduleTypingAssistance()
            }
        } catch { workspace.showMessage(error.localizedDescription) }
    }
}

/// One row of the `@` list (after RStudio's citation rows): the type icon in
/// a bordered square with a "Z" badge for a Zotero entry, `@key` in the
/// monospaced font with the authors and year at the right, and the title
/// below, cut with an ellipsis. The chosen row has a rounded accent outline
/// and a faint accent fill. A click inserts.
final class CitationCompletionRow: NSView {
    private let selected: Bool
    private let action: () -> Void

    init(entry: BibliographyEntry, zotero: Bool, selected: Bool, width: CGFloat, action: @escaping () -> Void) {
        self.selected = selected
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 48))
        translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView()
        icon.image = IconStore.image(CitationRowStyle.icon(forKind: entry.kind))
        icon.contentTintColor = Theme.nativeSecondary
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let boxBackground = BorderedSquare()
        boxBackground.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(boxBackground)
        box.addSubview(icon)

        let key = Self.label("@" + entry.key, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        key.textColor = Theme.nativeText
        key.lineBreakMode = .byTruncatingMiddle
        let authors = Self.label(entry.authorYearLine, font: .systemFont(ofSize: 11))
        authors.alignment = .right
        authors.lineBreakMode = .byTruncatingTail
        let title = Self.label(entry.title ?? L10n.text("Untitled"), font: .systemFont(ofSize: 11))
        title.lineBreakMode = .byTruncatingTail
        for view in [box, key, authors, title] {
            addSubview(view)
        }
        key.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        authors.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let side = CitationRowStyle.iconBox
        var constraints = [
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 48),
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
            box.widthAnchor.constraint(equalToConstant: side),
            box.heightAnchor.constraint(equalToConstant: side),
            boxBackground.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            boxBackground.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            boxBackground.topAnchor.constraint(equalTo: box.topAnchor),
            boxBackground.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            icon.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            key.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: 10),
            key.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            authors.leadingAnchor.constraint(greaterThanOrEqualTo: key.trailingAnchor, constant: 10),
            authors.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            authors.firstBaselineAnchor.constraint(equalTo: key.firstBaselineAnchor),
            title.leadingAnchor.constraint(equalTo: key.leadingAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: key.bottomAnchor, constant: 3),
        ]
        if zotero {
            let badge = Self.label("Z", font: .systemFont(ofSize: 7, weight: .bold))
            badge.textColor = .white
            badge.alignment = .center
            badge.drawsBackground = true
            badge.backgroundColor = CitationRowStyle.zoteroRed
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 2
            addSubview(badge)
            constraints += [
                badge.widthAnchor.constraint(equalToConstant: 11),
                badge.heightAnchor.constraint(equalToConstant: 11),
                badge.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: 3),
                badge.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: 3),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([
            CitationRowStyle.typeName(forKind: entry.kind), entry.key, entry.authorYearLine, entry.title ?? "",
        ].filter { !$0.isEmpty }.joined(separator: ", "))
        setAccessibilitySelected(selected)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func label(_ text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = Theme.nativeSecondary
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: frame.width, height: 48)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selected else {
            return
        }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        Theme.nativeAccent.withAlphaComponent(0.08).setFill()
        path.fill()
        Theme.nativeAccent.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// The whole row takes the click; its labels do not.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with _: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            action()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

/// The icon's square: the page colour with a hairline border.
private final class BorderedSquare: NSView {
    override func draw(_: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        Theme.nativeEditor.setFill()
        path.fill()
        Theme.nativeBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
