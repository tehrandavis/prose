import Foundation
@testable import ProseCore
import ProseTestSupport
import Testing

/// A throwaway project folder, removed when the test ends.
private final class BibliographyProject {
    let root: URL

    init(_ files: [String: String]) throws {
        root = TestPaths.temporaryDirectory.appendingPathComponent("bibliography-" + UUID().uuidString)
        for (name, text) in files {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func renderer() async throws -> BlockRenderer {
        try await BlockRenderer(root: root, main: root.appendingPathComponent("main.typ"))
    }
}

private let biblatex = """
@article{smith2020,
  author = {Smith, John and van Gogh, Vincent},
  title = {{The} Shape of Things},
  journal = {Journal of Shapes},
  year = {2020},
  doi = {10.1000/shape},
}

@book{bad,
  title = {Broken Year},
  year = {not a year},
}

@book{ostrom1990,
  editor = {Ostrom, Elinor},
  title = {Governing the Commons},
  year = {1990},
}

"""

private let hayagriva = """
muller2018:
  type: article
  title: Über Bäume
  author: ["Müller, Jürgen"]
  date: 2018
  parent:
    type: periodical
    title: Forest Letters

"""

@MainActor
struct BibliographyIndexTests {
    @Test func theIndexListsEveryKeyWithAuthorYearAndTitleAndReportsAMalformedEntry() async throws {
        let project = try BibliographyProject([
            "main.typ": "See @smith2020.\n\n#bibliography((\"refs.bib\", \"sources/more.yml\"))\n",
            "refs.bib": biblatex,
            "sources/more.yml": hayagriva,
            "unused.bib": "@book{unused, title={Unused}}\n",
        ])
        let renderer = try await project.renderer()
        #expect(await renderer.bibliographyFiles() == ["refs.bib", "sources/more.yml"])

        let index = BibliographyIndex()
        await index.reload(using: renderer, root: project.root)
        #expect(index.isLinked)
        #expect(index.entries.map(\.key) == ["smith2020", "ostrom1990", "muller2018"])
        let smith = try #require(index.entries.first)
        #expect(smith == BibliographyEntry(
            key: "smith2020",
            kind: "article",
            title: "The Shape of Things",
            authors: [.init(family: "Smith", given: "John"), .init(family: "van Gogh", given: "Vincent")],
            year: 2020,
            container: "Journal of Shapes",
            doi: "10.1000/shape",
            file: "refs.bib",
            line: 1,
        ))
        #expect(smith.authors.map(\.display) == ["Smith, J.", "van Gogh, V."])
        let muller = try #require(index.entries.last)
        #expect(muller.title == "Über Bäume" && muller.year == 2018 && muller.file == "sources/more.yml")
        #expect(muller.authors.first?.family == "Müller" && muller.container == "Forest Letters")
        #expect(index.entries.allSatisfy { $0.title != nil && $0.year != nil && !$0.authors.isEmpty })

        // The malformed entry: reported with its file and line; the rest load;
        // the file is marked as one Typst rejects.
        let issue = try #require(index.contents.errors.first)
        #expect(index.contents.errors.count == 1)
        #expect(issue.file == "refs.bib" && issue.line == 11)
        #expect(issue.message.contains("bad"))
        #expect(index.contents.files.map(\.path) == ["refs.bib", "sources/more.yml"])
        #expect(index.contents.files.map(\.accepted) == [false, true])
        #expect(index.contents.files.map(\.entries) == [2, 1])
    }

    @Test func withoutABibliographyCallEveryProjectFileIsListedAsNotLinked() async throws {
        let project = try BibliographyProject([
            "main.typ": "No citations yet.\n",
            "refs.bib": "@book{a, title={A}, author={Ay, B}, year={2001}}\n",
            "data/extra.yaml": "b:\n  type: book\n  title: B\n",
            ".hidden/secret.bib": "@book{hidden, title={H}}\n",
            "notes.txt": "x",
        ])
        #expect(ProjectTree.bibliographyFiles(in: project.root) == ["data/extra.yaml", "refs.bib"])
        let renderer = try await project.renderer()
        #expect(await renderer.bibliographyFiles().isEmpty)
        let index = BibliographyIndex()
        await index.reload(using: renderer, root: project.root)
        #expect(!index.isLinked)
        #expect(index.entries.map(\.key) == ["b", "a"])
        #expect(index.contents.files.allSatisfy { !$0.linked })

        // A project with no bibliography file at all.
        let empty = try BibliographyProject(["main.typ": "Hello\n"])
        let other = BibliographyIndex()
        try await other.reload(using: empty.renderer(), root: empty.root)
        #expect(other.contents == .empty && other.revision == 0)
    }

