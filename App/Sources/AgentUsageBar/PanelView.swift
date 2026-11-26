import SwiftUI
import Charts

struct PanelView: View {
    @EnvironmentObject var store: Store

    private var selected: Provider? {
        if let id = store.selectedId, let p = store.providers.first(where: { $0.id == id }) { return p }
        return store.providers.first(where: { $0.id == store.topProviderId }) ?? store.providers.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.providers.isEmpty {
                Text("No usage data yet.\nCollectors write JSON to\n\(Store.usageDir.path)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if store.providers.count > 1 { ProviderSwitcher(selected: selected?.id) }
            if let p = selected { ProviderSection(provider: p).id(p.id) }
            Divider()
            HStack {
                Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button { store.refresh(force: true) } label: {
                    if store.refreshing { ProgressView().controlSize(.small) } else { Text("Refresh") }
                }
                .disabled(store.refreshing)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 380)
        // Hug the content: the window must size to it (and shrink on tab switch), never keep a taller size.
        .fixedSize(horizontal: true, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: ContentHeightKey.self, value: g.size.height) })
        .onPreferenceChange(ContentHeightKey.self) { WindowFitter.shared.contentHeight = $0 }
        .background(WindowAccessor())
        // Top-aligned so a taller-than-content window never shows a band above the panel.
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// MenuBarExtra(.window) grows its NSWindow with content but never shrinks it. This resizes the
/// window to the measured content height, keeping the top edge fixed.
@MainActor
final class WindowFitter {
    static let shared = WindowFitter()
    static let logging = CommandLine.arguments.contains("--log-window")
    weak var window: NSWindow?
    var contentHeight: CGFloat = 0 { didSet { if contentHeight != oldValue { schedule() } } }

    func schedule() {
        DispatchQueue.main.async { self.fit() }
    }

    func fit() {
        guard let w = window, contentHeight > 1 else { return }
        let target = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: w.contentLayoutRect.width, height: contentHeight)).height
        if abs(w.frame.height - target) > 0.5 {
            var f = w.frame
            f.origin.y += f.height - target
            f.size.height = target
            w.setFrame(f, display: true, animate: false)
        }
        if Self.logging {
            FileHandle.standardError.write(Data(String(format: "window-height=%.1f content-height=%.1f match=%@\n",
                w.contentLayoutRect.height, contentHeight, abs(w.contentLayoutRect.height - contentHeight) < 1 ? "yes" : "NO").utf8))
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { WindowFitter.shared.window = v.window; WindowFitter.shared.schedule() }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            if WindowFitter.shared.window !== v.window { WindowFitter.shared.window = v.window }
            WindowFitter.shared.schedule()
        }
    }
}

