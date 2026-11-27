import Foundation

/// Projected weekly pace: where a weekly window is heading by its reset, from the week-to-date rate
/// blended with a recent slope taken from a small on-disk history.
struct UsageSample: Codable, Equatable { var ts: Double; var percent: Double }

/// Samples for one window plus the resetsAt they belong to.
struct WindowLog: Codable, Equatable {
    var resetsAt: Double?
    var samples: [UsageSample] = []

    static let minGap: Double = 15 * 60
    static let minDelta = 0.01
    static let maxSamples = 500
    static let maxAge: Double = 8 * 86400
    /// resetsAt jitters by seconds/minutes on some providers; only a bigger move is a new week.
    static let resetJitter: Double = 3600
    static let dropReset = 0.05

    /// Adds a reading. Returns true when the log changed (so the caller should save).
    @discardableResult
    mutating func record(percent: Double, resetsAt reset: Double, now: Double) -> Bool {
        var changed = false
        if let old = resetsAt, abs(old - reset) > Self.resetJitter { samples = []; changed = true }
        if let last = samples.last, percent < last.percent - Self.dropReset { samples = []; changed = true }
        if resetsAt != reset { resetsAt = reset; changed = true }
        if let last = samples.last, now - last.ts < Self.minGap, abs(percent - last.percent) < Self.minDelta {
            return changed
        }
        samples.append(UsageSample(ts: now, percent: percent))
        samples = samples.filter { now - $0.ts <= Self.maxAge }
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
        return true
    }
}

enum Projection {
    struct Result: Equatable {
        var projected: Double      // unclamped fraction at reset
        var runOut: Date?          // when 100% is reached, if before the reset
        var over: Bool { projected > 1.0 }
    }

    static let maxRecentWeight = 0.35
    static let week: TimeInterval = 7 * 86400

    static var fileURL: URL { UpdatePaths.support.appendingPathComponent("history.json") }

    /// Weekly windows only, and only when the reset time is known.
    static func applies(_ w: LimitWindow) -> Bool {
        let t = ((w.title ?? "") + " " + (w.label ?? "")).lowercased()
        return (t.contains("week") || t.contains("7-day") || t.contains("7d")) && w.resetDate != nil
    }

    /// 0 below 24h of real sample span, ramping linearly to 0.35 at 48h and beyond.
    static func recentWeight(span: TimeInterval) -> Double {
        guard span >= 24 * 3600 else { return 0 }
        return maxRecentWeight * min(1, (span - 24 * 3600) / (24 * 3600))
    }

    static func compute(percent p: Double, reset: Date, now: Date, samples: [UsageSample]) -> Result? {
        let elapsed = now.timeIntervalSince(reset.addingTimeInterval(-week))
        let left = reset.timeIntervalSince(now)
        guard elapsed >= 12 * 3600, left >= 2 * 3600, p >= 0.03, p < 1.0 else { return nil }
        let rWeek = p / elapsed
        // Recent slope over the last 48h of real samples, ending at the current reading.
        let t = now.timeIntervalSince1970
        let recent = (samples.filter { t - $0.ts <= 48 * 3600 && $0.ts <= t } + [UsageSample(ts: t, percent: p)])
            .sorted { $0.ts < $1.ts }
        var rate = rWeek
        if let first = recent.first, let last = recent.last {
            let span = last.ts - first.ts
            let w = recentWeight(span: span)
            if w > 0 {
                let rRecent = max(0, (last.percent - first.percent) / span)
                rate = (1 - w) * rWeek + w * rRecent
            }
        }
        let projected = p + rate * left
        var runOut: Date?
        if projected > 1.0, rate > 0 { runOut = now.addingTimeInterval((1 - p) / rate) }
        return Result(projected: projected, runOut: runOut)
    }

    static func runOutText(_ runOut: Date, now: Date, calendar: Calendar = .current) -> String {
        let secs = runOut.timeIntervalSince(now)
        if secs < 24 * 3600 {
            if secs < 3570 { return "Runs out in ~\(max(1, Int((secs / 60).rounded())))m" }
            return "Runs out in ~\(Int((secs / 3600).rounded()))h"
        }
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE HH:mm"
        return "Runs out ~" + f.string(from: runOut)
    }

