import Foundation
import OopsCore

/// A draft Hello corrects. Every `after` is what the real pipeline returned for its `before` (Claude
/// Haiku, low effort, through `oops-eval run` with the shipping prompt), never an answer written by
/// hand: rerun design/onboarding/hello-drafts.jsonl after a prompt change and paste the outputs back.
struct HelloDraft: Identifiable {
    enum App: CaseIterable { case chat, mail, doc, page, team, note, messenger }
    let app: App
    let before: String
    let after: String
    /// Its window on Hello's 1200 × 750 desktop.
    let frame: CGRect
    var rightToLeft = false
    var language = "en"
    var id: App { app }

    /// The same diff, count and highlights as a real correction.
    var diff: WordDiff { WordDiff(before: before, after: after) }
    @MainActor var label: String { TestEditorModel.fixesLabel(diff.changes) }
}

extension HelloDraft {
    static let canvas = CGSize(width: 1200, height: 750)

    /// Typed live, close up, before the camera pulls back.
    static let typed = HelloDraft(app: .chat, before: "on my way, runing 5 min late sory, save me a seet",
                                  after: "on my way, running 5 min late sorry, save me a seat",
                                  frame: CGRect(x: 380, y: 240, width: 440, height: 270))

    /// Unsent drafts waiting in other apps, clockwise from the top left: the wave and its rising notes
    /// travel round the screen.
    static let waiting: [HelloDraft] = [
        HelloDraft(app: .mail, before: "Bonjour Camille, je vous envoi le devis demain matin, désolé pour le retart. Bonne journé",
                   after: "Bonjour Camille, je vous envoie le devis demain matin, désolé pour le retard. Bonne journée",
                   frame: CGRect(x: 28, y: 44, width: 336, height: 296), language: "fr"),
        HelloDraft(app: .doc, before: "El informe trimestral esta casi listo, solo falta revisar las sifras de ventas y añadir las conclusiones.",
                   after: "El informe trimestral está casi listo, solo falta revisar las cifras de ventas y añadir las conclusiones.",
                   frame: CGRect(x: 384, y: 32, width: 432, height: 194), language: "es"),
        HelloDraft(app: .page, before: "我现在再开会，等一下在给你打电话", after: "我现在在开会，等一下再给你打电话",
                   frame: CGRect(x: 836, y: 44, width: 336, height: 236), language: "zh-Hans"),
        HelloDraft(app: .team, before: "@Sami can you take a look at teh PR before tonite? the fix is in `RetryPolicy.swift`",
                   after: "@Sami can you take a look at the PR before tonight? the fix is in `RetryPolicy.swift`",
                   frame: CGRect(x: 836, y: 300, width: 336, height: 318)),
        HelloDraft(app: .note, before: "ricordarsi di chiamare il dentista, e comprare il regallo per Giulia prima di venerdi",
                   after: "ricordarsi di chiamare il dentista e comprare il regalo per Giulia prima di venerdì",
                   frame: CGRect(x: 384, y: 528, width: 432, height: 198), language: "it"),
        HelloDraft(app: .messenger, before: "الاجتماغ غدا الساعه العاشرة، لا تتاخر من فضلك", after: "الاجتماع غدا الساعة العاشرة، لا تتأخر من فضلك",
                   frame: CGRect(x: 28, y: 362, width: 336, height: 346), rightToLeft: true, language: "ar")
    ]
}
