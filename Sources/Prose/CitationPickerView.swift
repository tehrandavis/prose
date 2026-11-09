import ProseCore
import SwiftUI

/// The citation picker inside the command panel (citations note, decision
/// 4): the entries, a field for a page or section, or the offer to add a
/// `#bibliography` call.
struct CitationPickerPane: View {
    @ObservedObject var workspace: Workspace
    let picker: CitationPicker

    static func hint(_ picker: CitationPicker) -> String {
        switch picker.stage {
        case .list: L10n.text("↑ ↓ to select · ↵ to cite · ⌥↵ to add a page or section · Tab to switch")
        case .supplement: L10n.text("↵ to cite · Esc to go back")
        case .linkBibliography: L10n.text("↵ to add the bibliography · N to cite only · Esc to go back")
        case .zoteroLink: L10n.text("↵ to link · Esc to go back")
        }
    }

    var body: some View {
        switch picker.stage {
        case .list:
            if picker.tab == .zotero {
                ZoteroResultsPane(workspace: workspace)
            } else {
                list
            }
        case let .supplement(entry): supplementForm(entry)
        case let .linkBibliography(entry, _, path): offer(entry, path: path)
        case .zoteroLink: ZoteroLinkForm(workspace: workspace)
        }
    }

    private var list: some View {
        let results = workspace.citationResults
        let index = workspace.bibliographyIndex
        let problems = workspace.citationProblems
        return VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if results.isEmpty {
                            emptyState(
                                loading: picker.loading,
                                noFiles: index.contents.files.isEmpty,
                            )
                        }
                        ForEach(Array(results.enumerated()), id: \.element.key) { offset, entry in
                            CitationRow(entry: entry, selected: offset == workspace.selectedCommandIndex) {
                                workspace.selectedCommandIndex = offset
                                workspace.cite(entry)
                            }.id(entry.key)
                        }
                    }.padding(.trailing, 16)
                }
                .onChange(of: workspace.selectedCommandIndex) { _, _ in
                    if let entry = workspace.highlightedCitation {
                        proxy.scrollTo(entry.key)
                    }
                }
            }
            if !problems.isEmpty {
                HStack(spacing: 6) {
                    PhosphorIcon(name: "warning-circle", size: 12).foregroundStyle(Theme.muted)
                    Text(problems.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.tail)
                }.padding(.bottom, 4)
            }
        }
    }

    private func emptyState(loading: Bool, noFiles: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if loading {
                Text(L10n.text("Reading bibliography files…")).font(.system(size: 12))
            } else if noFiles {
                Text(L10n.text("This project has no bibliography file.")).font(.system(size: 12))
                Text(L10n.text("Add a .bib or .yml file to the project, or create the bibliography call now."))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Button(L10n.text("Add a Bibliography…")) { workspace.createBibliographyFromPicker() }
                    .buttonStyle(.bordered)
            } else {
                Text(L10n.text("No matching sources")).font(.system(size: 12))
                Text(L10n.text("Try an author's family name, a year, a title word or a key."))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func supplementForm(_ entry: BibliographyEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CitationSummary(entry: entry)
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.text("Page or section")).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                PaletteTextField(
                    text: Binding(
                        get: { workspace.citationPicker?.supplement ?? "" },
                        set: { workspace.citationPicker?.supplement = $0 },
                    ),
                    label: L10n.text("Page or section"),
                    placeholder: "p. 4",
                    onSubmit: { workspace.submitSupplement(for: entry) },
                )
                .frame(height: 18).padding(10)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
                .frame(maxWidth: 320)
            }
            Text(CitationInsertion.citation(entry.key, supplement: picker.supplement))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
            Button { workspace.submitSupplement(for: entry) } label: {
                actionLabel(L10n.text("Insert Citation"), key: "↵", primary: true)
            }.buttonStyle(.plain).disabled(workspace.applyingCommand)
        }.padding(.top, 10).padding(.trailing, 24).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func offer(_ entry: BibliographyEntry, path: String) -> some View {
        let main = workspace.compilationURL.lastPathComponent
        let call = "#bibliography(\"\(path)\")"
        return VStack(alignment: .leading, spacing: 14) {
            CitationSummary(entry: entry)
            Text(L10n.text("This document has no bibliography yet, so the citation would not compile."))
                .font(.system(size: 12))
            Text(L10n.format("Add %@ at the end of %@?", call, main))
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            HStack(spacing: 10) {
                Button { workspace.answerBibliographyOffer(add: true) } label: {
                    actionLabel(L10n.text("Add Bibliography and Cite"), key: "↵", primary: true)
                }.buttonStyle(.plain)
                Button { workspace.answerBibliographyOffer(add: false) } label: {
                    actionLabel(L10n.text("Cite Only"), key: "N", primary: false)
                }.buttonStyle(.plain)
            }.disabled(workspace.applyingCommand)
        }.padding(.top, 10).padding(.trailing, 24).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionLabel(_ title: String, key: String, primary: Bool) -> some View {
        HStack(spacing: 14) {
            Text(title)
            Text(key).opacity(0.65)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(primary ? Theme.background : Theme.text)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(primary ? Theme.accent : Theme.border.opacity(0.75), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// One entry: first author, year, title and key.
private struct CitationRow: View {
    let entry: BibliographyEntry
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Text(entry.leadAuthor.isEmpty ? "—" : entry.leadAuthor)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: 130, alignment: .leading)
                Text(entry.year.map(String.init) ?? "")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                    .frame(width: 38, alignment: .leading)
                Text(entry.title ?? "")
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(entry.key)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .trailing)
            }.padding(.horizontal, 12).frame(height: 34).contentShape(Rectangle())
                .background(
                    selected ? Theme.border.opacity(0.75) : (hovered ? Theme.border.opacity(0.35) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 5),
                )
                .overlay(alignment: .leading) {
                    if selected {
                        Capsule().fill(Theme.accent).frame(width: 2, height: 16)
                    }
                }
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityLabel(Text([entry.leadAuthor, entry.year.map(String.init) ?? "", entry.title ?? "", entry.key]
                    .filter { !$0.isEmpty }.joined(separator: ", ")))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The entry an answer is about, in one line.
private struct CitationSummary: View {
    let entry: BibliographyEntry

    var body: some View {
        HStack(spacing: 10) {
            Text([entry.leadAuthor, entry.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
                .font(.system(size: 12, weight: .medium))
            Text(entry.title ?? "").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text(entry.key).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
        }
    }
}

/// The right column: the highlighted entry in full.
struct CitationGuide: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        let entry = workspace.citationPickerEntry
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                PhosphorIcon(name: "file-text", size: 19).foregroundStyle(Theme.accent)
                Text(L10n.text("Cite a Source")).font(.system(size: 12, weight: .medium))
                Spacer()
            }
            if let entry {
                Text(entry.title ?? L10n.text("Untitled")).font(.system(size: 11, weight: .medium)).lineLimit(3)
                if !entry.authors.isEmpty {
                    Text(entry.authors.map(\.display).joined(separator: "; "))
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
                }
                Text([entry.container, entry.year.map(String.init)].compactMap(\.self).joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
                Text(CitationInsertion.citation(entry.key))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 5))
                Text(entry.line > 0 ? "\(entry.file):\(entry.line)" : entry.file)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1)
            } else {
                Text(L10n.text("Entries come from the project's .bib and .yml files. Prose never changes them."))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineSpacing(4)
            }
            Spacer(minLength: 0)
        }.padding(.top, 9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
    }
}
