import XCTest
@testable import S5Core

final class ExcludeTests: XCTestCase {
    private func excluded(_ path: String, _ patterns: [String] = [], directory: Bool = false) -> Bool {
        ExcludeRules(patterns).isExcluded(path, isDirectory: directory)
    }

    func testDefaultExcludes() {
        XCTAssertTrue(excluded(".DS_Store"))
        XCTAssertTrue(excluded("a/b/.DS_Store"))
        XCTAssertTrue(excluded("a/._photo.jpg"))
        XCTAssertTrue(excluded("Icon\r"))
        XCTAssertTrue(excluded(".Trashes/501/x", directory: false))
        XCTAssertFalse(excluded("notes.txt"))
        XCTAssertFalse(excluded("a/.gitignore"))
    }

    func testPatternWithoutSlashMatchesNameAtAnyDepth() {
        XCTAssertTrue(excluded("a.tmp", ["*.tmp"]))
        XCTAssertTrue(excluded("a/b/c.tmp", ["*.tmp"]))
        XCTAssertTrue(excluded("proj/node_modules", ["node_modules"], directory: true))
        XCTAssertTrue(excluded("proj/node_modules/lib/index.js", ["node_modules"]))
        XCTAssertFalse(excluded("proj/node_modules_old", ["node_modules"]))
        XCTAssertFalse(excluded("a.tmp.txt", ["*.tmp"]))
        XCTAssertTrue(excluded(".env", ["*"]))
    }

    func testPatternWithSlashIsAnchoredAndStarStopsAtSlash() {
        XCTAssertTrue(excluded("docs/x.pdf", ["docs/*.pdf"]))
        XCTAssertFalse(excluded("other/x.pdf", ["docs/*.pdf"]))
        XCTAssertFalse(excluded("docs/sub/x.pdf", ["docs/*.pdf"]))
        XCTAssertFalse(excluded("a/docs/x.pdf", ["docs/*.pdf"]))
        XCTAssertTrue(excluded("build", ["/build"], directory: true))
        XCTAssertTrue(excluded("build/out.o", ["/build"]))
        XCTAssertFalse(excluded("src/build", ["/build"], directory: true))
        XCTAssertTrue(excluded("a/b/c", ["a/?/c"]))
        XCTAssertFalse(excluded("ab/c", ["a?c"]))
    }

    func testDoubleStar() {
        // « **/x » : n'importe quelle profondeur, y compris la racine.
        XCTAssertTrue(excluded("logs", ["**/logs"], directory: true))
        XCTAssertTrue(excluded("a/b/logs/today.log", ["**/logs"]))
        XCTAssertTrue(excluded("a/b/x.pdf", ["**/*.pdf"]))
        // « x/** » : tout le contenu, pas x lui-même.
        XCTAssertTrue(excluded("cache/a", ["cache/**"]))
        XCTAssertTrue(excluded("cache/a/b/c", ["cache/**"]))
        XCTAssertFalse(excluded("cache", ["cache/**"], directory: true))
        XCTAssertFalse(excluded("sub/cache/a", ["cache/**"]))
        // « a/**/b » : zéro ou plusieurs dossiers.
        XCTAssertTrue(excluded("a/b", ["a/**/b"]))
        XCTAssertTrue(excluded("a/x/b", ["a/**/b"]))
        XCTAssertTrue(excluded("a/x/y/b", ["a/**/b"]))
        XCTAssertFalse(excluded("a/x/bb", ["a/**/b"]))
        XCTAssertTrue(excluded("docs/sub/x.pdf", ["docs/**/*.pdf"]))
    }

    func testTrailingSlashMatchesDirectoriesOnly() {
        XCTAssertTrue(excluded("a/tmp", ["tmp/"], directory: true))
        XCTAssertTrue(excluded("a/tmp/file.txt", ["tmp/"]))
        XCTAssertFalse(excluded("a/tmp", ["tmp/"], directory: false))
        XCTAssertTrue(excluded("out/x", ["/out/"]))
        XCTAssertFalse(excluded("src/out/x", ["/out/"]))
    }

    func testNegationLastMatchWins() {
        XCTAssertFalse(excluded("keep.log", ["*.log", "!keep.log"]))
        XCTAssertTrue(excluded("other.log", ["*.log", "!keep.log"]))
        XCTAssertTrue(excluded("keep.log", ["!keep.log", "*.log"]))
        XCTAssertFalse(excluded(".DS_Store", ["!.DS_Store"]))
        // « x/** » n'exclut pas x : son contenu peut être ré-inclus.
        XCTAssertFalse(excluded("cache/keep", ["cache/**", "!cache/keep"]))
        XCTAssertTrue(excluded("cache/other", ["cache/**", "!cache/keep"]))
    }

    func testCannotReincludeUnderExcludedDirectory() {
        XCTAssertTrue(excluded("build/keep.txt", ["build/", "!build/keep.txt"]))
        XCTAssertTrue(excluded("build/keep.txt", ["build", "!keep.txt"]))
        // Ré-inclure le dossier lui-même fonctionne.
        XCTAssertFalse(excluded("build/a/keep.txt", ["build/*", "!build/a/"]))
        XCTAssertTrue(excluded("build/b/x.txt", ["build/*", "!build/a/"]))
    }

    func testItemOnlyCheckIgnoresParents() {
        let rules = ExcludeRules(["build/"])
        XCTAssertTrue(rules.excludesItem("build", isDirectory: true))
        XCTAssertFalse(rules.excludesItem("build/x.txt", isDirectory: false))
        XCTAssertTrue(rules.isExcluded("build/x.txt", isDirectory: false))
    }

    func testCommentsBlankLinesAndEscapes() {
        XCTAssertFalse(excluded("#notes", ["#notes"]))
        XCTAssertTrue(excluded("#notes", ["\\#notes"]))
        XCTAssertTrue(excluded("!important", ["\\!important"]))
        XCTAssertFalse(excluded("a", ["", "   ", "# commentaire"]))
        XCTAssertTrue(excluded("a.tmp", ["*.tmp  "]))
        XCTAssertTrue(excluded("a ", ["a\\ "]))
    }

    func testCharacterClassesAndQuestionMark() {
        XCTAssertTrue(excluded("img1.png", ["img?.png"]))
        XCTAssertTrue(excluded("v2.bak", ["v[0-9].bak"]))
        XCTAssertFalse(excluded("vx.bak", ["v[0-9].bak"]))
        XCTAssertTrue(excluded("d/v2.bak", ["d/v[0-9].bak"]))
    }

    func testMatchingIsCaseSensitive() {
        XCTAssertFalse(excluded("a.tmp", ["*.TMP"]))
    }

    func testUnicodeNormalizationIsIgnored() {
        let nfd = "docs/e\u{301}te\u{301}" // « été » décomposé, comme sur le disque
        XCTAssertTrue(excluded(nfd, ["\u{e9}t\u{e9}"]))
        XCTAssertTrue(excluded("\u{e9}t\u{e9}.tmp", ["e\u{301}te\u{301}.*"]))
        XCTAssertTrue(excluded("docs/e\u{301}te\u{301}/x", ["/docs/\u{e9}t\u{e9}/"]))
    }

    func testNoPatterns() {
        XCTAssertFalse(ExcludeRules([], includeDefaults: false).isExcluded("a.tmp", isDirectory: false))
        XCTAssertFalse(ExcludeRules([], includeDefaults: false).isExcluded(".DS_Store", isDirectory: false))
    }
}
