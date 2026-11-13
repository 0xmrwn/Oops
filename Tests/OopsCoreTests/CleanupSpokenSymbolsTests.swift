import XCTest
@testable import OopsCore

/// Hex's spoken symbols tests (`src/dictation/spoken_symbols.rs` at v3.4.0), each under its upstream name in the
/// Swift style, and French cases in the same style.
final class CleanupSpokenSymbolsTests: XCTestCase {
    func testSymbolsJoinTheirNeighbours() {
        XCTAssertEqual(SpokenSymbols.apply("hashtag release"), "#release")
        XCTAssertEqual(SpokenSymbols.apply("my underscore variable"), "my_variable")
        XCTAssertEqual(SpokenSymbols.apply("done comma thanks"), "done, thanks")
        XCTAssertEqual(SpokenSymbols.apply("tag it hash sign release"), "tag it #release")
        XCTAssertEqual(SpokenSymbols.apply("mail me at sign home"), "mail me @home")
        XCTAssertEqual(SpokenSymbols.apply("well hyphen known"), "well-known")
        XCTAssertEqual(SpokenSymbols.apply("and slash or"), "and/or")
        XCTAssertEqual(SpokenSymbols.apply("one semicolon two"), "one; two")
        XCTAssertEqual(SpokenSymbols.apply("the list colon apples"), "the list: apples")
        XCTAssertEqual(SpokenSymbols.apply("Done, Comma, thanks."), "Done, thanks.")
        XCTAssertEqual(SpokenSymbols.apply("the list COLON."), "the list:")
        XCTAssertEqual(SpokenSymbols.apply("a comma comma b"), "a,, b")
    }

    func testSpanishWordsBecomeSymbolsWithOrWithoutAccents() {
        XCTAssertEqual(SpokenSymbols.apply("escríbeme a arroba casa"), "escríbeme a @casa")
        XCTAssertEqual(SpokenSymbols.apply("mi guion bajo variable"), "mi_variable")
        XCTAssertEqual(SpokenSymbols.apply("mi Guión Bajo variable"), "mi_variable")
        XCTAssertEqual(SpokenSymbols.apply("bien guión conocido"), "bien-conocido")
        XCTAssertEqual(SpokenSymbols.apply("uno punto y coma dos"), "uno; dos")
        XCTAssertEqual(SpokenSymbols.apply("hola coma gracias"), "hola, gracias")
        XCTAssertEqual(SpokenSymbols.apply("la lista dos puntos manzanas"), "la lista: manzanas")
        XCTAssertEqual(SpokenSymbols.apply("hola comma gracias"), "hola, gracias")
    }

    func testFrenchWordsBecomeSymbolsWithOrWithoutAccents() {
        XCTAssertEqual(SpokenSymbols.apply("merci virgule à bientôt"), "merci, à bientôt")
        XCTAssertEqual(SpokenSymbols.apply("Merci, Virgule, à bientôt."), "Merci, à bientôt.")
        XCTAssertEqual(SpokenSymbols.apply("tu viens point d'interrogation"), "tu viens?")
        XCTAssertEqual(SpokenSymbols.apply("tu viens point d\u{2019}interrogation oui"), "tu viens? oui")
        XCTAssertEqual(SpokenSymbols.apply("super point d'exclamation"), "super!")
        XCTAssertEqual(SpokenSymbols.apply("la liste deux-points pommes"), "la liste: pommes")
        XCTAssertEqual(SpokenSymbols.apply("la liste deux points pommes"), "la liste: pommes")
        XCTAssertEqual(SpokenSymbols.apply("un point virgule deux"), "un; deux")
        XCTAssertEqual(SpokenSymbols.apply("écris-moi arobase maison"), "écris-moi @maison")
        XCTAssertEqual(SpokenSymbols.apply("mon tiret bas variable"), "mon_variable")
        XCTAssertEqual(SpokenSymbols.apply("bien tiret connu"), "bien-connu")
        XCTAssertEqual(SpokenSymbols.apply("et barre oblique ou"), "et/ou")
        XCTAssertEqual(SpokenSymbols.apply("dièse version"), "#version")
        XCTAssertEqual(SpokenSymbols.apply("hola virgule gracias"), "hola, gracias")
    }

    func testFrenchDeuxPointsCountingPointsStaysProse() {
        for text in [
            "deux points de vue", "Il y a deux points d'écart.", "deux points d\u{2019}accord", "deux points du programme",
            "les deux points", "à deux points près", "il a deux points", "gagné par deux points", "sur deux points importants"
        ] {
            XCTAssertEqual(SpokenSymbols.apply(text), text)
        }
        XCTAssertEqual(SpokenSymbols.apply("la liste deux points pommes"), "la liste: pommes")
        XCTAssertEqual(SpokenSymbols.apply("deux points de vue deux-points le mien"), "deux points de vue: le mien")
        XCTAssertEqual(SpokenSymbols.apply("les deux-points pommes"), "les: pommes")
        XCTAssertEqual(SpokenSymbols.apply("la lista dos puntos de manzanas"), "la lista: de manzanas")
    }

    func testOtherWordsAreLeftAlone() {
        for text in [
            "comas", "guiones largos", "un punto y aparte", "commas", "slashed prices", "hashtags everywhere",
            "a hash browns sign", "the colonel", "Plain text, nothing to do.", "",
            "des virgules", "un point de vue", "arobases", "tirets"
        ] {
            XCTAssertEqual(SpokenSymbols.apply(text), text)
        }
    }
}
