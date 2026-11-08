import AppKit
import SwiftUI

struct PaletteTextField: NSViewRepresentable {
    @Binding var text: String
    let label: String
    var placeholder = ""
    var autoFocus = true
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> FocusTextField {
        let field = FocusTextField()
        field.focusOnAttach = autoFocus
        field.stringValue = text
        field.placeholderString = placeholder
        field.isBezeled = false
        field.drawsBackground = false
        field.textColor = Theme.nativeText
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.focusRingType = .none
        field.setAccessibilityLabel(label)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        return field
    }

    func updateNSView(_ field: FocusTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        field.setAccessibilityLabel(label)
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteTextField
        init(_ parent: PaletteTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField {
                parent.text = field.stringValue
            }
        }

        @objc func submit() {
            parent.onSubmit()
        }
    }
}

@MainActor final class FocusTextField: NSTextField {
    var focusOnAttach = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, focusOnAttach else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window else {
                return
            }
            window.makeFirstResponder(self)
            selectText(nil)
        }
    }
}