struct ProviderSwitcher: View {
    let selected: String?
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 6) {
            ForEach(store.providers) { p in
                let on = p.id == selected
                let pct = p.maxPercent(now: store.now)
                Button { store.selectedId = p.id } label: {
                    HStack(spacing: 5) {
                        ProviderIcon.image(for: p.id, fallback: "sparkles").frame(width: 14, height: 14)
                        if p.ready == false {
                            Text("–").font(.subheadline).foregroundStyle(.secondary)
                        } else if let pct {
                            Text("\(Int((pct * 100).rounded()))%").font(.subheadline.monospacedDigit())
                                .foregroundStyle(pct >= 0.9 ? Color.red : (on ? Color.primary : Color.secondary))
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(on ? Color.primary.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(p.displayName)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct ProviderSection: View {
    let provider: Provider
    @EnvironmentObject var store: Store

    var body: some View {
        // TimelineView re-evaluates every 30s so countdowns stay live while open.
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            content(now: ctx.date)
        }
    }

    private var notReadyText: String {
        for t in [provider.authHelpText, provider.usageStatusText] {
            if let t, !t.trimmingCharacters(in: .whitespaces).isEmpty { return t }
        }
        return "Couldn't read usage yet. Press Refresh; if it persists, run the collector with --print in Terminal to see why."
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                ProviderIcon.image(for: provider.id, fallback: "sparkles")
                    .frame(width: 16, height: 16)
                Text(provider.displayName).font(.headline)
                Spacer()
                if !provider.plan.isEmpty {
                    Text(provider.plan).font(.caption).foregroundStyle(.secondary)
                }
            }

            if provider.ready == false {
                Note(text: notReadyText, tint: .secondary)
            } else if let status = provider.usageStatusText, !status.isEmpty {
                Note(text: [status, provider.authHelpText ?? ""].filter { !$0.isEmpty }.joined(separator: " — "), tint: .red)
            }
            if provider.limitsStale == true, !(provider.limits ?? []).isEmpty {
                Note(text: "Showing the last known limits; couldn't refresh just now.", tint: .orange)
            }

            if let b = provider.balance, let remaining = b.remaining {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Balance").font(.subheadline)
                        Spacer()
                        Text(Fmt.money(remaining, b.currency))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(b.alarming ? Color.red : Color.primary)
                    }
                    if let ratio = b.ratio {
                        Meter(value: ratio, alarming: b.alarming)
                        if let funded = b.funded, funded > 0 {
                            Text(Fmt.money(b.spent ?? 0, b.currency) + " spent of " + Fmt.money(funded, b.currency) + " funded" + (b.estimated == true ? " · estimated" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            ForEach(provider.windows(now: now), id: \.0.id) { w, pct in
                LimitRow(window: w, percent: pct, now: now)
            }

            if let days = provider.recentDays, days.contains(where: { ($0.messageCount ?? 0) > 0 }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tokens, last 7 days").font(.caption).foregroundStyle(.secondary)
                    Chart(days) { d in
                        BarMark(x: .value("Day", d.id), y: .value("Tokens", d.messageCount ?? 0))
                            .foregroundStyle(d.date == Fmt.todayString() ? Color.accentColor : Color.accentColor.opacity(0.45))
                            .cornerRadius(2)
                    }
                    .chartXAxis {
                        AxisMarks(values: days.map(\.id)) { v in
                            AxisValueLabel {
                                if let s = v.as(String.self) { Text(s == Fmt.todayString() ? "Today" : Fmt.weekday(s)).font(.system(size: 9)) }
                            }
                        }
                    }
                    .chartYAxis { AxisMarks(position: .leading) { v in
                        AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.tokens(d)).font(.system(size: 9)) } }
                    } }
                    .frame(height: 90)
                    if provider.hasPromptStats != false, let tp = provider.todayPrompts {
                        Text("Today: \(Fmt.tokens(provider.todayTotalTokens ?? 0)) tokens · \(Int(tp)) prompts · \(Int(provider.todaySessions ?? 0)) sessions")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            let models = provider.topModels
            if !models.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Top models").font(.caption).foregroundStyle(.secondary)
                    ForEach(models, id: \.name) { m in
                        HStack {
                            Text(m.name).font(.callout)
                            Spacer()
                            Text(Fmt.tokens(m.bucket.total)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .help("In \(Fmt.tokens(m.bucket.inputTokens ?? 0)) · out \(Fmt.tokens(m.bucket.outputTokens ?? 0)) · cache read \(Fmt.tokens(m.bucket.cacheReadInputTokens ?? 0)) · cache write \(Fmt.tokens(m.bucket.cacheCreationInputTokens ?? 0))")
                    }
                }
            }
        }
    }
}

struct LimitRow: View {
    let window: LimitWindow
    let percent: Double
    let now: Date

    var body: some View {
        let alarming = percent >= 0.9
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.displayTitle).font(.subheadline)
                Spacer()
                Text("\(Int((percent * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(alarming ? Color.red : Color.primary)
            }
            Meter(value: min(1, percent), alarming: alarming)
            if let r = window.resetDate, r > now {
                Text("Resets in " + Fmt.duration(r.timeIntervalSince(now)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct Meter: View {
    let value: Double
    let alarming: Bool
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(alarming ? Color.red : Color.accentColor)
                    .frame(width: max(value > 0 ? 4 : 0, g.size.width * value))
            }
        }
        .frame(height: 6)
    }
}

struct Note: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text).font(.caption).foregroundStyle(tint == .secondary ? Color.secondary : tint)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}
