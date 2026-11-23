import AppKit
import SwiftUI

/// The time a narrating drop's work has taken, as `m:ss` in tabular digits so a tick never shifts the drop, and
/// quieter than the label beside it.
struct DropClock: View {
    let startedAt: Date, scale: CGFloat, ink: Color, halo: Color
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)

    static func font(_ scale: CGFloat) -> NSFont { scale == 1 ? font : .monospacedDigitSystemFont(ofSize: 13 * scale, weight: .regular) }
    static func text(since startedAt: Date, at date: Date) -> String {
        Duration.seconds(Int(max(0, date.timeIntervalSince(startedAt)))).formatted(.time(pattern: .minuteSecond))
    }
    /// The clock's width now: it changes only as the clock gains a digit.
    static func width(since startedAt: Date, scale: CGFloat) -> CGFloat {
        (text(since: startedAt, at: Date()) as NSString).size(withAttributes: [.font: font(scale)]).width.rounded(.up)
    }

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Text(Self.text(since: startedAt, at: context.date)).font(Font(Self.font(scale))).fixedSize().contentTransition(.identity)
        }
        .foregroundStyle(ink.opacity(0.6))
        .modifier(Halo(color: halo))
    }
}
