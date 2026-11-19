public extension SpeechLanguage {
    /// First run's guess at the language someone dictates in, which the speech model it downloads follows: the
    /// system's first language, or Auto when the enabled keyboards type more than one. `keyboards` holds each
    /// enabled keyboard's languages, its own first.
    static func firstRun(preferred: [String], keyboards: [[String]]) -> String {
        func base(_ code: String) -> String {
            code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? code
        }
        if Set(keyboards.compactMap { $0.first.map(base) }).count > 1 { return auto }
        let first = preferred.first.map(base) ?? "en"
        return isListed(first) ? first : "en"
    }
}
