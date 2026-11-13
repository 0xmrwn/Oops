import XCTest
@testable import OopsCore

/// Hex's spoken formatting tests (`src/dictation/spoken_formatting.rs` at v3.4.0), each under its upstream name in
/// the Swift style, and French cases in the same style.
final class CleanupSpokenFormattingTests: XCTestCase {
    func testBreaksReplaceTheirPhrasesAndThePunctuationAroundThem() {
        XCTAssertEqual(SpokenFormatting.apply("Hello. New line. Next"), "Hello.\nNext")
        XCTAssertEqual(SpokenFormatting.apply("One. New paragraph. Two."), "One.\n\nTwo.")
        XCTAssertEqual(SpokenFormatting.apply("one, line break, two"), "one\ntwo")
        XCTAssertEqual(SpokenFormatting.apply("a NEW LINE new line b"), "a\n\nb")
    }

    /// A model ends the sentence after the command; the mark stays with the line it ends.
    func testABreakKeepsTheSentenceMarkSpokenAfterIt() {
        XCTAssertEqual(
            SpokenFormatting.apply(
                "Here is the first point, new line. Here is the second point, new paragraph. She said, open quote, ship it today, close quote."
            ),
            "Here is the first point.\nHere is the second point.\n\nShe said, \"ship it today\"."
        )
        XCTAssertEqual(SpokenFormatting.apply("point. New line. Here"), "point.\nHere")
        XCTAssertEqual(SpokenFormatting.apply("point new line here"), "point\nhere")
        XCTAssertEqual(SpokenFormatting.apply("New line. Here"), "\nHere")
        XCTAssertEqual(SpokenFormatting.apply("Here, new line."), "Here.\n")
        XCTAssertEqual(SpokenFormatting.apply("Are you in, new line? Yes"), "Are you in?\nYes")
        XCTAssertEqual(SpokenFormatting.apply("Ship it, new paragraph! Now"), "Ship it!\n\nNow")
        XCTAssertEqual(SpokenFormatting.apply("Ready? New line! Go"), "Ready?\nGo")
        XCTAssertEqual(SpokenFormatting.apply("one, new line, two"), "one\ntwo")
        XCTAssertEqual(SpokenFormatting.apply("Wait, new line… Then"), "Wait…\nThen")
    }

    func testABreakKeepsTheSentenceMarkInEveryLanguage() {
        XCTAssertEqual(SpokenFormatting.apply("Primero, nueva línea. Segundo"), "Primero.\nSegundo")
        XCTAssertEqual(SpokenFormatting.apply("Primero, nuevo párrafo. Segundo"), "Primero.\n\nSegundo")
        XCTAssertEqual(SpokenFormatting.apply("D'abord, à la ligne. Ensuite"), "D'abord.\nEnsuite")
        XCTAssertEqual(SpokenFormatting.apply("D'abord, nouveau paragraphe. Ensuite"), "D'abord.\n\nEnsuite")
    }

    func testQuotesBecomeQuotationMarks() {
        XCTAssertEqual(SpokenFormatting.apply("He said open quote hi close quote."), "He said \"hi\".")
        XCTAssertEqual(
            SpokenFormatting.apply("He said, Open quote, hello, close quote, and left."), "He said, \"hello\", and left."
        )
        XCTAssertEqual(SpokenFormatting.apply("open quote yes close quote then"), "\"yes\" then")
    }

    func testQuoteUnquoteBecomesQuotationMarks() {
        XCTAssertEqual(SpokenFormatting.apply("He said quote hello unquote."), "He said \"hello\".")
        XCTAssertEqual(SpokenFormatting.apply("Quote, something, unquote, and more"), "\"something\", and more")
        XCTAssertEqual(SpokenFormatting.apply("open quote a close quote and quote b unquote"), "\"a\" and \"b\"")
        for text in [
            "Can I get a quote for this", "quote unquote experts", "an unquote alone", "quotes and quoted text unquoted"
        ] {
            XCTAssertEqual(SpokenFormatting.apply(text), text)
        }
    }

    func testSpanishPhrasesWorkWithOrWithoutAccentsAndInAnyCase() {
        XCTAssertEqual(SpokenFormatting.apply("Hola. Nuevo párrafo. Adiós."), "Hola.\n\nAdiós.")
        XCTAssertEqual(SpokenFormatting.apply("Hola. nuevo parrafo. Adiós."), "Hola.\n\nAdiós.")
        XCTAssertEqual(SpokenFormatting.apply("uno, nueva línea, dos"), "uno\ndos")
        XCTAssertEqual(SpokenFormatting.apply("uno NUEVA LINEA dos"), "uno\ndos")
        XCTAssertEqual(SpokenFormatting.apply("uno salto de línea dos"), "uno\ndos")
        XCTAssertEqual(SpokenFormatting.apply("dijo abre comillas hola cierra comillas"), "dijo \"hola\"")
        XCTAssertEqual(
            SpokenFormatting.apply("Dijo Abrir Comillas sí Cerrar Comillas y se fue"), "Dijo \"sí\" y se fue"
        )
        XCTAssertEqual(SpokenFormatting.apply("Hola. New paragraph. Adiós."), "Hola.\n\nAdiós.")
    }

    func testFrenchPhrasesWorkWithOrWithoutAccentsAndInAnyCase() {
        XCTAssertEqual(SpokenFormatting.apply("Bonjour. Nouveau paragraphe. Merci."), "Bonjour.\n\nMerci.")
        XCTAssertEqual(SpokenFormatting.apply("un, à la ligne, deux"), "un\ndeux")
        XCTAssertEqual(SpokenFormatting.apply("un A LA LIGNE deux"), "un\ndeux")
        XCTAssertEqual(SpokenFormatting.apply("un retour à la ligne deux"), "un\ndeux")
        XCTAssertEqual(SpokenFormatting.apply("un saut de ligne deux"), "un\ndeux")
        XCTAssertEqual(SpokenFormatting.apply("un. Nouvelle ligne. deux"), "un.\ndeux")
        XCTAssertEqual(
            SpokenFormatting.apply("Il a dit ouvrez les guillemets salut fermez les guillemets."), "Il a dit \"salut\"."
        )
        XCTAssertEqual(
            SpokenFormatting.apply("Il a dit, Ouvrez les guillemets, bonjour, fermez les guillemets, et il est parti."),
            "Il a dit, \"bonjour\", et il est parti."
        )
        XCTAssertEqual(SpokenFormatting.apply("Hello. Nouveau paragraphe. Merci."), "Hello.\n\nMerci.")
    }

    func testOtherWordsAreLeftAlone() {
        for text in [
            "comillas", "una línea lineal", "dos parrafos nuevos", "nuevo parrafos", "The newline character", "a new liner",
            "renew line items", "line breaker", "open quotes", "Plain text, nothing to do.", "",
            "la ligne droite", "un nouveau paragraphes", "les guillemets français", "à la lignée"
        ] {
            XCTAssertEqual(SpokenFormatting.apply(text), text)
        }
    }
}
