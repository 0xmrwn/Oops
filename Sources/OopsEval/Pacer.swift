import Foundation

/// What a response says about the provider's limits, read from its headers (and, for a 429, its
/// body, which is classified here and never kept).
struct LimitSignal: Sendable {
    /// Wait this long before the next request: `Retry-After`, a spent window's reset, Gemini's `retryDelay`.
    var wait: Double?
    /// A daily (or longer) quota is spent: the rest waits for its reset.
    var daily = false

    /// `x-ratelimit-remaining-*` at zero pauses the provider until the matching `x-ratelimit-reset-*`.
    static func headers(_ headers: [String: String], status: Int) -> LimitSignal {
        var signal = LimitSignal()
        if let after = headers["retry-after"] { signal.wait = Double(after) ?? httpDate(after).map { max(0, $0.timeIntervalSinceNow) } }
        for (name, value) in headers where name.hasPrefix("x-ratelimit-remaining") && Double(value) == 0 {
            guard let reset = headers[name.replacingOccurrences(of: "remaining", with: "reset")].flatMap(duration) else { continue }
            if name.contains("day") { signal.daily = status == 429 || signal.daily; continue }
            signal.wait = max(signal.wait ?? 0, reset)
        }
        return signal
    }

    /// A 429's body: whether the quota that ran out is a daily one, and Gemini's suggested delay.
    static func body(_ text: String) -> LimitSignal {
        let lower = text.lowercased()
        var signal = LimitSignal()
        signal.daily = ["per day", "perday", "per_day", "per-day", "daily", "(rpd)", "(tpd)", "requests_per_day"].contains { lower.contains($0) }
        if let match = text.firstMatch(of: /"retryDelay"\s*:\s*"(\d+(?:\.\d+)?)s"/) { signal.wait = Double(match.1) }
        return signal
    }

    /// `7.66s`, `2m59.56s`, `120ms`, plain seconds, or an epoch time in seconds or milliseconds.
    static func duration(_ text: String) -> Double? {
        if let number = Double(text) {
            if number > 1e12 { return number / 1000 - Date().timeIntervalSince1970 }
            if number > 1e9 { return number - Date().timeIntervalSince1970 }
            return number
        }
        var total = 0.0, matched = false
        for part in text.matches(of: /(\d+(?:\.\d+)?)(ms|h|m|s)/) {
            guard let value = Double(part.1) else { continue }
            matched = true
            switch part.2 { case "ms": total += value / 1000; case "h": total += value * 3600; case "m": total += value * 60; default: total += value }
        }
        return matched ? total : nil
    }

    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}

/// One provider's pace, shared by its models: at most `concurrency` requests in flight, spaced to the
/// requests and tokens a minute it allows (a generic cell rate: no bursts), paused whenever a response
/// says a window is spent, and stopped for the day once `dailyRequests` have gone out.
actor Pacer {
    let pace: LanesConfig.Pace
    private let clock = ContinuousClock()
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var nextRequest: ContinuousClock.Instant
    private var nextTokens: ContinuousClock.Instant
    private var blockedUntil: ContinuousClock.Instant
    private var today: Int
    private var day: String

    private(set) var requests = 0
    private(set) var rateLimited = 0
    private(set) var waited: Duration = .zero
    private var firstSend: Date?
    private var lastAnswer: Date?
    private let monitor: URL?

    /// `usedToday`: requests already sent today, counted from the run's records.
    init(_ pace: LanesConfig.Pace, usedToday: Int = 0, monitor: URL? = nil) {
        self.pace = pace
        self.monitor = monitor
        let now = ContinuousClock.now
        nextRequest = now; nextTokens = now; blockedUntil = now
        today = usedToday
        day = Pacer.day(Date(), zone: pace.dailyReset)
    }

    /// The calendar day a daily limit counts in.
    static func day(_ date: Date, zone: String?) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The next daily reset: midnight in the provider's time zone.
    static func nextReset(after date: Date, zone: String?) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")!
        return calendar.nextDate(after: date, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) ?? date.addingTimeInterval(86_400)
    }

    /// Waits for a slot and the request's turn. Returns how long that took, or nil when today's
    /// requests are spent (nothing is held then).
    func enter(tokens: Int) async -> Duration? {
        let began = clock.now
        if inFlight < max(pace.concurrency ?? 1, 1) { inFlight += 1 } else { await withCheckedContinuation { waiters.append($0) } }
        let current = Pacer.day(Date(), zone: pace.dailyReset)
        if current != day { day = current; today = 0 }
        if let cap = pace.dailyRequests, today >= cap { leave(); return nil }
        // Counted now, before the wait, so requests sleeping side by side can't overrun the cap.
        today += 1
        var at = turn(after: clock.now, tokens: tokens)
        // A pause that starts while this request sleeps sends it to the back of the line, so the
        // requests it held back don't all go at once when it ends.
        while true {
            if blockedUntil > at { at = turn(after: blockedUntil, tokens: tokens) }
            if at <= clock.now { break }
            publish()
            try? await Task.sleep(until: at, clock: clock)
        }
        requests += 1
        if firstSend == nil { firstSend = Date() }
        publish()
        return began.duration(to: clock.now)
    }

    private func turn(after earliest: ContinuousClock.Instant, tokens: Int) -> ContinuousClock.Instant {
        let at = max(earliest, nextRequest, nextTokens)
        if let rpm = pace.rpm, rpm > 0 { nextRequest = at + .seconds(60 / rpm) }
        if let tpm = pace.tpm, tpm > 0 { nextTokens = at + .seconds(60 * Double(tokens) / tpm) }
        return at
    }

    func leave() {
        lastAnswer = Date()
        if waiters.isEmpty { inFlight -= 1 } else { waiters.removeFirst().resume() }
        publish()
    }

    /// Pauses every model of the provider for `seconds`.
    func pause(_ seconds: Double, limited: Bool) {
        if limited { rateLimited += 1 }
        let until = clock.now + .seconds(min(max(seconds, 0), 900))
        if until > blockedUntil { waited += blockedUntil > clock.now ? blockedUntil.duration(to: until) : clock.now.duration(to: until); blockedUntil = until }
        publish()
    }

    private func publish() {
        guard let monitor else { return }
        let remaining = max(0, clock.now.duration(to: max(blockedUntil, nextRequest, nextTokens)) / .seconds(1))
        let value: [String: Any] = ["updated": CallRecord.timestamp(Date()), "requests": requests,
                                    "rate_limited": rateLimited, "occupied_slots": inFlight,
                                    "next_slot": CallRecord.timestamp(Date().addingTimeInterval(remaining))]
        try? FileManager.default.createDirectory(at: monitor.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) { try? data.write(to: monitor, options: .atomic) }
    }

    var achieved: Manifest.Achieved {
        let minutes = firstSend.map { (lastAnswer ?? Date()).timeIntervalSince($0) / 60 } ?? 0
        return Manifest.Achieved(requests: requests, rateLimited: rateLimited, waitedS: (waited / .milliseconds(1)) / 1000,
                                 minutes: (minutes * 100).rounded() / 100, perMinute: minutes > 0 ? (Double(requests) / minutes * 10).rounded() / 10 : nil)
    }
}
