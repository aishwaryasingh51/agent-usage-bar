import SwiftUI
import AppKit

/// UI-facing side of the self-updater. Checking is the only thing that ever happens on its own;
/// installing needs an explicit click plus a confirmation dialog.
@MainActor
final class UpdateManager: ObservableObject {
    /// Newer release tag (vX.Y.Z), when there is one.
    @Published private(set) var latest: String?
    /// Stage text while an update is being prepared.
    @Published private(set) var busy: String?
    @Published private(set) var failure: String?
    /// Short status for the last manual check ("Up to date", "Couldn't check ...").
    @Published private(set) var status: String?
    @Published private(set) var checking = false
    /// Non-nil when in-app updating can't work on this Mac (git/swift missing, folder not writable).
    @Published private(set) var prereqProblem: String?
    @Published var checkEnabled: Bool {
        didSet {
            UserDefaults.standard.set(checkEnabled, forKey: Self.key)
            scheduleChecks()
        }
    }

    let current = Updater.currentVersion
    private static let key = "checkForUpdates"
    private let fakeLatest: String? = Updater.arg("--fake-latest").flatMap { UpdateTag.isValid($0) ? $0 : nil }
    private var timer: Timer?

    init() {
        checkEnabled = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
        if let f = fakeLatest, SemVer.isNewer(UpdateTag.version(of: f) ?? "", than: current) { latest = f }
    }

    func releaseURL(_ tag: String) -> URL { Updater.releaseURL(tag: tag) ?? URL(string: "https://github.com/\(Updater.slug)/releases")! }

    // MARK: Checking

    func start() {
        if Store.demo && fakeLatest == nil { return }
        if latest != nil { refreshPrereq() }
        scheduleChecks()
    }

    private func scheduleChecks() {
        timer?.invalidate(); timer = nil
        guard checkEnabled, !(Store.demo && fakeLatest == nil) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(manual: false) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.checkEnabled else { return }
            self.check(manual: false)
        }
    }

    func check(manual: Bool) {
        guard !checking, busy == nil else { return }
        if fakeLatest != nil { status = latest == nil ? "Up to date" : nil; return }
        checking = true
        if manual { status = nil }
        let slug = Updater.slug
        Task {
            do {
                let tag = try await Updater.fetchLatestTag(slug: slug)
                apply(tag)
            } catch {
                checking = false
                UpdateLog.write("update check failed: \(error)")
                if manual { status = "Couldn't check: \(error)" }
            }
        }
    }

    private func apply(_ tag: String) {
        checking = false
        if let v = UpdateTag.version(of: tag), SemVer.isNewer(v, than: current) {
            latest = tag; status = nil; failure = nil
            refreshPrereq()
        } else {
            latest = nil; status = "Up to date"
        }
    }

    private func refreshPrereq() {
        Task.detached {
            let p = Updater.prerequisiteProblem()
            await MainActor.run { self.prereqProblem = p }
        }
    }

    // MARK: Installing (always after confirmation)

    func requestUpdate() {
        guard let tag = latest, busy == nil, prereqProblem == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Update Agent Usage Bar to \(tag)?"
        alert.informativeText = """
            This will download the source code for \(tag) from github.com/\(Updater.slug), build it on this Mac (a few minutes), \
            and then restart the app.

            The current version is kept as AgentUsageBar.previous.app so you can go back. If the new build fails its checks, nothing is changed.
            """
        alert.addButton(withTitle: "Update and Restart")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        startUpdate(tag)
    }

    private func startUpdate(_ tag: String) {
        busy = "Preparing…"; failure = nil
        Task.detached {
            do {
                let staged = try Updater.prepare(tag: tag, source: nil) { stage in
                    Task { @MainActor in self.busy = stage }
                }
                await MainActor.run { self.busy = "Restarting…" }
                try Updater.launchSwap(staged: staged)
                await MainActor.run { NSApp.terminate(nil) }
            } catch {
                UpdateLog.write("update failed: \(error)")
                await MainActor.run {
                    self.busy = nil
                    self.failure = "Update to \(tag) failed: \(error) The current version is still installed and running. Log: \(UpdatePaths.displayLog)"
                }
            }
        }
    }

    func revealLog() {
        let url = UpdatePaths.logFile
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.open(url.deletingLastPathComponent()) }
    }
}

/// Footer block of the popover: update banner (when newer), failure note, and the on/off switch.
struct UpdateBar: View {
    @EnvironmentObject var u: UpdateManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tag = u.latest {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                    Text("Update available: \(tag)").font(.subheadline.weight(.semibold))
                    Spacer()
                }
                if let problem = u.prereqProblem {
                    Note(text: problem, tint: .orange)
                    HStack { Link("Release page", destination: u.releaseURL(tag)).font(.caption); Spacer() }
                } else {
                    HStack {
                        Link("What's new", destination: u.releaseURL(tag)).font(.caption)
                        Spacer()
                        if let b = u.busy {
                            ProgressView().controlSize(.small)
                            Text(b).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Update") { u.requestUpdate() }
                        }
                    }
                }
            }
            if let f = u.failure {
                Note(text: f, tint: .red)
                HStack { Button("Show log") { u.revealLog() }.controlSize(.small); Spacer() }
            }
            HStack {
                Toggle("Check for updates", isOn: $u.checkEnabled)
                    .toggleStyle(.switch).controlSize(.small)
                Spacer()
                if u.checking { ProgressView().controlSize(.small) }
                else if let s = u.status {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else { Text("v\(u.current)").font(.caption).foregroundStyle(.secondary) }
                Button("Check now") { u.check(manual: true) }
                    .controlSize(.small).disabled(u.checking || u.busy != nil)
            }
        }
    }
}
