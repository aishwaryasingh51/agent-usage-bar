import SwiftUI
import AppKit
import Combine

@main
struct AgentUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Debug aid: `AgentUsageBar --snapshot <dir>` renders the popover and bar label to PNGs, then exits.
        let a = CommandLine.arguments
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
    var body: some View { PanelView().environmentObject(store) }
}

/// NSStatusItem + NSPopover: the popover tracks the SwiftUI ideal size both ways (grow and shrink).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var host: NSHostingController<PanelRoot>!
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObs: NSKeyValueObservation?
    private var lastItems: [LabelItem]?
    private let logging = CommandLine.arguments.contains("--log-window")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        host = NSHostingController(rootView: PanelRoot(store: store))
        host.sizingOptions = [.preferredContentSize]
        popover = NSPopover()
        popover.behavior = .transient
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
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        logSizes("open")
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

/// One entry per provider, in switcher order: logo + 5-hour session %, or "–" when not ready.
struct LabelItem: Equatable {
    let id: String
    let percent: Double?   // nil = not ready / unknown
    var alarming: Bool { (percent ?? 0) >= 0.9 }
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
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            for p in [nil] + store.providers.map({ Optional($0.id) }) {
            store.selectedId = p
            let view = PanelView().environmentObject(store)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
                .environment(\.colorScheme, scheme)
            let r = ImageRenderer(content: view); r.scale = 2
            if let img = r.cgImage { save(img, "\(dir)/popover-\(name)" + (p.map { "-\($0)" } ?? "") + ".png") }
            }
        }
        store.selectedId = nil
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
