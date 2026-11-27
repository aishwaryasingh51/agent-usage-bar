import SwiftUI
import AppKit
import Combine

@main
struct AgentUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Debug aid: `AgentUsageBar --snapshot <dir>` renders the popover and bar label to PNGs, then exits.
        let a = CommandLine.arguments
        if a.contains("--help") || a.contains("-h") {
            print("""
            Agent Usage Bar \(appVersion): macOS menu bar app for AI agent usage.

            Usage: AgentUsageBar [option]

              -h, --help        Show this help and exit
              --version         Print the version and exit
              --selftest        Run the built-in checks and exit
              --check-icons     Report which provider icons resolve and exit
              --update-check    Ask GitHub for the latest release and exit
              --snapshot <dir>  Render the popover and bar label to PNGs in <dir>
              --demo            Run with bundled sample data

            With no option the app starts in the menu bar.
            """)
            exit(0)
        }
        if a.contains("--version") { print("Agent Usage Bar \(appVersion)"); exit(0) }
        if a.contains("--selftest") {
            let fails = Provider.selfTest()
            if fails.isEmpty { print("selftest: \(Provider.selfTestCount)/\(Provider.selfTestCount) passed"); exit(0) }
            fails.forEach { print("FAIL " + $0) }
            exit(1)
        }
        if a.contains("--check-icons") {
            for id in ["claude", "agy"] {
                let r = ProviderIcon.resolve(id)
                print("\(id): \(r.source) size=\(Int(r.image?.size.width ?? 0))x\(Int(r.image?.size.height ?? 0))")
            }
            exit(0)
        }
        // Hidden test hooks for the self-updater: --update-check, --update-dry-run [--update-source P] [--update-tag vX.Y.Z],
        // --fake-version X.Y.Z, --fake-latest vX.Y.Z (stubbed "update available" for UI tests).
        Updater.runCLIIfRequested()
        if let i = a.firstIndex(of: "--snapshot"), i + 1 < a.count {
            let dir = a[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { Snapshot.write(dir: dir) }
            }
        }
    }

    // The status item and popover live in AppDelegate (AppKit); SwiftUI only needs a scene.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

struct PanelRoot: View {
    @ObservedObject var store: Store
    @ObservedObject var updater: UpdateManager
    var body: some View { PanelView().environmentObject(store).environmentObject(updater) }
}

