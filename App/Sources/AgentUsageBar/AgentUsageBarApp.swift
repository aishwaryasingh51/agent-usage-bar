import SwiftUI
import AppKit

@main
struct AgentUsageBarApp: App {
    @StateObject private var store = Store()

    init() {
        // Debug aid: `AgentUsageBar --snapshot <dir>` renders the popover and bar label to PNGs, then exits.
        let a = CommandLine.arguments
        if a.contains("--selftest") {
            let fails = Provider.selfTest()
            if fails.isEmpty { print("selftest: 8/8 passed"); exit(0) }
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

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(store)
        } label: {
            MenuLabel(percent: store.topPercent, alarming: store.alarming, iconId: store.topProviderId)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Template (monochrome) normally; a red, non-template bitmap when alarming,
/// because the menu bar only honours colour on non-template images.
struct MenuLabel: View {
    let percent: Double?
    let alarming: Bool
    let iconId: String?

    var body: some View {
        Image(nsImage: render())
    }

    private func render() -> NSImage {
        let text = percent.map { "\(Int(($0 * 100).rounded()))%" }
        let content = HStack(spacing: 3) {
            ProviderIcon.image(for: iconId ?? "", fallback: "gauge.with.dots.needle.50percent", tinted: true)
                .frame(width: 15, height: 15)
            if let text { Text(text).monospacedDigit() }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(alarming ? Color.red : Color.black)
        .padding(.horizontal, 1)

        let r = ImageRenderer(content: content)
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        let img = r.nsImage ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: "Agent Usage Bar") ?? NSImage()
        img.isTemplate = !alarming
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
        for (name, alarm) in [("normal", false), ("alarm", true)] {
            let v = MenuLabel(percent: store.topPercent, alarming: alarm, iconId: store.topProviderId)
                .padding(6).background(Color(white: 0.8))
            let r = ImageRenderer(content: v); r.scale = 3
            if let img = r.cgImage { save(img, "\(dir)/label-\(name).png") }
        }
        exit(0)
    }
    static func save(_ img: CGImage, _ path: String) {
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
