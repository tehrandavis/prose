import ProseCore
import SwiftUI

/// A small typeset cover identifies a complete editable example, separate from templates.
struct SampleBookCard: View {
    var book: SampleBook = .sicp
    var isAdding: Bool = false
    var compact = false
    let add: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("SICP").font(.system(size: 21, weight: .regular, design: .serif)).tracking(1)
                Rectangle().fill(Theme.text.opacity(0.35)).frame(width: 22, height: 1)
                Text("λ").font(.system(size: 30, weight: .light, design: .serif)).foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                Text("SECOND EDITION").font(.system(size: compact ? 4 : 5, weight: .medium))
                    .tracking(compact ? 0.1 : 0.5)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }.padding(13).frame(width: compact ? 76 : 96, height: compact ? 112 : 132, alignment: .leading)
                .background(
                    Theme.background,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: 2,
                        bottomLeadingRadius: 2,
                        bottomTrailingRadius: 6,
                        topTrailingRadius: 6,
                    ),
                )
                .overlay(alignment: .leading) { Rectangle().fill(Theme.text.opacity(0.1)).frame(width: 3) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.text("Explore a complete book")).font(.system(size: 10)).foregroundStyle(Theme.muted)
                Text(book.title).font(.system(size: compact ? 15 : 17, weight: .medium, design: .serif)).fixedSize(
                    horizontal: false,
                    vertical: true,
                )
                if !compact {
                    Text(L10n.text("Read, edit and make it yours. Code, equations and illustrations included."))
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(
                            horizontal: false,
                            vertical: true,
                        )
                }
                HStack(spacing: 12) {
                    Button(action: add) {
                        HStack(spacing: 6) {
                            if isAdding {
                                ProgressView().controlSize(.mini)
                            } else {
                                PhosphorIcon(name: "plus", size: 12)
                            }
                            Text(L10n.text(isAdding ? "Adding book…" : "Add to my writing"))
                        }.font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(Theme.border.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).disabled(isAdding).accessibilityIdentifier("sample-book-add")
                    if !compact {
                        Text(L10n.text("1.9 MB · downloads once")).font(.system(size: 9)).foregroundStyle(Theme.muted)
                    }
                }.padding(.top, 4)
                if compact {
                    Text(L10n.text("1.9 MB · downloads once")).font(.system(size: 9)).foregroundStyle(Theme.muted)
                }
                Link("Abelson & Sussman · CC BY-SA 4.0", destination: book.sourceURL)
                    .font(.system(size: 9)).foregroundStyle(Theme.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(18).frame(height: compact ? 176 : nil).background(
            Theme.panel.opacity(0.5),
            in: RoundedRectangle(cornerRadius: 8),
        )
    }
}