/// NSStatusItem + NSPopover: the popover tracks the SwiftUI ideal size both ways (grow and shrink).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = Store()
    private let updater = UpdateManager()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var host: NSHostingController<PanelRoot>!
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObs: NSKeyValueObservation?
    private var lastItems: [LabelItem]?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let logging = CommandLine.arguments.contains("--log-window")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        host = NSHostingController(rootView: PanelRoot(store: store, updater: updater))
        host.sizingOptions = [.preferredContentSize]
        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = host

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(toggle(_:))
            b.imagePosition = .imageOnly
            appearanceObs = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateLabel(force: true) } }
            }
        }
        updateLabel(force: true)
        updater.start()

        store.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the value lands; look again on the next turn.
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.updateLabel(force: false)
                self?.logSizes("data-change")
            } }
        }.store(in: &cancellables)

        if CommandLine.arguments.contains("--open-popover-on-launch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { MainActor.assumeIsolated {
                self.show()
                if self.logging { self.cycleTabs() }
                if CommandLine.arguments.contains("--simulate-outside-click") { self.simulateOutsideClick() }
            } }
        }
    }

    private func updateLabel(force: Bool) {
        let items = store.labelItems
        guard force || items != lastItems else { return }
        lastItems = items
        statusItem.button?.image = MenuLabel(items: items).render()
    }

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) } else { show() }
    }

    private func show() {
        guard let b = statusItem.button, !popover.isShown else { return }
        // An accessory (LSUIElement) app only gets outside clicks while it is active.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installMonitors()
        logSizes("open")
    }

    /// Clicks in other apps never reach us as normal events, so watch globally; Esc is local.
    /// Clicks on our own status item are not delivered to the global monitor, so no double-toggle.
    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.popover.performClose(nil) } }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            if e.keyCode == 53, let self, self.popover.isShown {
                // Esc backs out of Settings first; only the main panel closes the popover.
                if self.store.showingSettings { self.store.showingSettings = false } else { self.popover.performClose(nil) }
                return nil
            }
            return e
        }
    }

    private func removeMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    func popoverDidClose(_ notification: Notification) {
        removeMonitors()
        store.showingSettings = false
    }

    /// Debug (--simulate-outside-click): synthetic mouse-down far from the popover, then log whether it closed.
    private func simulateOutsideClick() {
        let frame = popover.contentViewController?.view.window?.frame ?? .zero
        let screen = NSScreen.main?.frame ?? .zero
        // CGEvent uses top-left origin; pick the screen's lower-left area, well away from the popover.
        let pt = CGPoint(x: screen.minX + 80, y: screen.maxY - 80)
        let cg = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)
        cg?.post(tap: .cghidEventTap)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)
        up?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { MainActor.assumeIsolated {
            print("popover-closed=\(self.popover.isShown ? "no" : "yes") (click at \(Int(pt.x)),\(Int(pt.y)); popover frame \(frame))")
            fflush(stdout)
            exit(0)
        } }
    }

    /// Debug: step through the provider tabs so shrink/grow can be seen in the log.
    private func cycleTabs() {
        let ids = store.providers.map(\.id)
        for (n, id) in (ids + [ids.first].compactMap { $0 }).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 * Double(n + 1)) { MainActor.assumeIsolated {
                self.store.selectedId = id
                self.logSizes("tab-switch(\(id))", delay: 0.3)
            } }
        }
    }

    private func logSizes(_ why: String, delay: Double = 0.3) {
        guard logging, popover.isShown else { return }
        // Let SwiftUI lay out and the popover pick up the new preferred size first.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated {
            guard self.popover.isShown else { return }
            let p = self.popover.contentSize.height
            let c = self.host.view.fittingSize.height
            FileHandle.standardError.write(Data(String(format: "[%@] popover-height=%.1f content-height=%.1f match=%@\n",
                why, p, c, abs(p - c) < 1 ? "yes" : "NO").utf8))
        } }
    }
}

/// One entry per ready provider, in switcher order: logo + 5-hour session %.
/// When none are ready, a single neutral entry (first provider's logo, "–").
struct LabelItem: Equatable {
    let id: String
    let percent: Double?   // nil = unknown
    var alarming: Bool { (percent ?? 0) >= 0.9 }

    static func items(for providers: [Provider], now: Date) -> [LabelItem] {
        let ready = providers.filter { $0.ready != false }
        if ready.isEmpty { return providers.first.map { [LabelItem(id: $0.id, percent: nil)] } ?? [] }
        return ready.map { LabelItem(id: $0.id, percent: $0.sessionPercent(now: now)) }
    }

    static func selfTest() -> [String] {
        func prov(_ id: String, ready: Bool?) -> Provider {
            let r = ready.map { ",\"ready\":\($0)" } ?? ""
            let json = #"{"id":"\#(id)"\#(r),"limits":[{"label":"Session (5-hour)","percent":0.4,"resetsAt":"2099-01-01T00:00:00Z"}]}"#
            return try! JSONDecoder().decode(Provider.self, from: Data(json.utf8))
        }
        let now = Date()
        let cases: [(String, [Provider], [String], [Double?])] = [
            ("both ready", [prov("claude", ready: true), prov("agy", ready: true)], ["claude", "agy"], [0.4, 0.4]),
            ("ready unset counts as ready", [prov("claude", ready: nil), prov("agy", ready: true)], ["claude", "agy"], [0.4, 0.4]),
            ("one ready", [prov("claude", ready: true), prov("agy", ready: false)], ["claude"], [0.4]),
            ("other one ready", [prov("claude", ready: false), prov("agy", ready: true)], ["agy"], [0.4]),
            ("none ready", [prov("claude", ready: false), prov("agy", ready: false)], ["claude"], [nil]),
            ("no providers", [], [], []),
        ]
        return cases.compactMap { name, ps, ids, pcts in
            let got = items(for: ps, now: now)
            return got.map(\.id) == ids && got.map(\.percent) == pcts ? nil : "label \(name): got \(got)"
        }
    }
}

