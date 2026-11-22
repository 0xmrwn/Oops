import AppKit
import ApplicationServices
import OopsCore

/// What the Actions wheel reads of the focused field as it opens: where the field is, and the colour of its text,
/// which says whether the page behind it is light or dark.
extension EditorAccess {
    /// The colour is read where the person is: the start of the selection, or the character the caret continues.
    /// Unlike `caretStyle`, a selection still tells it. The style holds only the colour; nil when the field doesn't
    /// tell it.
    func focusedTone() throws -> (geometry: CapsulePlacement.Geometry, style: CaretStyle?) {
        guard AXIsProcessTrusted() else { throw CorrectionError.message("Allow Oops in \(AccessibilityPermission.paneName) first.") }
        let element = try focusedWaking()
        let geometry = geometry(element)
        guard let selection = range(element) else { return (geometry, nil) }
        let at = selection.length > 0 || selection.location == 0 ? selection.location : selection.location - 1
        guard let read = attributedString(element, NSRange(location: at, length: 1)), read.length > 0,
              let value = read.attributes(at: 0, effectiveRange: nil)[NSAttributedString.Key("AXForegroundColor")],
              CFGetTypeID(value as CFTypeRef) == CGColor.typeID, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let rgb = (value as! CGColor).converted(to: space, intent: .defaultIntent, options: nil)?.components, rgb.count >= 3
        else { return (geometry, nil) }
        return (geometry, CaretStyle(color: SIMD3(Double(rgb[0]), Double(rgb[1]), Double(rgb[2]))))
    }
}
