import CoreGraphics
import Foundation

/// What tells someone the wheel's centre takes typing: the words under the drop come by themselves as it opens and go
/// again, and the eyes glance down at them once. Taught until learned: until an instruction has been typed in the
/// wheel, or for its first few opens.
public enum WheelCue {
    /// The opens that show the cue, at most.
    public static let opens = 5

    /// Whether an opening shows the cue, given whether an instruction has ever been typed in the wheel and how many
    /// openings have shown it before.
    public static func shows(typed: Bool, opens shown: Int) -> Bool { !typed && shown < opens }

    /// From the shortcut, in seconds: the words come with the petals, the eyes look down at them and back, the words go.
    static let wordsIn = 0.35, glanceIn = 0.45, glanceOut = 1.07, wordsOut = 1.95
    /// Under Reduce Motion the eyes cross-fade to the glance's still pose and hold it this long.
    static let held = 0.9
    /// Where the eyes look to read the words, and how low their lids come while they do.
    public static let look = CGSize(width: 0.05, height: 0.95), lid = 0.24
}