    @Test func aFileChangedOnDiskAppearsAfterFilesChanged() async throws {
        let project = try BibliographyProject([
            "main.typ": "#bibliography(\"refs.bib\")\n",
            "refs.bib": "@book{a, title={A}}\n",
        ])
        let renderer = try await project.renderer()
        let index = BibliographyIndex()
        await index.reload(using: renderer, root: project.root)
        #expect(index.entries.map(\.key) == ["a"])
        let revision = index.revision

        let refs = project.root.appendingPathComponent("refs.bib")
        try "@book{a, title={A}}\n@book{b, title={B}}\n".write(to: refs, atomically: true, encoding: .utf8)
        await index.reload(using: renderer, root: project.root)
        #expect(index.revision == revision, "the engine serves what it read until told")
        await renderer.filesChanged([refs])
        await index.reload(using: renderer, root: project.root)
        #expect(index.entries.map(\.key) == ["a", "b"])
        #expect(index.revision == revision + 1)

        // An editor buffer for the file wins over the disk.
        try await renderer.setText("@book{buffer, title={In the Editor}}\n", of: refs)
        await index.reload(using: renderer, root: project.root)
        #expect(index.entries.map(\.key) == ["buffer"])
    }

    @Test func searchRanksKeyThenAuthorThenTitleThenAnywhere() {
        let index = BibliographyIndex()
        index.update(BibliographyContents(entries: [
            BibliographyEntry(key: "zeta1999", title: "Notes on Smithing", year: 1999),
            BibliographyEntry(
                key: "doe2001",
                title: "Blacksmith Methods",
                authors: [.init(family: "Doe")],
                year: 2001,
            ),
            BibliographyEntry(key: "lee2010", title: "Unrelated", authors: [.init(family: "Smithers")], year: 2010),
            BibliographyEntry(key: "smith2020", title: "Shapes", authors: [.init(family: "Jones")], year: 2020),
            BibliographyEntry(
                key: "muller2018",
                title: "Über Bäume",
                authors: [.init(family: "Müller", given: "Jürgen"), .init(family: "van Gogh")],
                year: 2018,
                container: "Forest Letters",
            ),
        ]))
        // Key prefix, then author prefix, then title word prefix, then substring.
        #expect(index.search("smith").map(\.key) == ["smith2020", "lee2010", "zeta1999", "doe2001"])
        // Case, diacritics and width are ignored, both ways.
        #expect(index.search("MULLER").map(\.key) == ["muller2018"])
        #expect(index.search("baume").map(\.key) == ["muller2018"])
        #expect(index.search("Über").map(\.key) == ["muller2018"])
        #expect(index.search("ｍüｌｌｅｒ").map(\.key) == ["muller2018"])
        // Each word must match; a family name's own words count as author prefixes.
        #expect(index.search("gogh 2018").map(\.key) == ["muller2018"])
        #expect(index.search("gogh 2019").isEmpty)
        // Year, container and an empty query.
        #expect(index.search("2010").map(\.key) == ["lee2010"])
        #expect(index.search("forest").map(\.key) == ["muller2018"])
        #expect(index.search("  ").count == 5)
        #expect(index.search("", limit: 2).map(\.key) == ["zeta1999", "doe2001"])
        #expect(index.search("smith", limit: 1).map(\.key) == ["smith2020"])
        #expect(index.search("nothing-like-this").isEmpty)
    }

    @Test func theRevisionChangesOnlyWhenTheContentsChange() {
        let index = BibliographyIndex()
        #expect(index.revision == 0)
        let first = BibliographyContents(entries: [BibliographyEntry(key: "a", title: "A")])
        index.update(first)
        #expect(index.revision == 1)
        index.update(first)
        #expect(index.revision == 1)
        index.update(BibliographyContents(entries: [BibliographyEntry(key: "a", title: "A changed")]))
        #expect(index.revision == 2)
        index.update(.empty)
        #expect(index.revision == 3 && index.entries.isEmpty)
        #expect(index.search("a").isEmpty)
    }

    @Test func authorDisplayUsesInitials() {
        #expect(BibliographyEntry.Author(family: "Dubois", given: "Jean-Paul").display == "Dubois, J.-P.")
        #expect(BibliographyEntry.Author(family: "Doe", given: "Jane Q., Jr.").display == "Doe, J. Q.")
        #expect(BibliographyEntry.Author(family: "Plato").display == "Plato")
    }

