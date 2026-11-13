import Foundation

// The language tables of Hex at v3.4.0 (MIT, github.com/anomalyco/hex): `src/transcription/languages.rs` and
// `WHISPER_LANGUAGES` of `src/transcription/models.rs`. See THIRD_PARTY_NOTICES.md.

public enum SpeechLanguage {
    public static let auto = "auto"

    /// The languages Hex names, in the order its Settings offers them (Auto first).
    public static let listed: [(code: String, name: String)] = [
        ("auto", "Auto"), ("en", "English"), ("zh", "Mandarin Chinese"), ("yue", "Cantonese"), ("ja", "Japanese"),
        ("ko", "Korean"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("pt", "Portuguese"),
        ("it", "Italian"), ("ar", "Arabic"), ("hi", "Hindi"), ("bn", "Bangla"), ("vi", "Vietnamese"),
        ("ru", "Russian"), ("uk", "Ukrainian"), ("nl", "Dutch"), ("pl", "Polish"), ("tr", "Turkish"),
        ("sv", "Swedish"), ("da", "Danish"), ("no", "Norwegian"), ("fi", "Finnish"), ("cs", "Czech"),
        ("el", "Greek"), ("ro", "Romanian"), ("hu", "Hungarian"), ("id", "Indonesian"), ("ms", "Malay"),
        ("th", "Thai"), ("fa", "Persian"), ("he", "Hebrew"), ("bg", "Bulgarian"), ("hr", "Croatian"),
        ("et", "Estonian"), ("lv", "Latvian"), ("lt", "Lithuanian"), ("mt", "Maltese"), ("sk", "Slovak"),
        ("sl", "Slovenian"), ("mk", "Macedonian"), ("fil", "Filipino")
    ]

    /// Names for the other languages Whisper knows, which only a model that declares them offers.
    private static let others: [(code: String, name: String)] = [
        ("nn", "Norwegian Nynorsk"), ("ca", "Catalan"), ("ta", "Tamil"), ("ur", "Urdu"), ("la", "Latin"),
        ("mi", "Maori"), ("ml", "Malayalam"), ("cy", "Welsh"), ("te", "Telugu"), ("sr", "Serbian"),
        ("az", "Azerbaijani"), ("kn", "Kannada"), ("br", "Breton"), ("eu", "Basque"), ("is", "Icelandic"),
        ("hy", "Armenian"), ("ne", "Nepali"), ("mn", "Mongolian"), ("bs", "Bosnian"), ("kk", "Kazakh"),
        ("sq", "Albanian"), ("sw", "Swahili"), ("gl", "Galician"), ("mr", "Marathi"), ("pa", "Punjabi"),
        ("si", "Sinhala"), ("km", "Khmer"), ("sn", "Shona"), ("yo", "Yoruba"), ("so", "Somali"),
        ("af", "Afrikaans"), ("oc", "Occitan"), ("ka", "Georgian"), ("be", "Belarusian"), ("tg", "Tajik"),
        ("sd", "Sindhi"), ("gu", "Gujarati"), ("am", "Amharic"), ("yi", "Yiddish"), ("lo", "Lao"),
        ("uz", "Uzbek"), ("fo", "Faroese"), ("ht", "Haitian Creole"), ("ps", "Pashto"), ("tk", "Turkmen"),
        ("sa", "Sanskrit"), ("lb", "Luxembourgish"), ("my", "Burmese"), ("bo", "Tibetan"), ("tl", "Tagalog"),
        ("mg", "Malagasy"), ("as", "Assamese"), ("tt", "Tatar"), ("haw", "Hawaiian"), ("ln", "Lingala"),
        ("ha", "Hausa"), ("ba", "Bashkir"), ("jw", "Javanese"), ("su", "Sundanese")
    ]

    /// Whisper large-v3's language codes: the engine accepts these beyond the languages Settings lists.
    private static let whisper: [String] = [
        "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar", "sv", "it",
        "id", "hi", "fi", "vi", "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no", "th", "ur",
        "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk", "te", "fa", "lv", "bn", "sr", "az", "sl", "kn",
        "et", "mk", "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw", "gl", "mr", "pa", "si",
        "km", "sn", "yo", "so", "af", "oc", "ka", "be", "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo",
        "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl", "mg", "as", "tt", "haw", "ln",
        "ha", "ba", "jw", "su", "yue"
    ]

    /// Every code Hex knows besides Auto: the listed ones and Whisper's. A model Hex marks `"*"` accepts all of them.
    public static let known: [String] = {
        var codes = listed.map(\.code).filter { $0 != auto }
        for code in whisper where !codes.contains(code) { codes.append(code) }
        return codes
    }()

    public static func isKnown(_ code: String) -> Bool {
        code == auto || known.contains(code)
    }

    public static func isListed(_ code: String) -> Bool {
        listed.contains { $0.code == code }
    }

    /// The language's English name, or its code when Hex has none.
    public static func name(of code: String) -> String {
        (listed + others).first { $0.code == code }?.name ?? code
    }
}
