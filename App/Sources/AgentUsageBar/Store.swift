import Foundation
import SwiftUI
import ServiceManagement

@MainActor
final class Store: ObservableObject {
    @Published var providers: [Provider] = []
    @Published var refreshing = false
    @Published var launchAtLogin = false
    @Published var now = Date()
    /// Last manual provider choice this session; nil = follow the hottest provider.
    @Published var selectedId: String?
    /// True while the popover shows the Settings page instead of the usage panel (reset when it closes).
    @Published var showingSettings = false
    /// Usage bars the user turned off, as "<provider id>|<window id>". Empty = all on, so new bars appear by default.
    @Published private(set) var hiddenLimitKeys: Set<String> = Store.demo ? [] : Set(UserDefaults.standard.stringArray(forKey: Store.hiddenKeysPref) ?? [])
    private static let hiddenKeysPref = "hiddenLimitKeys"
    /// Weekly pace projection on/off (default on). Not persisted in demo runs.
    @Published private(set) var showProjection: Bool = Store.demo ? true : (UserDefaults.standard.object(forKey: Store.projectionPref) as? Bool ?? true)
    private static let projectionPref = "showWeeklyProjection"
    /// Per-window usage history for the pace projection. Never read or written in demo mode.
    private var history: [String: WindowLog] = [:]

    /// True when launched with `--demo`: reads bundled synthetic data, runs no collectors.
    /// Also true when AGENT_USAGE_DIR points at a folder named "demo", so collectors never overwrite it.
    static let demo: Bool = {
        if CommandLine.arguments.contains("--demo") { return true }
        let d = ProcessInfo.processInfo.environment["AGENT_USAGE_DIR"] ?? ""
        return URL(fileURLWithPath: (d as NSString).expandingTildeInPath).lastPathComponent == "demo"
    }()

