import Foundation
@testable import ProseCore
import Testing

/// The citation picker's text rules (citations note, decision 4).
@Test func citationTextSpacesAfterWordsAndCitationsAndKeepsSupplementsAsTyped() {
    func insert(_ source: String, at marker: String = "|", _ key: String = "smith2019", supplement: String? = nil)
        -> String
    {
        let location = (source as NSString).range(of: marker).location
        let text = (source as NSString).replacingCharacters(in: NSRange(location: location, length: 1), with: "")
        let inserted = CitationInsertion.text(citing: key, in: text as NSString, at: location, supplement: supplement)
        return (text as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: inserted)
    }
    #expect(insert("A claim|.") == "A claim @smith2019.")
    #expect(insert("A claim |.") == "A claim @smith2019.")
    #expect(insert("|") == "@smith2019")
    #expect(insert("Done.\n\n|Next") == "Done.\n\n@smith2019 Next")
    #expect(insert("(|)") == "(@smith2019)")
    // After a citation, with or without a space.
    #expect(insert("See @a| for it.") == "See @a @smith2019 for it.")
    #expect(insert("See @a |for it.") == "See @a @smith2019 for it.")
    #expect(insert("See @key-x_| here") == "See @key-x_ @smith2019 here")
    #expect(insert("See @a[p. 4]| here") == "See @a[p. 4] @smith2019 here")
    // Brackets that are not a supplement, and an address.
    #expect(insert("A list [x]|.") == "A list [x]@smith2019.")
    #expect(insert("mail me@x.org|") == "mail me@x.org @smith2019")
    // A following bracket would read as a supplement.
    #expect(insert("Claim|[note]") == "Claim @smith2019 [note]")
    // Supplements are inserted exactly as typed.
    #expect(insert("A claim|.", supplement: "p. 4") == "A claim @smith2019[p. 4].")
    #expect(insert("A claim|.", supplement: "") == "A claim @smith2019.")
    #expect(insert("Über|", "müller") == "Über @müller")
}

@Test func citationKeysTypstCannotReadAfterAtUseCite() {
    #expect(CitationInsertion.citation("doe:2020.a") == "@doe:2020.a")
    #expect(CitationInsertion.isReferenceKey("2020smith"))
    #expect(!CitationInsertion.isReferenceKey("smith."))
    #expect(!CitationInsertion.isReferenceKey(""))
    #expect(CitationInsertion.citation("a b") == "#cite(label(\"a b\"))")
    #expect(CitationInsertion.citation("x/\"y\\", supplement: "ch. 2") ==
        "#cite(label(\"x/\\\"y\\\\\"), supplement: [ch. 2])")
    #expect(CitationInsertion.citation("end:", supplement: "p. 1") == "#cite(label(\"end:\"), supplement: [p. 1])")
}

@Test func onlyEditsNearABibliographyCallReloadTheIndex() {
    let source = "= Paper\n\nSome text here.\n\n#bibliography(\"refs.bib\")\n" as NSString
    let text = source.range(of: "text").location
    #expect(!CitationInsertion.mayChangeBibliography(
        source,
        TextReplacement(range: NSRange(location: text, length: 0), text: "x"),
    ))
    let path = source.range(of: "refs").location
    #expect(CitationInsertion.mayChangeBibliography(
        source,
        TextReplacement(range: NSRange(location: path, length: 4), text: "other"),
    ))
    // Typing the last letter of the call's name.
    let typed = "Text #bibliograph" as NSString
    #expect(CitationInsertion.mayChangeBibliography(
        typed,
        TextReplacement(range: NSRange(location: typed.length, length: 0), text: "y"),
    ))
    // Deleting a whole call.
    let call = source.range(of: "#bibliography(\"refs.bib\")")
    #expect(CitationInsertion.mayChangeBibliography(source, TextReplacement(range: call, text: "")))
    #expect(CitationInsertion.mayChangeBibliography(
        source,
        TextReplacement(range: NSRange(location: source.length + 4, length: 0), text: ""),
    ))
}

@Test func pickerRowsAndProblemLines() throws {
    let one = BibliographyEntry(key: "a", authors: [.init(family: "Smith", given: "Jane")])
    let two = BibliographyEntry(key: "b", authors: [.init(family: "Smith"), .init(family: "Jones")])
    #expect(one.leadAuthor == "Smith")
    #expect(two.leadAuthor == "Smith et al.")
    #expect(BibliographyEntry(key: "c").leadAuthor.isEmpty)

    let json = """
    {"entries": [],
     "errors": [
       {"file": "refs.bib", "line": 42, "message": "bad year"},
       {"file": "more.bib", "line": 3, "message": "bad year"},
       {"file": "more.bib", "line": 9, "message": "bad year"},
       {"file": "more.bib", "line": 12, "message": "bad year"},
       {"file": "more.bib", "line": 20, "message": "bad year"},
       {"file": "gone.bib", "line": 0, "message": "file not found"},
       {"file": "notes.yml", "line": 1, "message": "not a bibliography"}
     ],
     "files": [
       {"path": "refs.bib", "entries": 3, "accepted": false},
       {"path": "more.bib", "entries": 1, "accepted": false},
       {"path": "gone.bib", "entries": 0, "accepted": false},
       {"path": "notes.yml", "entries": 0, "accepted": false}
     ]}
    """
    var contents = try JSONDecoder().decode(BibliographyContents.self, from: Data(json.utf8))
    #expect(contents.problemSummaries == [
        "refs.bib: 1 entry could not be read, line 42",
        "more.bib: 4 entries could not be read, lines 3, 9, 12…",
        "gone.bib: file not found",
        "notes.yml: 1 entry could not be read, line 1",
    ])
    // Not linked: a YAML file with no entry is most likely not a bibliography.
    for index in contents.files.indices {
        contents.files[index].linked = false
    }
    #expect(contents.problemSummaries.count == 3)
    #expect(!contents.problemSummaries.contains { $0.hasPrefix("notes.yml") })
}