    @Test func twoThousandEntriesLoadAndSearchQuickly() async throws {
        let project = try BibliographyProject([
            "main.typ": "#bibliography(\"big.bib\")\n",
            "big.bib": Self.generatedBibliography(count: 2000),
        ])
        let clock = ContinuousClock()
        // The engine call alone (read, parse, JSON across the C ABI, decode),
        // then the search table on its own.
        let fresh = try await project.renderer()
        var contents = BibliographyContents.empty
        let engine = await clock.measure {
            contents = await fresh.bibliography(["big.bib"])
        }
        let table = clock.measure {
            BibliographyIndex().update(contents)
        }

        let renderer = try await project.renderer()
        let index = BibliographyIndex()
        let load = await clock.measure {
            await index.reload(using: renderer, root: project.root)
        }
        #expect(index.entries.count == 2000)
        #expect(index.contents.errors.isEmpty)
        let cached = await clock.measure {
            await index.reload(using: renderer, root: project.root)
        }

        let queries = ["smi", "müller 1985", "coordination", "ecolog", "garcia", "2001", "handbook", "xyz", "o'brien"]
        // Each search's own work is the main thread's CPU time: the suite runs
        // in parallel, so wall-clock time also counts time other tests hold
        // the CPU.
        var slowest = Duration.zero
        var slowestWall = Duration.zero
        var total = Duration.zero
        for run in 0 ..< 100 {
            let query = queries[run % queries.count]
            let cpuStart = Self.threadCPUTime()
            let elapsed = clock.measure {
                _ = index.search(query)
            }
            slowest = max(slowest, Self.threadCPUTime() - cpuStart)
            slowestWall = max(slowestWall, elapsed)
            total += elapsed
        }
        for query in queries {
            var found = 0
            let elapsed = clock.measure {
                found = index.search(query).count
            }
            print("bibliography search \(query): \(found) results, \(elapsed)")
        }
        print(
            "bibliography index: 2000 entries, engine call \(engine), search table \(table), load \(load), cached reload \(cached), search mean \(total / 100), slowest CPU \(slowest), slowest wall \(slowestWall)",
        )
        #expect(!index.search("smi").isEmpty)
        #expect(slowest < .milliseconds(5), "slowest search took \(slowest) of CPU time")
        #expect(total / 100 < .milliseconds(5), "searches took \(total / 100) on average")
    }

    /// The calling thread's CPU time.
    private static func threadCPUTime() -> Duration {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return .seconds(time.tv_sec) + .nanoseconds(time.tv_nsec)
    }

    /// A BibLaTeX file of realistic entries, built here (no network).
    static func generatedBibliography(count: Int) -> String {
        let families = ["Smith", "Müller", "García", "Nguyen", "O'Brien", "van der Berg", "Kowalski", "Dubois",
                        "Johansson", "Tanaka", "Rossi", "Ivanova", "Okafor", "Fernández", "Lindqvist", "Chen"]
        let given = ["Anna", "Björn", "Carlos", "Dana", "Émile", "Fatima", "Gustav", "Hiro"]
        let words = ["dynamics", "perception", "coordination", "action", "ecological", "affordances", "recurrence",
                     "fractal", "variability", "movement", "synergy", "attention", "learning", "interpersonal",
                     "posture", "rhythm"]
        let journals = ["Ecological Psychology", "Cognitive Science", "Human Movement Science"]
        var out = ""
        for item in 0 ..< count {
            let family = families[item % families.count]
            let coauthor = families[(item * 7 + 3) % families.count]
            let title = (0 ..< 6).map { words[(item * 3 + $0 * 5) % words.count] }
            let year = 1970 + item % 55
            let key = family.lowercased().filter(\.isLetter) + "\(year)\(item)"
            if item.isMultiple(of: 3) {
                out += """
                @book{\(key),
                  author = {\(family), \(given[item % given.count])},
                  title = {\(title.joined(separator: " "))},
                  publisher = {Academic Press},
                  year = {\(year)},
                }


                """
            } else {
                out += """
                @article{\(key),
                  author = {\(family), \(given[item % given.count]) and \(coauthor), \(given[(item + 3) % given.count])},
                  title = {{The} \(title[..<3].joined(separator: " ")) of \(title[3...].joined(separator: " "))},
                  journal = {\(journals[item % journals.count])},
                  volume = {\(item % 40 + 1)},
                  pages = {\(item % 300 + 1)--\(item % 300 + 20)},
                  year = {\(year)},
                  doi = {10.1000/\(key)},
                  abstract = {An abstract about \(title[0]) and \(title[1]) that runs for a while, as abstracts do.},
                }


                """
            }
        }
        return out
    }
}
