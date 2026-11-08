import Foundation

/// Native one-chord shortcuts coexist with the command's discoverable leader path.
public struct DirectShortcut: Equatable, Sendable {
    public enum Modifier: Sendable { case command, shift, option, control }
    public let key: String
    public let modifiers: Set<Modifier>
    public init(_ key: String, modifiers: Set<Modifier> = [.command]) {
        self.key = key
        self.modifiers = modifiers
    }

    public var label: String {
        let symbols: [(Modifier, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + key.uppercased()
    }
}