    static func label(_ r: Result, now: Date) -> String {
        if !r.over { return "On pace for ~\(Int((min(1, r.projected) * 100).rounded()))%" }
        return r.runOut.map { runOutText($0, now: now) } ?? "Runs out before reset"
    }

    // MARK: File

    /// Missing or corrupt data gives an empty history, never a crash.
    static func decode(_ data: Data?) -> [String: WindowLog] {
        guard let data, let d = try? JSONDecoder().decode([String: WindowLog].self, from: data) else { return [:] }
        return d
    }

    static func load() -> [String: WindowLog] { decode(try? Data(contentsOf: fileURL)) }

    static func save(_ h: [String: WindowLog]) {
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(h) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Selftests

    static let selfTestCount = 33

    static func selfTest() -> [String] {
        var fails: [String] = []
        var n = 0
        func check(_ ok: Bool, _ what: String) { n += 1; if !ok { fails.append("projection: " + what) } }
        func near(_ a: Double?, _ b: Double, _ tol: Double = 1e-6) -> Bool { a.map { abs($0 - b) < tol } ?? false }
        let now = Date(timeIntervalSince1970: 1_800_000_000), t = now.timeIntervalSince1970
        let H: TimeInterval = 3600
        func win(_ json: String) -> LimitWindow { try! JSONDecoder().decode(LimitWindow.self, from: Data(json.utf8)) }
        let far = "2099-01-01T00:00:00Z"

        // Gates
        check(applies(win(#"{"label":"Weekly (7-day)","title":"Weekly","percent":0.5,"resetsAt":"\#(far)"}"#)), "weekly applies")
        check(applies(win(#"{"label":"7d","percent":0.5,"resetsAt":"\#(far)"}"#)), "7d label applies")
        check(!applies(win(#"{"label":"Session (5-hour)","title":"Session","percent":0.5,"resetsAt":"\#(far)"}"#)), "session never applies")
        check(!applies(win(#"{"label":"Weekly","title":"Weekly","percent":0.5}"#)), "weekly without reset never applies")
        check(compute(percent: 0.4, reset: now.addingTimeInterval(7 * 86400 - 6 * H), now: now, samples: []) == nil, "silent under 12h elapsed")
        check(compute(percent: 0.4, reset: now.addingTimeInterval(1 * H), now: now, samples: []) == nil, "silent under 2h remaining")
        let mid = now.addingTimeInterval(84 * H)   // 84h elapsed, 84h left
        check(compute(percent: 0.02, reset: mid, now: now, samples: []) == nil, "silent under 3%")
        check(compute(percent: 1.0, reset: mid, now: now, samples: []) == nil, "silent at 100%")
        check(near(compute(percent: 0.4, reset: mid, now: now, samples: [])?.projected, 0.8), "pure week pace 0.4 at half week -> 0.8")

        // Blend ramp
        check(recentWeight(span: 23 * H) == 0, "no recent weight under 24h")
        check(near(recentWeight(span: 36 * H), 0.175), "half ramp at 36h")
        check(near(recentWeight(span: 48 * H), 0.35) && near(recentWeight(span: 96 * H), 0.35), "capped at 0.35")
        let short = [UsageSample(ts: t - 20 * H, percent: 0.1)]
        check(near(compute(percent: 0.4, reset: mid, now: now, samples: short)?.projected, 0.8), "span under 24h ignores recent slope")
        let rWeek = 0.4 / (84 * H), rRecent = 0.1 / (36 * H)
        let want = 0.4 + (0.825 * rWeek + 0.175 * rRecent) * 84 * H
        check(near(compute(percent: 0.4, reset: mid, now: now, samples: [UsageSample(ts: t - 36 * H, percent: 0.3)])?.projected, want), "36h span blends at 0.175")
        let flat = compute(percent: 0.4, reset: mid, now: now, samples: [UsageSample(ts: t - 48 * H, percent: 0.5)])
        check(near(flat?.projected, 0.4 + 0.65 * rWeek * 84 * H), "negative recent slope clamps to 0")
        check(near(compute(percent: 0.4, reset: mid, now: now, samples: [UsageSample(ts: t - 100 * H, percent: 0.0)])?.projected, 0.8), "samples older than 48h ignored")

        // Over 100% and run-out
        let hot = compute(percent: 0.71, reset: now.addingTimeInterval(76 * H), now: now, samples: [])
        check(hot?.over == true && near(hot.flatMap { $0.runOut }.map { $0.timeIntervalSince(now) / H }, 0.29 * 92 / 0.71, 1e-6), "run-out = (1-p)/rate")
        check(compute(percent: 0.4, reset: mid, now: now, samples: [])?.runOut == nil, "no run-out when on pace")
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let thu = Date(timeIntervalSince1970: 1_795_701_600)   // 2026-11-26 14:00 UTC, a Thursday
        check(runOutText(thu, now: thu.addingTimeInterval(-30 * H), calendar: utc) == "Runs out ~Thu 14:00", "run-out >= 24h shows weekday and time")
        check(runOutText(thu, now: thu.addingTimeInterval(-6 * H), calendar: utc) == "Runs out in ~6h", "run-out < 24h shows hours")
        check(runOutText(thu, now: thu.addingTimeInterval(-30 * 60), calendar: utc) == "Runs out in ~30m", "run-out < 1h shows minutes")
        check(runOutText(thu, now: thu.addingTimeInterval(-3580), calendar: utc) == "Runs out in ~1h", "run-out at 59m40s shows ~1h, not ~60m")

        // History: jitter, reset, throttle, cap
        var log = WindowLog(); let R = 1_900_000_000.0
        log.record(percent: 0.3, resetsAt: R, now: t)
        check(log.record(percent: 0.35, resetsAt: R + 300, now: t + 20 * 60) && log.samples.count == 2, "small resetsAt jitter keeps the log")
        var l2 = log; l2.record(percent: 0.36, resetsAt: R + 2 * H, now: t + 40 * 60)
        check(l2.samples.count == 1, "resetsAt move over 1h starts a new log")
        var l3 = log; l3.record(percent: 0.2, resetsAt: R, now: t + 40 * 60)
        check(l3.samples.count == 1, "percent drop over 0.05 starts a new log")
        var l4 = log; l4.record(percent: 0.32, resetsAt: R, now: t + 40 * 60)
        check(l4.samples.count == 3, "small percent drop keeps the log")
        var th = WindowLog(); th.record(percent: 0.3, resetsAt: R, now: t)
        check(!th.record(percent: 0.305, resetsAt: R, now: t + 10 * 60) && th.samples.count == 1, "throttle: same reading within 15m not stored")
        check(th.record(percent: 0.315, resetsAt: R, now: t + 11 * 60) && th.samples.count == 2, "a 0.01 move is stored early")
        check(th.record(percent: 0.315, resetsAt: R, now: t + 30 * 60) && th.samples.count == 3, "15m gap is stored")
        var cap = WindowLog(); cap.resetsAt = R
        cap.samples = (0..<600).map { UsageSample(ts: t - Double(600 - $0) * 60, percent: 0.3) }
        cap.record(percent: 0.31, resetsAt: R, now: t)
        check(cap.samples.count <= WindowLog.maxSamples, "capped at 500 samples")
        var old = WindowLog(); old.resetsAt = R
        old.samples = [UsageSample(ts: t - 9 * 86400, percent: 0.1), UsageSample(ts: t - 3600, percent: 0.2)]
        old.record(percent: 0.25, resetsAt: R, now: t)
        check(old.samples.allSatisfy { t - $0.ts <= WindowLog.maxAge }, "samples older than 8 days dropped")
        check(decode(Data("not json{".utf8)).isEmpty && decode(nil).isEmpty, "corrupt or missing history starts empty")
        let rt = try? JSONEncoder().encode(["a|b": log])
        check(decode(rt)["a|b"] == log, "history round-trips")
        if n != selfTestCount { fails.append("projection: selfTestCount \(selfTestCount) but ran \(n)") }
        return fails
    }
}