    /// Usage JSON folder: AGENT_USAGE_DIR, else the bundled demo data (--demo),
    /// else ~/.local/state/agent-usage-bar/usage.
    static let usageDir: URL = {
        let env = ProcessInfo.processInfo.environment
        if let d = env["AGENT_USAGE_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: (d as NSString).expandingTildeInPath)
        }
        if demo {
            if let r = Bundle.main.resourceURL?.appendingPathComponent("demo"),
               FileManager.default.fileExists(atPath: r.path) { return r }
            // Running from a source checkout: docs/demo next to App/.
            let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<6 {
                let c = dir.appendingPathComponent("docs/demo")
                if FileManager.default.fileExists(atPath: c.path) { return c }
                dir = dir.deletingLastPathComponent()
            }
        }
        let state = env["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        return state.appendingPathComponent("agent-usage-bar/usage")
    }()

    private var lastSignature = ""
    private var pollTimer: Timer?
    private var clockTimer: Timer?
    private var collectTask: Task<Void, Never>?

    init() {
        if !Self.demo { try? FileManager.default.createDirectory(at: Self.usageDir, withIntermediateDirectories: true) }
        if !Self.demo { setupLaunchAtLogin(); history = Projection.load() }
        reload()
        // Poll the usage dir every 5s so new/changed files appear live.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        if !Self.demo { startCollectorLoop() }
    }

    // MARK: Visibility (Settings)

    /// Providers with the user's hidden bars removed; a provider with every bar hidden is dropped.
    /// Drives the switcher, panel and menu bar. Never use it for the Settings page.
    var visibleProviders: [Provider] { Visibility.visible(providers, hidden: hiddenLimitKeys) }
    /// True when the user has hidden every bar of every provider that could show one: the panel then says
    /// so instead of showing sign-in help for barless/not-installed providers.
    var allBarsHidden: Bool { Visibility.allHidden(providers, visible: visibleProviders) }
    /// Raw providers that have bars, for the Settings page: unaffected by hiding, so nothing can get stuck hidden.
    var settingsProviders: [Provider] { Visibility.configurable(providers) }

    func isLimitVisible(_ providerId: String, _ w: LimitWindow) -> Bool {
        !hiddenLimitKeys.contains(Visibility.key(providerId, w))
    }

    func setLimitVisible(_ on: Bool, providerId: String, window w: LimitWindow) {
        let k = Visibility.key(providerId, w)
        if on { hiddenLimitKeys.remove(k) } else { hiddenLimitKeys.insert(k) }
        // Demo/snapshot runs must not touch the user's real preferences.
        if !Self.demo { UserDefaults.standard.set(hiddenLimitKeys.sorted(), forKey: Self.hiddenKeysPref) }
    }

    // MARK: Menu bar summary

    /// Ready providers; all providers only when none are ready.
    private var candidates: [Provider] {
        let ready = visibleProviders.filter { $0.ready != false }
        return ready.isEmpty ? visibleProviders : ready
    }
    var topPercent: Double? { candidates.compactMap { $0.maxPercent(now: now) }.max() }
    /// Ready provider whose window is the fullest: its icon labels the menu bar.
    var topProviderId: String? {
        candidates.max { ($0.maxPercent(now: now) ?? -1) < ($1.maxPercent(now: now) ?? -1) }?.id
    }
    /// Providers this Mac actually has (ready); drive the label and the popover tabs.
    var readyProviders: [Provider] { visibleProviders.filter { $0.ready != false } }
    /// Popover tabs: ready providers plus ones whose sign-in expired (so the user sees how to sign in again).
    var tabProviders: [Provider] { visibleProviders.filter { $0.ready != false || $0.signInExpired } }
    /// Menu bar label entries: ready providers only; one neutral "–" entry when none are ready.
    var labelItems: [LabelItem] { LabelItem.items(for: visibleProviders, now: now) }
    var balanceAlarming: Bool { visibleProviders.contains { $0.balance?.alarming == true } }
    var alarming: Bool { (topPercent ?? 0) >= 0.9 || balanceAlarming }

    // MARK: Reading

    func reload() {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: Self.usageDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let sig = files.map { f -> String in
            let v = try? f.resourceValues(forKeys: [.contentModificationDateKey])
            return f.lastPathComponent + "@" + String(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }.joined(separator: ",")
        guard sig != lastSignature else { return }
        lastSignature = sig
        var out: [Provider] = []
        for f in files {
            guard let data = try? Data(contentsOf: f), var p = try? JSONDecoder().decode(Provider.self, from: data) else { continue }
            if p.id.isEmpty { p.id = f.deletingPathExtension().lastPathComponent }
            if Self.demo { p.shiftForDemo(now: Date()) }
            out.append(p)
        }
        // Claude first, then alphabetical.
        providers = out.sorted { ($0.id == "claude" ? "" : $0.id) < ($1.id == "claude" ? "" : $1.id) }
        now = Date()
        recordHistory()
    }

    // MARK: Weekly pace

    func setShowProjection(_ on: Bool) {
        showProjection = on
        if !Self.demo { UserDefaults.standard.set(on, forKey: Self.projectionPref) }
    }

    private func recordHistory() {
        guard !Self.demo else { return }
        var changed = false
        let t = Date().timeIntervalSince1970
        for p in providers {
            for w in p.limits ?? [] where Projection.applies(w) {
                guard let pct = w.percent, pct >= 0, let r = w.resetDate, r.timeIntervalSince1970 > t else { continue }
                let key = Visibility.key(p.id, w)
                var log = history[key] ?? WindowLog()
                if log.record(percent: pct, resetsAt: r.timeIntervalSince1970, now: t) { history[key] = log; changed = true }
            }
        }
        if changed { Projection.save(history) }
    }

    /// Pace for a weekly bar, or nil (toggle off, not weekly, or a quiet gate). Demo = pure week-to-date pace.
    func projection(provider: String, window w: LimitWindow, percent: Double, now: Date) -> Projection.Result? {
        guard showProjection, Projection.applies(w), let r = w.resetDate else { return nil }
        let samples = Self.demo ? [] : (history[Visibility.key(provider, w)]?.samples ?? [])
        return Projection.compute(percent: percent, reset: r, now: now, samples: samples)
    }

    // MARK: Collectors

    /// Bundled collectors plus any in ~/.config/agent-usage-bar/collectors.
    static func collectorScripts() -> [URL] {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("collectors")) }
        dirs.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/agent-usage-bar/collectors"))
        var out: [URL] = []
        for d in dirs {
            let items = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
            out += items.filter { FileManager.default.isExecutableFile(atPath: $0.path) && $0.lastPathComponent.hasPrefix("agent-usage-") }
        }
        return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func refresh(force: Bool = false) {
        guard !refreshing, !Self.demo else { return }
        refreshing = true
        let scripts = Self.collectorScripts()
        var args = ["--write"]
        if force { args.append("--force") }
        else if (topPercent ?? 0) >= 0.9 { args.append("--limits-only") }
        let runArgs = args
        Task.detached {
            await withTaskGroup(of: Void.self) { g in
                for s in scripts { g.addTask { Store.run(s, runArgs) } }
            }
            await MainActor.run {
                self.refreshing = false
                self.lastSignature = ""
                self.reload()
            }
        }
    }

    nonisolated static func run(_ script: URL, _ args: [String]) {
        let p = Process()
        p.executableURL = script
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        // Kill a hung collector after 90s.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: killer)
        p.waitUntilExit()
        killer.cancel()
    }

    /// Run on open, then every 15 min (3 min when any window is >= 90%).
    private func startCollectorLoop() {
        collectTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshing = false
                self.refresh()
                // wait for the run to finish before sleeping
                while self.refreshing { try? await Task.sleep(nanoseconds: 500_000_000) }
                let hot = (self.topPercent ?? 0) >= 0.9
                try? await Task.sleep(nanoseconds: UInt64((hot ? 180.0 : 900.0) * 1e9))
            }
        }
    }

    // MARK: Launch at login (default ON)

    private func setupLaunchAtLogin() {
        // The backup copy must never register itself, record its version, or clean the build cache.
        if Updater.runningFromBackup { launchAtLogin = SMAppService.mainApp.status == .enabled; return }
        let key = "didSetDefaultLaunchAtLogin"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            try? SMAppService.mainApp.register()
        }
        let d = UserDefaults.standard
        // Remember what the user wants. Before this was stored, the current state is the best answer.
        if d.object(forKey: Self.loginPrefKey) == nil { d.set(SMAppService.mainApp.status == .enabled, forKey: Self.loginPrefKey) }
        // After an update the app is a new bundle: if the user wants launch at login and it got dropped, put it back.
        let lastSeen = d.string(forKey: "lastSeenVersion")
        if lastSeen != appVersion {
            d.set(appVersion, forKey: "lastSeenVersion")
            if d.bool(forKey: Self.loginPrefKey), SMAppService.mainApp.status != .enabled {
                do { try SMAppService.mainApp.register(); UpdateLog.write("version changed (\(lastSeen ?? "none") -> \(appVersion)): launch at login re-registered") }
                catch { UpdateLog.write("version changed: could not re-register launch at login: \(error)") }
            }
            Task.detached { Updater.cleanBuildCache() }
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private static let loginPrefKey = "launchAtLoginWanted"

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { NSLog("launch at login: \(error)") }
        UserDefaults.standard.set(on, forKey: Self.loginPrefKey)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
