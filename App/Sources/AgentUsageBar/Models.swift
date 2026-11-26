import Foundation

/// One provider record, decoded leniently from <usage dir>/<id>.json.
/// Every field the app reads is optional so other collectors (agy, ...) can omit what they lack.
struct LimitWindow: Decodable, Identifiable {
    var label: String?
    var title: String?
    var percent: Double?     // 0...1 fraction used
    var resetsAt: String?    // ISO-8601
    var id: String { (title ?? "") + "|" + (label ?? "") }

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        let l = (label ?? "").lowercased()
        if l.contains("week") || l.contains("7-day") { return "Weekly" }
        if l.contains("month") { return "Monthly" }
        if l.contains("session") || l.contains("hour") { return "Session" }
        return (label ?? "").isEmpty ? "Limit" : label!
    }
    var resetDate: Date? { Dates.parse(resetsAt) }

    /// A window whose reset has passed has rolled over: show empty (as the Linux panel does).
    func effectivePercent(now: Date) -> Double? {
        guard let p = percent, p >= 0 else { return nil }
        if let r = resetDate, r <= now { return 0 }
        return p
    }
}

struct Balance: Decodable {
    var remaining: Double?
    var funded: Double?
    var spent: Double?
    var currency: String?
    var estimated: Bool?
    var ratio: Double? {
        guard let f = funded, f > 0, let r = remaining else { return nil }
        return min(1, max(0, r / f))
    }
    var alarming: Bool { (ratio ?? 1) <= 0.1 && (funded ?? 0) > 0 }
}

struct DayUsage: Decodable, Identifiable {
    var date: String
    var messageCount: Double?
    var id: String { date }
}

struct ModelBucket: Decodable {
    var inputTokens: Double?
    var outputTokens: Double?
    var cacheReadInputTokens: Double?
    var cacheCreationInputTokens: Double?
    var total: Double { (inputTokens ?? 0) + (outputTokens ?? 0) + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0) }
}

struct Provider: Decodable, Identifiable {
    var id: String
    var name: String?
    var ready: Bool?
    var tierLabel: String?
    var usageStatusText: String?
    var authHelpText: String?
    var limits: [LimitWindow]?
    var limitsStale: Bool?
    var limitsFetchedAt: Double?
    var retryAdvised: Bool?
    var totalPrompts: Double?
    var totalSessions: Double?
    var activeDays: Double?
    var activeDates: [String]?
    var todayTokensByModel: [String: Double]?
    var balance: Balance?
    var updatedAt: String?
    var hasLocalStats: Bool?
    var hasPromptStats: Bool?
    var todayPrompts: Double?
    var todaySessions: Double?
    var todayTotalTokens: Double?
    var recentDays: [DayUsage]?
    var modelUsage: [String: ModelBucket]?

