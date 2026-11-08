import AppKit

@MainActor
final class WritingWindow: NSWindow {
    weak var workspace: Workspace?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        workspace?.recordKeyEvent(event, stage: "shortcut")
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            workspace?.recordKeyEvent(event, stage: "dispatch")
        }
        // AppKit delivers window events on the main thread. Handle them in its
        // native responder path, without an event-monitor executor assertion.
        if event.type == .keyDown, attachedSheet == nil, let workspace {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == workspace.commandKey {
                if (firstResponder as? NSTextView)?.hasMarkedText() != true {
                    workspace.togglePalette()
                }
                return
            }
            if workspace.handlePaletteKey(event) {
                return
            }
            if event.keyCode == 53, workspace.assistance != nil,
               (firstResponder as? NSTextView)?.hasMarkedText() != true
            {
                workspace.dismissAssistance()
                return
            }
            if event.keyCode == 53, workspace.checksOpen,
               (firstResponder as? NSTextView)?.hasMarkedText() != true
            {
                workspace.checksOpen = false
                return
            }
            if event.keyCode == 53, workspace.sidePanel != nil,
               (firstResponder as? NSTextView)?.isFieldEditor != true,
               (firstResponder as? NSTextView)?.hasMarkedText() != true
            {
                workspace.sidePanel = nil
                return
            }
        }
        super.sendEvent(event)
    }
}