/// A single bitmap holding every provider. Template (monochrome) normally; when any
/// number is red it is a non-template bitmap (the menu bar only honours colour there),
/// with the logos and digits drawn in the current menu bar ink.
struct MenuLabel: View {
    let items: [LabelItem]
    var dark: Bool? = nil

    var body: some View {
        Image(nsImage: render())
    }

    func render() -> NSImage {
        let anyRed = items.contains { $0.alarming }
        let isDark = dark ?? (NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let ink: Color = anyRed ? (isDark ? .white : .black) : .black
        let content = HStack(spacing: 7) {
            ForEach(items, id: \.id) { it in
                HStack(spacing: 2) {
                    ProviderIcon.image(for: it.id, fallback: "gauge.with.dots.needle.50percent", tinted: true)
                        .frame(width: 14, height: 14)
                    Text(it.percent.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                        .monospacedDigit()
                        .foregroundStyle(it.alarming ? Color.red : ink)
                }
            }
            if items.isEmpty { Image(systemName: "gauge").frame(width: 14, height: 14) }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ink)
        .padding(.horizontal, 1)

        let r = ImageRenderer(content: content)
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        let img = r.nsImage ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: "Agent Usage Bar") ?? NSImage()
        img.isTemplate = !anyRed
        return img
    }
}

/// Icon lookup: user override ~/.config/agent-usage-bar/icons/<id>-template.svg,
/// then the bundled <id>-template.svg, then an SF Symbol. SVGs load as template images.
enum ProviderIcon {
    static let symbols = ["claude": "sparkles", "agy": "atom"]

    static func nsImage(_ id: String) -> NSImage? { resolve(id).image }

    /// Which source supplied the icon ("override", "bundled" or "symbol") and the loaded image.
    static func resolve(_ id: String) -> (source: String, image: NSImage?) {
        guard !id.isEmpty, !id.contains("/") else { return ("symbol", nil) }
        let name = "\(id)-template.svg"
        let user = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agent-usage-bar/icons/\(name)")
        var candidates = [("override", user)]
        if let res = Bundle.main.resourceURL {
            candidates.append(("bundled", res.appendingPathComponent("Icons/\(name)")))
        }
        for (source, url) in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let img = NSImage(contentsOf: url), img.size.width > 0 { img.isTemplate = true; return (source, img) }
        }
        return ("symbol", nil)
    }
    @ViewBuilder
    static func image(for id: String, fallback: String, tinted: Bool = false) -> some View {
        if let img = nsImage(id) {
            // Template images take the surrounding foreground style.
            Image(nsImage: img).renderingMode(.template).resizable().scaledToFit()
        } else {
            Image(systemName: symbols[id] ?? fallback).resizable().scaledToFit()
        }
    }
}

@MainActor
enum Snapshot {
    static func write(dir: String) {
        let store = Store()
        let updater = UpdateManager()   // --fake-latest vX.Y.Z stubs the "update available" state
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            for p in [nil] + store.readyProviders.map({ Optional($0.id) }) {
            store.selectedId = p
            let view = PanelView().environmentObject(store).environmentObject(updater)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
                .environment(\.colorScheme, scheme)
            let r = ImageRenderer(content: view); r.scale = 2
            if let img = r.cgImage { save(img, "\(dir)/popover-\(name)" + (p.map { "-\($0)" } ?? "") + ".png") }
            }
        }
        store.selectedId = nil
        // Settings page, same environment as the panel.
        store.showingSettings = true
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let view = PanelView().environmentObject(store).environmentObject(updater)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
                .environment(\.colorScheme, scheme)
            let r = ImageRenderer(content: view); r.scale = 2
            if let img = r.cgImage { save(img, "\(dir)/popover-settings-\(name).png") }
        }
        store.showingSettings = false
        let v = MenuLabel(items: store.labelItems, dark: false)
            .padding(6).background(Color(white: 0.8))
        let r = ImageRenderer(content: v); r.scale = 3
        if let img = r.cgImage { save(img, "\(dir)/label.png") }
        exit(0)
    }
    static func save(_ img: CGImage, _ path: String) {
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