    var displayName: String { (name?.isEmpty == false) ? name! : id }
    var plan: String {
        guard let t = tierLabel, !t.isEmpty else { return "" }
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    func windows(now: Date) -> [(LimitWindow, Double)] {
        (limits ?? []).compactMap { w in w.effectivePercent(now: now).map { (w, $0) } }
    }
    func maxPercent(now: Date) -> Double? { windows(now: now).map { $0.1 }.max() }

    /// Menu bar value: the 5-hour session window. Picks the limit whose title/label says
    /// session / 5-hour / five hour; otherwise the shortest window (soonest reset).
    func sessionPercent(now: Date) -> Double? {
        let ws = windows(now: now)
        func isSession(_ w: LimitWindow) -> Bool {
            let t = ((w.title ?? "") + " " + (w.label ?? "")).lowercased()
            return t.contains("session") || t.contains("5-hour") || t.contains("5 hour") || t.contains("five hour") || t.contains("five-hour")
        }
        if let m = ws.first(where: { isSession($0.0) }) { return m.1 }
        return ws.min { ($0.0.resetDate ?? .distantFuture) < ($1.0.resetDate ?? .distantFuture) }?.1
    }

    /// Top-4 models by total tokens.
    var topModels: [(name: String, bucket: ModelBucket)] {
        (modelUsage ?? [:]).map { (Provider.friendly($0.key), $0.value) }
            .sorted { $0.1.total > $1.1.total }.prefix(4).map { (name: $0.0, bucket: $0.1) }
    }

    static func friendly(_ id: String) -> String {
        var s = id
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        if let r = s.range(of: #"-\d{8}$"#, options: .regularExpression) { s.removeSubrange(r) }
        let tokens = s.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        if tokens.isEmpty { return id }
        func numeric(_ t: String) -> Bool { t.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil }
        var out = ""
        var prevNumeric = false
        for t in tokens {
            let isNum = numeric(t)
            let word = isNum ? t : t.prefix(1).uppercased() + t.dropFirst()
            if out.isEmpty { out = word } else { out += (isNum && prevNumeric ? "." : " ") + word }
            prevNumeric = isNum
        }
        return out
    }

    /// Returns failure descriptions (empty = all pass). Run via `AgentUsageBar --selftest`.
    static func selfTest() -> [String] {
        let cases: [(String, String)] = [
            ("claude-opus-5", "Opus 5"), ("claude-opus-5-5", "Opus 5.5"),
            ("claude-sonnet-5", "Sonnet 5"), ("claude-sonnet-5-5-20260101", "Sonnet 5.5"),
            ("claude-haiku-4-5-20251001", "Haiku 4.5"),
            ("gemini-2.5-pro-preview", "Gemini 2.5 Pro Preview"),
            ("gemini-3.8-flash-medium", "Gemini 3.8 Flash Medium"),
            ("gemini-4-hydrogen-tiered-high", "Gemini 4 Hydrogen Tiered High"),
        ]
        var fails = cases.compactMap { id, want -> String? in
            let got = friendly(id)
            return got == want ? nil : "\(id): got '\(got)', want '\(want)'"
        }
        fails += sessionSelfTest()
        fails += demoShiftSelfTest()
        return fails
    }

    static let selfTestCount = 8 + 5 + 3

    private static func sessionSelfTest() -> [String] {
        func prov(_ limits: String) -> Provider? {
            try? JSONDecoder().decode(Provider.self, from: Data(#"{"id":"x","limits":\#(limits)}"#.utf8))
        }
        let far = "2099-01-01T00:00:00Z", later = "2099-02-01T00:00:00Z"
        let cases: [(String, String, Double?)] = [
            ("claude-style", #"[{"label":"Session (5-hour)","title":"Session","percent":0.34,"resetsAt":"\#(far)"},{"label":"Weekly (7-day)","title":"Weekly","percent":0.58,"resetsAt":"\#(far)"}]"#, 0.34),
            ("agy-style", #"[{"label":"Weekly (7-day)","title":"Weekly","percent":0.71,"resetsAt":"\#(far)"},{"label":"Session (5-hour)","title":"Session","percent":0.12,"resetsAt":"\#(far)"}]"#, 0.12),
            ("five-hour label", #"[{"label":"Weekly","percent":0.9},{"label":"Five Hour","percent":0.2}]"#, 0.2),
            ("fallback shortest", #"[{"label":"A","percent":0.8,"resetsAt":"\#(later)"},{"label":"B","percent":0.3,"resetsAt":"\#(far)"}]"#, 0.3),
            ("no limits", "[]", nil),
        ]
        return cases.compactMap { name, json, want in
            let got = prov(json)?.sessionPercent(now: Date())
            return got == want ? nil : "session \(name): got \(String(describing: got)), want \(String(describing: want))"
        }
    }
}

extension Provider {
    /// Demo mode only: fixtures carry fixed dates, so make them follow today.
    /// The last recentDays entry becomes today (earlier ones keep their spacing),
    /// and reset times / updatedAt become relative to now. Real collectors are untouched.
    mutating func shiftForDemo(now: Date) {
        let offsets: [TimeInterval] = [2 * 3600 + 13 * 60, 3 * 86400 + 5 * 3600]
        let iso = ISO8601DateFormatter()
        limits = limits?.enumerated().map { i, w in
            var w = w
            w.resetsAt = iso.string(from: now.addingTimeInterval(offsets[min(i, 1)]))
            return w
        }
        updatedAt = iso.string(from: now)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        let cal = Calendar.current
        if let days = recentDays, let last = days.last, let lastDate = f.date(from: last.date) {
            let delta = cal.dateComponents([.day], from: cal.startOfDay(for: lastDate), to: cal.startOfDay(for: now)).day ?? 0
            recentDays = days.map { d in
                var d = d
                if let dt = f.date(from: d.date), let n = cal.date(byAdding: .day, value: delta, to: dt) { d.date = f.string(from: n) }
                return d
            }
        }
    }

    static func demoShiftSelfTest() -> [String] {
        let json = #"{"id":"x","limits":[{"label":"Session (5-hour)","percent":0.3,"resetsAt":"2020-01-01T00:00:00Z"}],"recentDays":[{"date":"2020-01-01","messageCount":1},{"date":"2020-01-02","messageCount":2}]}"#
        guard var p = try? JSONDecoder().decode(Provider.self, from: Data(json.utf8)) else { return ["demo shift: decode failed"] }
        let now = Date()
        p.shiftForDemo(now: now)
        var fails: [String] = []
        if p.recentDays?.last?.date != Fmt.todayString() { fails.append("demo shift: last day \(p.recentDays?.last?.date ?? "nil"), want today") }
        let y = Calendar.current.date(byAdding: .day, value: -1, to: now).map { f -> String in
            let d = DateFormatter(); d.dateFormat = "yyyy-MM-dd"; return d.string(from: f) }
        if p.recentDays?.first?.date != y { fails.append("demo shift: first day not yesterday") }
        if let r = p.limits?.first?.resetDate, r <= now { fails.append("demo shift: reset not in future") } else if p.limits?.first?.resetDate == nil { fails.append("demo shift: reset missing") }
        return fails
    }
}

enum Dates {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let plain = ISO8601DateFormatter()
    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = withFraction.date(from: s) ?? plain.date(from: s) { return d }
        // Python emits microseconds; trim to milliseconds for the formatter.
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            let frac = String(s[r].prefix(4))
            return withFraction.date(from: s.replacingCharacters(in: r, with: frac))
        }
        return nil
    }
}

enum Fmt {
    static func duration(_ interval: TimeInterval) -> String {
        guard interval > 0 else { return "now" }
        let minutes = Int(interval / 60), hours = minutes / 60, days = hours / 24
        if days > 0 { return "\(days)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(max(1, minutes))m"
    }
    static func tokens(_ v: Double) -> String {
        switch v {
        case 1e9...: return String(format: "%.1fB", v / 1e9)
        case 1e6...: return String(format: "%.1fM", v / 1e6)
        case 1e3...: return String(format: "%.1fK", v / 1e3)
        default: return String(Int(v))
        }
    }
    static func money(_ v: Double, _ currency: String?) -> String {
        let prefix: String
        switch (currency ?? "USD").uppercased() {
        case "USD": prefix = "$"; case "EUR": prefix = "€"; case "GBP": prefix = "£"
        default: prefix = (currency ?? "") + " "
        }
        return prefix + String(format: "%.2f", v)
    }
    static func weekday(_ date: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: date) else { return date }
        let o = DateFormatter(); o.dateFormat = "EEE"; return o.string(from: d)
    }
    static func todayString() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }
}
