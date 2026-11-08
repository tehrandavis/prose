import AppKit
import Combine
import ProseCore
import SwiftUI

/// Native dynamic colors resolve in each view's effective appearance. Keeping
/// them in attributed text lets a theme change repaint without re-highlighting,
/// replacing text, moving the caret, or creating undo operations.
enum Theme {
    static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: NSColor.Name("Prose." + name)) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }

    // Intent tokens (docs/prose-spec.md Section 4.1): Things-style sidebar and
    // page, warm ink and a dusk-violet accent. Muted text is derived, kept at
    // 4.5:1 or better on the page and the sidebar.
    static let nativeBackground = adaptive("background", light: 0xF5F5F7, dark: 0x1A1A1A)
    static let nativeEditor = adaptive("editor", light: 0xFFFFFF, dark: 0x262626)
    static let nativePanel = adaptive("panel", light: 0xF5F5F7, dark: 0x1A1A1A)
    static let nativeBorder = adaptive("border", light: 0xE5E2DD, dark: 0x464646)
    static let nativeText = adaptive("text", light: 0x1A1918, dark: 0xE8E4DE)
    static let nativeSecondary = adaptive("secondary", light: 0x68635E, dark: 0x9C968D)
    static let nativeMuted = adaptive("muted", light: 0x716B65, dark: 0x948E85)
    static let nativeAccent = adaptive("accent", light: 0x7C2494, dark: 0xB784E0)
    static let nativeGreen = adaptive("green", light: 0x5CB85C, dark: 0x5CB85C)
    static let nativeRed = adaptive("red", light: 0xE25555, dark: 0xE25555)
    // Accent at 10 percent on the light page and 22 percent on the dark page.
    static let selection = adaptive("selection", light: 0xF2E9F4, dark: 0x463B4F)
    static let selectedText = adaptive("selectedText", light: 0x1A1918, dark: 0xE8E4DE)

    // Code-mode syntax colours keep LeftBlank's Nano-derived set (spec Section 4.1).
    static let sourceText = adaptive("sourceText", light: 0x37474F, dark: 0xD5D9DE)
    static let sourceStrong = adaptive("sourceStrong", light: 0x263238, dark: 0xEEE8DA)
    static let sourceComment = adaptive("sourceComment", light: 0x637681, dark: 0x7C8793)
    static let sourceString = adaptive("sourceString", light: 0x526D42, dark: 0xA8B89A)
    static let sourceKeyword = adaptive("sourceKeyword", light: 0x673AB7, dark: 0xBEA4C9)
    static let sourceNumber = adaptive("sourceNumber", light: 0x9C5700, dark: 0xD9B97C)
    static let sourceFunction = adaptive("sourceFunction", light: 0x326A83, dark: 0x9DBBCD)
    static let sourceIdentifier = adaptive("sourceIdentifier", light: 0x496B7D, dark: 0xA5B8C8)
    static let sourceCode = adaptive("sourceCode", light: 0x455A64, dark: 0xBAC4CF)
    static let codeBackground = adaptive("codeBackground", light: 0xECEFF1, dark: 0x272D32)

    static let background = Color(nsColor: nativeBackground)
    static let editor = Color(nsColor: nativeEditor)
    static let panel = Color(nsColor: nativePanel)
    static let border = Color(nsColor: nativeBorder)
    static let text = Color(nsColor: nativeText)
    static let secondary = Color(nsColor: nativeSecondary)
    static let muted = Color(nsColor: nativeMuted)
    static let accent = Color(nsColor: nativeAccent)
    static let green = Color(nsColor: nativeGreen)
    static let red = Color(nsColor: nativeRed)

    @MainActor static func apply(_ preference: AppAppearance) {
        switch preference {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Cache the two raster assets and observe AppKit's effective appearance so
/// explicit choices and live system changes use the same Dock update path.
@MainActor
final class DockIconController {
    private var observer: AnyCancellable?
    private let light: NSImage?
    private let dark: NSImage?
    var isAvailable: Bool {
        light != nil && dark != nil
    }

    init() {
        var resources = Bundle.main.resourceURL
        #if DEBUG
            if resources
                .map({ !FileManager.default.fileExists(atPath: $0.appendingPathComponent("AppIcon.icns").path) }) ??
                true
            {
                resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent("Resources")
            }
        #endif
        light = resources.flatMap { NSImage(contentsOf: $0.appendingPathComponent("AppIconLight.icns")) }
        dark = resources.flatMap { NSImage(contentsOf: $0.appendingPathComponent("AppIcon.icns")) }
        update()
        observer = NSApp.publisher(for: \.effectiveAppearance, options: [.new]).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.update() }
        }
    }

    private func update() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if let image = isDark ? dark : light {
            NSApp.applicationIconImage = image
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 255) / 255,
            green: Double((hex >> 8) & 255) / 255,
            blue: Double(hex & 255) / 255,
            opacity: 1,
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255,
            alpha: 1,
        )
    }
}

@MainActor
enum IconStore {
    private static var images: [String: NSImage] = [:]
    private static var missing: Set<String> = []
    static func image(_ name: String) -> NSImage? {
        if let image = images[name] {
            return image
        }
        if missing.contains(name) {
            return nil
        }
        var directory = Bundle.main.resourceURL?.appendingPathComponent("Icons")
        #if DEBUG
            if directory.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
                directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent("Resources/Icons")
            }
        #endif
        guard let url = directory?.appendingPathComponent("\(name).pdf"), let image = NSImage(contentsOf: url) else {
            missing.insert(name)
            return nil
        }
        // Native menu labels may use the NSImage directly and ignore the
        // surrounding SwiftUI frame. PDF assets have a 256 pt artboard.
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        images[name] = image
        return image
    }
}

struct PhosphorIcon: View {
    let name: String
    var size: CGFloat = 18
    var body: some View {
        if let image = IconStore.image(name) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}

struct QuietButton: View {
    let icon: String
    let help: String
    var shortcut: String?
    var detail: String?
    var active = false
    var iconSize: CGFloat = 16
    var hitSize: CGFloat = 30
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            PhosphorIcon(name: icon, size: iconSize).foregroundStyle(active ? Theme.accent : Theme.secondary)
                .frame(width: hitSize, height: hitSize)
                .overlay(alignment: .bottom) {
                    if active {
                        Capsule().fill(Theme.accent).frame(width: 8, height: 1.5).padding(.bottom, 1)
                    }
                }
        }.buttonStyle(QuietControlStyle()).accessibilityLabel(help)
            .accessibilityAddTraits(active ? .isSelected : [])
            .learningHelp(help, shortcut: shortcut, detail: detail)
    }
}

/// One flat interaction treatment for compact controls throughout the app.
/// The hit area stays larger than the glyph; only hover or a press adds a wash.
struct QuietControlStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(
                Theme.secondary.opacity(enabled ? (configuration.isPressed ? 0.14 : (hovering ? 0.08 : 0)) : 0),
                in: RoundedRectangle(cornerRadius: 5),
            )
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }
}

struct Keycap: View {
    let value: String
    var body: some View {
        Text(value).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Theme.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border.opacity(0.7)))
    }
}
