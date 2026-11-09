import ProseCore
import SwiftUI

struct BuiltInTemplateCard: View {
    let template: BuiltInTemplate
    var isCreating: Bool
    var compact = false
    let create: () -> Void

    @MainActor private static let thumbnail = WelcomeDocument.thumbnailURL.flatMap(NSImage.init(contentsOf:))

    var body: some View {
        Button(action: create) {
            HStack(spacing: 18) {
                if template == .welcome, let image = Self.thumbnail {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: compact ? 72 : 92, height: compact ? 112 : 130)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .accessibilityHidden(true)
                } else {
                    PhosphorIcon(name: "file-plus", size: 24).foregroundStyle(Theme.secondary)
                        .frame(width: 36)
                }
                VStack(alignment: .leading, spacing: 7) {
                    if template == .welcome {
                        Text(L10n.text("Start here")).font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                    Text(template.title).font(.system(
                        size: template == .welcome ? (compact ? 19 : 20) : 14,
                        weight: .medium,
                        design: .serif,
                    ))
                    .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text(template == .welcome
                            ? "A small guide to Prose, with equations, a diagram and code. Make it your own."
                            : "Just a page and your next thought."))
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(
                            horizontal: false,
                            vertical: true,
                        )
                    if template == .welcome {
                        Text(L10n.text("Included · works offline"))
                            .font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.top, 5)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                PhosphorIcon(name: "arrow-right", size: 16).foregroundStyle(Theme.secondary)
            }.padding(template == .welcome ? 18 : 16)
                .frame(height: compact ? 176 : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(isCreating)
            .accessibilityIdentifier("universe.builtin.\(template.rawValue)")
            .learningHelp(L10n
                .text(template == .welcome ? "Create your own copy of the Prose guide" : "Start with a blank page"))
    }
}
