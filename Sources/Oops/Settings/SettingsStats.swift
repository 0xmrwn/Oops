import Charts
import SwiftUI

/// The stats totals, on General. The whole card opens the charts.
struct StatsCard: View {
    let stats: Stats
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 0) {
                tile(stats.corrections, "Corrections", ShortcutSettings.Action.correct.symbol)
                Divider().frame(height: 44)
                tile(stats.mistakesFixed, "Mistakes fixed", "checkmark.seal")
                Divider().frame(height: 44)
                tile(stats.wordsChecked, "Words checked", "text.magnifyingglass")
            }
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).secondaryText()
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .settingsSurface()
        .accessibilityHint("Shows charts")
    }

    private func tile(_ value: Int, _ title: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Text(value.formatted()).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
            Label(title, systemImage: symbol).font(.callout).secondaryText()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The charts behind the totals: activity by day, what a correction usually changes, how long
/// drafts are, how fast each model answers and where Oops is used.
struct StatsPage: View {
    let stats: Stats
    @State private var selectedDay: Date?
    @State private var confirmingReset = false
    @State private var resetError: String?

    var body: some View {
        let events = stats.events
        let counted = events.filter { $0.outcome == .fixed || $0.outcome == .clear }
        if counted.isEmpty {
            Text("No corrections yet").secondaryText().frame(maxWidth: .infinity).settingsSurface()
        } else {
            let fixed = counted.filter { $0.outcome == .fixed }
            VStack(alignment: .leading, spacing: 20) {
                ActivityChart(days: days(counted), reverted: stats.reverted, selectedDay: $selectedDay)
                HStack(alignment: .top, spacing: 20) {
                    histogram("Mistakes per correction", average: average(fixed, by: \.fixes),
                              unit: "", buckets: mistakeBuckets(fixed))
                    histogram("Draft length", average: average(counted, by: \.words), unit: " words", buckets: lengthBuckets(counted))
                }
                ranking("Response time", rows: speeds(events), format: { $0.formatted(.number.precision(.fractionLength(1))) + " s" })
                ranking("Apps", rows: apps(counted), format: { Int($0).formatted() })
                HStack {
                    if let resetError {
                        Label(resetError, systemImage: "exclamationmark.triangle").font(.callout).secondaryText()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button { confirmingReset = true } label: { Label("Reset Stats", systemImage: "trash") }
                        .buttonStyle(.settingsGlass)
                }
            }
            .confirmationDialog("Reset all stats?", isPresented: $confirmingReset) {
                Button("Reset Stats", role: .destructive) {
                    do { try stats.reset(); resetError = nil } catch { resetError = "Couldn’t delete the stats file. \(error.localizedDescription)" }
                }
            } message: {
                Text("Every count and chart starts again from zero. This can’t be undone.")
            }
        }
    }

    // MARK: Activity

    private struct Day: Identifiable { let date: Date; let outcome: String; let count: Int; var id: String { "\(date)\(outcome)" } }

    private func days(_ counted: [Stats.Event]) -> [Day] {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: .now))!
        let recent = counted.filter { $0.date >= start }
        let grouped = Dictionary(grouping: recent) { calendar.startOfDay(for: $0.date) }
        return grouped.flatMap { date, events in
            [Day(date: date, outcome: "Fixed", count: events.count { $0.outcome == .fixed }),
             Day(date: date, outcome: "Already clear", count: events.count { $0.outcome == .clear })]
        }
    }

    private struct ActivityChart: View {
        let days: [Day]
        let reverted: Int
        @Binding var selectedDay: Date?

        var body: some View {
            let selected = selectedDay.map { Calendar.current.startOfDay(for: $0) }
            let selectedTotal = days.filter { $0.date == selected }.reduce(0) { $0 + $1.count }
            return VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Last 30 days").font(.headline)
                    Spacer()
                    Group {
                        if let selected, selectedTotal > 0 {
                            Text("\(selected.formatted(.dateTime.day().month())) · \(selectedTotal) corrections")
                        } else {
                            Text("\(days.reduce(0) { $0 + $1.count }) corrections · \(reverted) reverted")
                        }
                    }
                    .font(.callout).secondaryText().monospacedDigit()
                }
                Chart(days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Corrections", day.count))
                        .foregroundStyle(by: .value("Outcome", day.outcome))
                        .cornerRadius(3)
                        .opacity(selected == nil || selected == day.date ? 1 : 0.35)
                }
                .chartForegroundStyleScale(["Fixed": Color.primary.opacity(0.85), "Already clear": Color.primary.opacity(0.28)])
                .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
                .chartXSelection(value: $selectedDay)
                // Room for the last date's label, which is wider than its bar.
                .chartXScale(range: .plotDimension(startPadding: 2, endPadding: 22))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(), centered: false)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(.primary.opacity(0.2))
                        AxisValueLabel()
                    }
                }
                .frame(height: 170)
                .animation(.easeOut(duration: 0.15), value: selectedDay)
            }
            .settingsSurface()
        }
    }

    // MARK: Distributions

    private struct Bucket: Identifiable { let label: String; let count: Int; var id: String { label } }

    private func mistakeBuckets(_ fixed: [Stats.Event]) -> [Bucket] {
        (1...5).map { n in
            Bucket(label: n == 5 ? "5+" : "\(n)", count: fixed.count { n == 5 ? $0.fixes >= 5 : $0.fixes == n })
        }
    }

    private func lengthBuckets(_ counted: [Stats.Event]) -> [Bucket] {
        let edges = [(1, 10, "≤10"), (11, 25, "25"), (26, 50, "50"), (51, 100, "100"), (101, .max, "100+")]
        return edges.map { low, high, label in Bucket(label: label, count: counted.count { $0.words >= low && $0.words <= high }) }
    }

    private func histogram(_ title: String, average: Double, unit: String, buckets: [Bucket]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(average.formatted(.number.precision(.fractionLength(1))) + unit)
                .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
            Chart(buckets) { bucket in
                BarMark(x: .value("Range", bucket.label), y: .value("Count", bucket.count))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .cornerRadius(3)
            }
            .chartYAxis(.hidden)
            .chartXAxis { AxisMarks { _ in AxisValueLabel() } }
            .frame(height: 80)
        }
        .settingsSurface()
    }

    // MARK: Rankings

    private struct Row: Identifiable { let name: String; let value: Double; var id: String { name } }

    private func speeds(_ events: [Stats.Event]) -> [Row] {
        let timed = events.filter { $0.seconds != nil && $0.model != nil }
        return Dictionary(grouping: timed, by: { $0.model! })
            .map { Row(name: $0.key, value: $0.value.compactMap(\.seconds).reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.value < $1.value }.prefix(5).map(\.self)
    }

    private func apps(_ counted: [Stats.Event]) -> [Row] {
        Dictionary(grouping: counted.filter { $0.app != nil }, by: { $0.app! })
            .map { Row(name: $0.key, value: Double($0.value.count)) }
            .sorted { $0.value > $1.value }.prefix(5).map(\.self)
    }

    /// Name, a bar scaled to the largest value, then the value: plain rows read better than a
    /// chart axis for five names.
    private func ranking(_ title: String, rows: [Row], format: @escaping (Double) -> String) -> some View {
        let top = rows.map(\.value).max() ?? 1
        return VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    Text(row.name).lineLimit(1).truncationMode(.middle).frame(width: 130, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule().fill(Color.primary.opacity(0.7))
                            .frame(width: max(6, proxy.size.width * row.value / top), height: 8)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 16)
                    Text(format(row.value)).font(.callout).secondaryText().monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .settingsSurface()
    }

    private func average(_ events: [Stats.Event], by value: KeyPath<Stats.Event, Int>) -> Double {
        events.isEmpty ? 0 : Double(events.reduce(0) { $0 + $1[keyPath: value] }) / Double(events.count)
    }
}
