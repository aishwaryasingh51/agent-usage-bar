import SwiftUI

/// The Settings page shown inside the popover: which usage bars to show, plus launch-at-login and update checks.
/// It reads the raw `store.settingsProviders` (never the visibility-filtered list) so a provider whose
/// last bar was switched off can always be switched back on.
struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var updater: UpdateManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                GearButton(symbol: "chevron.left", size: 24, radius: 7) { store.showingSettings = false }
                Text("Settings").font(.headline)
                Spacer()
                Text("v\(updater.current)").font(.caption).foregroundStyle(.secondary)
            }
            Divider()

            SectionLabel("Usage bars")
            if store.settingsProviders.isEmpty {
                Text("No usage bars yet. They appear here once a provider reports its limits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.settingsProviders) { p in
                SettingsCard { ProviderBars(provider: p) }
            }

            SectionLabel("General")
            SettingsCard { GeneralSettings() }
        }
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
}

/// Rounded inset card shared by every settings group; add rows inside it.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One label + switch row. Extend by adding rows to a card; this stays the single row shape.
struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

private struct ProviderBars: View {
    let provider: Provider
    @EnvironmentObject var store: Store

    private func row(_ w: LimitWindow) -> some View {
        SettingsToggleRow(title: w.displayTitle, isOn: Binding(
            get: { store.isLimitVisible(provider.id, w) },
            set: { store.setLimitVisible($0, providerId: provider.id, window: w) }))
    }

    var body: some View {
        let all = provider.limits ?? []
        let main = all.filter { !$0.isGrouped }
        var groups: [String] = []
        for w in all where w.isGrouped && !groups.contains(w.group!) { groups.append(w.group!) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderIcon.image(for: provider.id, fallback: "sparkles").frame(width: 14, height: 14)
                Text(provider.displayName).font(.subheadline.weight(.semibold))
            }
            .padding(.bottom, 2)
            if let heading = provider.mainPoolHeading, !main.isEmpty { PoolHeading(heading) }
            ForEach(main) { row($0) }
            ForEach(groups, id: \.self) { g in
                PoolHeading(g).padding(.top, 2)
                ForEach(all.filter { $0.group == g }) { row($0) }
            }
        }
    }
}

private struct PoolHeading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
}

private struct GeneralSettings: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var u: UpdateManager

    var body: some View {
        SettingsToggleRow(title: "Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
        Divider().opacity(0.6)
        SettingsToggleRow(title: "Check for updates", isOn: $u.checkEnabled)
        HStack(spacing: 8) {
            if u.checking { ProgressView().controlSize(.small) }
            if let b = u.busy { Text(b).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            else if let s = u.status { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            else if let tag = u.latest { Text("Update available: \(tag)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            else { Text("v\(u.current)").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if u.latest != nil, u.prereqProblem == nil, u.busy == nil { Button("Update") { u.requestUpdate() }.controlSize(.small) }
            Button("Check now") { u.check(manual: true) }
                .controlSize(.small).disabled(u.checking || u.busy != nil)
        }
        if let f = u.failure { Note(text: f, tint: .red) }
    }
}
