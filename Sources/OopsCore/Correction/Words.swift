/// Word counting shared by Stats and dictation history, so their numbers agree.
public enum Words {
    /// Runs of characters between whitespace or line breaks.
    public static func count(in text: String) -> Int {
        var count = 0, previousWasSeparator = true
        for character in text {
            let isSeparator = character.isWhitespace || character.isNewline
            if previousWasSeparator, !isSeparator { count += 1 }
            previousWasSeparator = isSeparator
        }
        return count
    }
}
