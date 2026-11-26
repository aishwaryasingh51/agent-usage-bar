import Foundation
import AppKit

// Self-updater engine (no UI). The app only ever *checks* on its own; installing happens
// after an explicit confirmation (see UpdateManager). Update = clone/fetch the repo's
// source into a managed checkout, build it with build.sh into a staging folder, verify the
// staged binary, then hand over to a detached helper script that swaps the bundle.

struct UpdateError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Pure logic (unit-tested in --selftest)

enum SemVer {
    /// Strict "X.Y.Z" (ASCII digits only, each part 1...9 digits).
    static func parse(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.utf8.count <= 9, p.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }
    /// True only when both parse and `a` is strictly greater than `b`.
    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parse(a), let y = parse(b) else { return false }
        return x.lexicographicallyPrecedes(y) == false && x != y
    }
}

enum UpdateTag {
    /// Exactly vX.Y.Z (no suffixes, no paths). Written without regex: ICU's `$` also matches before a trailing newline.
    static func isValid(_ t: String) -> Bool {
        guard t.hasPrefix("v") else { return false }
        return SemVer.parse(String(t.dropFirst())) != nil
    }
    static func version(of tag: String) -> String? { isValid(tag) ? String(tag.dropFirst()) : nil }

    /// owner/repo with only the characters GitHub allows.
    static func isValidSlug(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { p in
            !p.isEmpty && p != "." && p != ".." && p.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 46 || $0 == 95
            }
        }
    }

    /// Reads the tag from a `Location` header of /releases/latest:
    /// https://github.com/<slug>/releases/tag/vX.Y.Z (or the same as a relative path).
    static func parseLocation(_ loc: String, slug: String) -> String? {
        guard let c = URLComponents(string: loc.trimmingCharacters(in: .whitespaces)) else { return nil }
        if let h = c.host {
            guard c.scheme == "https", h.lowercased() == "github.com" else { return nil }
        } else if c.scheme != nil { return nil }
        let comps = c.path.split(separator: "/", omittingEmptySubsequences: false)
        guard comps.count == 6, comps[0].isEmpty, comps[3] == "releases", comps[4] == "tag" else { return nil }
        guard "\(comps[1])/\(comps[2])".lowercased() == slug.lowercased() else { return nil }
        let tag = String(comps[5])
        return isValid(tag) ? tag : nil
    }
}

enum CheckoutGuard {
    static func normalizeRemote(_ s: String) -> String {
        var r = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while r.hasSuffix("/") { r.removeLast() }
        if r.hasSuffix(".git") { r.removeLast(4) }
        return r.lowercased().hasPrefix("https://") ? r.lowercased() : r
    }
    static func remoteMatches(_ actual: String, _ expected: String) -> Bool {
        normalizeRemote(actual) == normalizeRemote(expected)
    }
    /// Why the managed checkout must not be used (nil = fine to use).
    static func refusal(porcelain: String, remote: String, expected: String) -> String? {
        if !remoteMatches(remote, expected) {
            return "The update checkout points at a different repository (\(remote.trimmingCharacters(in: .whitespacesAndNewlines))). Delete \(UpdatePaths.checkout.path) to let the app recreate it."
        }
        if !porcelain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The update checkout has local changes, so it was not touched. Delete \(UpdatePaths.checkout.path) to let the app recreate it."
        }
        return nil
    }
}

// MARK: - Test hooks (compiled out of normal builds)

/// Environment variables and command-line flags that redirect the updater exist only in builds made with
/// `AUB_TEST_BUILD=1 ./build.sh` (Swift flag AUB_TEST_HOOKS). A normal build contains none of this code.
enum TestHooks {
    static let enabled: Bool = {
        #if AUB_TEST_HOOKS
        return true
        #else
        return false
        #endif
    }()
    static func env(_ name: String) -> String? {
        #if AUB_TEST_HOOKS
        let v = ProcessInfo.processInfo.environment[name] ?? ""
        return v.isEmpty ? nil : v
        #else
        return nil
        #endif
    }
    static func arg(_ name: String) -> String? {
        #if AUB_TEST_HOOKS
        return Updater.arg(name)
        #else
        return nil
        #endif
    }
}

// MARK: - Paths and log

enum UpdatePaths {
    /// AUB_SUPPORT_DIR overrides the location (test builds only), keeping logs inside it too.
    static var override: String? {
        TestHooks.env("AUB_SUPPORT_DIR").map { ($0 as NSString).expandingTildeInPath }
    }
    static var support: URL {
        if let o = override { return URL(fileURLWithPath: o) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentUsageBar")
    }
    static var logDir: URL {
        if override != nil { return support.appendingPathComponent("logs") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AgentUsageBar")
    }
    static var logFile: URL { logDir.appendingPathComponent("update.log") }
    static var checkout: URL { support.appendingPathComponent("src") }
    static var staging: URL { support.appendingPathComponent("staging") }
    static var helper: URL { support.appendingPathComponent("aub-swap.sh") }
    /// The replaced app is kept here, outside the Applications folder.
    static var backupDir: URL { support.appendingPathComponent("previous") }
    static var backupApp: URL { backupDir.appendingPathComponent("AgentUsageBar.app") }
    static var lockDir: URL { support.appendingPathComponent("update.lock") }
    static var displayLog: String { (logFile.path as NSString).abbreviatingWithTildeInPath }
}

enum UpdateLog {
    private static let lock = NSLock()
    private static let stamp: ISO8601DateFormatter = ISO8601DateFormatter()

    static func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: UpdatePaths.logDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: UpdatePaths.logFile.path) { fm.createFile(atPath: UpdatePaths.logFile.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: UpdatePaths.logFile) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }
    static func write(_ line: String) { append(Data("\(stamp.string(from: Date())) \(line)\n".utf8)) }

    /// Keep the log from growing without bound: drop it when over 1 MB (called at the start of an update).
    static func rotateIfLarge() {
        let size = ((try? FileManager.default.attributesOfItem(atPath: UpdatePaths.logFile.path))?[.size] as? Int) ?? 0
        if size > 1_000_000 { try? FileManager.default.removeItem(at: UpdatePaths.logFile) }
    }
}

// MARK: - Running child processes

struct RunResult {
    let status: Int32
    let output: String
    let timedOut: Bool
    var ok: Bool { status == 0 && !timedOut }
}

private final class OutBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func add(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

enum Shell {
    /// Runs a program in its own process group with a clean environment, captures stdout+stderr
    /// (and copies them to the update log), and kills the whole group on timeout.
    static func run(_ exe: String, _ args: [String], cwd: String? = nil, env: [String: String], timeout: TimeInterval, tee: Bool = true) -> RunResult {
        UpdateLog.write("$ " + ([exe] + args).joined(separator: " ") + (cwd.map { "   (in \($0))" } ?? ""))
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return RunResult(status: -1, output: "pipe() failed", timedOut: false) }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC); _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)

        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fa, fds[1], 1)
        posix_spawn_file_actions_adddup2(&fa, fds[1], 2)
        if let cwd { posix_spawn_file_actions_addchdir_np(&fa, cwd) }
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &fa, &attr, argv, envp)
        close(fds[1])
        if rc != 0 {
            close(fds[0])
            let m = "could not start \(exe): \(String(cString: strerror(rc)))"
            UpdateLog.write(m)
            return RunResult(status: -1, output: m, timedOut: false)
        }

        let box = OutBox()
        let readerDone = DispatchSemaphore(value: 0)
        let rfd = fds[0]
        DispatchQueue.global().async {
            let fh = FileHandle(fileDescriptor: rfd, closeOnDealloc: true)
            while true {
                let d = fh.availableData
                if d.isEmpty { break }
                box.add(d)
                if tee { UpdateLog.append(d) }
            }
            readerDone.signal()
        }

        var st: Int32 = 0
        var timedOut = false
        var waitFailed = false
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let r = waitpid(pid, &st, WNOHANG)
            if r == pid { break }
            if r < 0 { waitFailed = true; UpdateLog.write("waitpid failed: \(String(cString: strerror(errno)))"); break }
            if Date() >= deadline {
                timedOut = true
                kill(-pid, SIGTERM)
                for _ in 0..<40 { if waitpid(pid, &st, WNOHANG) == pid { break }; usleep(50_000) }
                if kill(pid, 0) == 0 { kill(-pid, SIGKILL); waitpid(pid, &st, 0) }
                break
            }
            usleep(50_000)
        }
        // A stray grandchild could hold the pipe open; don't wait for it forever.
        _ = readerDone.wait(timeout: .now() + 5)
        let sig = st & 0x7f
        // If we could not learn how the child ended, that is a failure, never a success.
        let status: Int32 = waitFailed ? -1 : (sig == 0 ? (st >> 8) & 0xff : 128 + sig)
        if timedOut { UpdateLog.write("timed out after \(Int(timeout))s") }
        UpdateLog.write("exit status \(status)")
        return RunResult(status: status, output: box.string, timedOut: timedOut)
    }
}

// MARK: - Engine

enum Updater {
    static let defaultSlug = "aishwaryasingh51/agent-usage-bar"
    static let selfTestCount = versionCases.count + tagCases.count + locationCases.count + remoteCases.count + refusalCases.count + slugCases.count
        + backupCases.count + 2

    static func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    /// The version this process believes it is (--fake-version is a test hook).
    static var currentVersion: String {
        if let f = TestHooks.arg("--fake-version"), SemVer.parse(f) != nil { return f }
        return appVersion
    }

    /// Repo slug: env AUB_UPDATE_REPO (test builds only), else the Info.plist key written by build.sh, else the upstream repo.
    static var slug: String {
        if let env = TestHooks.env("AUB_UPDATE_REPO"), UpdateTag.isValidSlug(env) { return env }
        if let p = Bundle.main.object(forInfoDictionaryKey: "AUBUpdateRepo") as? String, UpdateTag.isValidSlug(p) { return p }
        return defaultSlug
    }

    static func releaseURL(tag: String) -> URL? {
        guard UpdateTag.isValid(tag) else { return nil }
        return URL(string: "https://github.com/\(slug)/releases/tag/\(tag)")
    }

    // MARK: Check

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)   // do not follow: the 302 itself carries the tag
        }
    }

    /// HTTPS HEAD to /releases/latest without following the redirect; the tag is in the Location header.
    /// Deliberately not api.github.com (rate limits).
    static func fetchLatestTag(slug: String) async throws -> String {
        guard UpdateTag.isValidSlug(slug), let url = URL(string: "https://github.com/\(slug)/releases/latest") else {
            throw UpdateError("Invalid update repository name.")
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "HEAD"
        req.setValue("AgentUsageBar/\(appVersion)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UpdateError("Unexpected response from GitHub.") }
        guard [301, 302, 303, 307, 308].contains(http.statusCode) else {
            throw UpdateError(http.statusCode == 404 ? "No releases published yet." : "GitHub answered HTTP \(http.statusCode).")
        }
        guard let loc = http.value(forHTTPHeaderField: "Location"), let tag = UpdateTag.parseLocation(loc, slug: slug) else {
            throw UpdateError("GitHub's answer did not name a valid release tag.")
        }
        return tag
    }

    // MARK: Prerequisites

    static let cleanPath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

    static func baseEnv() -> [String: String] {
        let src = ProcessInfo.processInfo.environment
        var e: [String: String] = [
            "PATH": cleanPath,
            "HOME": TestHooks.env("HOME") ?? NSHomeDirectory(),   // test builds: lets a test point git at a hostile HOME
            "USER": src["USER"] ?? NSUserName(),
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            // Hermetic git: the user's global/system git config (url rewrites, hooks, fsmonitor,
            // credential helpers) must never influence the managed checkout.
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ASKPASS": "",
            "GIT_ALLOW_PROTOCOL": TestHooks.enabled ? "https:file" : "https",
        ]
        if let d = src["DEVELOPER_DIR"] { e["DEVELOPER_DIR"] = d }
        return e
    }

    /// Options put in front of every git command, on top of the hermetic environment.
    static let gitOptions = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "credential.helper=",
                             "-c", "protocol.allow=never", "-c", "protocol.https.allow=always"]
    static var gitProtocolOptions: [String] { TestHooks.enabled ? ["-c", "protocol.file.allow=always"] : [] }

    static let toolsMessage = "Install Xcode Command Line Tools (xcode-select --install) to update in-app."

    /// Path to git when git and swift are both available; nil otherwise. Never triggers the
    /// macOS "install developer tools" prompt: `xcode-select -p` is checked first.
    static func gitPath() -> String? {
        let env = baseEnv()
        guard Shell.run("/usr/bin/xcode-select", ["-p"], env: env, timeout: 20, tee: false).ok else { return nil }
        guard Shell.run("/usr/bin/xcrun", ["--find", "swift"], env: env, timeout: 20, tee: false).ok else { return nil }
        let g = Shell.run("/usr/bin/xcrun", ["--find", "git"], env: env, timeout: 20, tee: false)
        guard g.ok else { return nil }
        let path = g.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        guard Shell.run("/usr/bin/xcrun", ["swift", "--version"], env: env, timeout: 30, tee: false).ok else { return nil }
        return path
    }

    static let backupMessage = "This is the backup copy. Open AgentUsageBar.app to update."

    /// True when the bundle at `bundle` is the saved backup (inside <support>/previous) or is named like one.
    /// Updating from it would replace the very app that is running.
    static func isBackupCopy(bundle: String, backupDir: String) -> Bool {
        let b = URL(fileURLWithPath: bundle).standardizedFileURL
        if b.lastPathComponent.hasSuffix(".previous.app") { return true }
        let dir = URL(fileURLWithPath: backupDir).standardizedFileURL.path
        return b.deletingLastPathComponent().path == dir
    }
    static var runningFromBackup: Bool { isBackupCopy(bundle: Bundle.main.bundleURL.path, backupDir: UpdatePaths.backupDir.path) }

    /// Why in-app updating is unavailable on this Mac (nil = available). Blocking: call off the main thread.
    static func prerequisiteProblem() -> String? {
        if runningFromBackup { return backupMessage }
        if gitPath() == nil { return toolsMessage }
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return "Updating in-app needs the installed app (built with build.sh)." }
        guard FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            return "The app's folder isn't writable, so it can't replace itself. Update with git pull && ./build.sh."
        }
        return nil
    }

    // MARK: Prepare (checkout + build + verify)

    /// Steps 3 and 4 of the design. Returns the verified staged .app. Never touches the installed app.
    static func prepare(tag: String, source: String?, expectedCommit: String? = nil, progress: @escaping (String) -> Void) throws -> URL {
        guard UpdateTag.isValid(tag) else { throw UpdateError("Refusing unexpected tag name.") }
        guard !runningFromBackup else { throw UpdateError(backupMessage) }
        UpdateLog.rotateIfLarge()
        UpdateLog.write("=== update to \(tag) (current \(currentVersion), source \(source ?? "github.com/\(slug)")) ===")
        guard let gitBin = gitPath() else { throw UpdateError(toolsMessage) }
        let fm = FileManager.default
        try? fm.createDirectory(at: UpdatePaths.support, withIntermediateDirectories: true)

        // Expected remote: GitHub over https, or the explicit test source.
        let expected: String
        if let s = source {
            if s.hasPrefix("https://") { expected = s }
            else {
                let p = (s as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { throw UpdateError("Update source \(s) is not a folder or https URL.") }
                expected = URL(fileURLWithPath: p).standardizedFileURL.path
            }
        } else {
            expected = "https://github.com/\(slug).git"
        }

        let src = UpdatePaths.checkout
        let env = baseEnv()
        let opts = gitOptions + gitProtocolOptions
        func git(_ args: [String], timeout: TimeInterval = 60, tee: Bool = true) -> RunResult {
            Shell.run(gitBin, opts + args, cwd: fm.fileExists(atPath: src.path) ? src.path : nil, env: env, timeout: timeout, tee: tee)
        }

        progress("Downloading source…")
        if !fm.fileExists(atPath: src.appendingPathComponent(".git").path) {
            if fm.fileExists(atPath: src.path) { throw UpdateError("\(src.path) exists but is not a git checkout. Delete it and try again.") }
            let r = Shell.run(gitBin, opts + ["clone", "--quiet", "--", expected, src.path], env: env, timeout: 300)
            guard r.ok else { throw UpdateError("Could not download the source: " + lastLine(r.output)) }
        } else {
            // The raw configured URL (`remote get-url` would apply url.*.insteadOf rewrites).
            let remote = git(["config", "--get", "remote.origin.url"], tee: false)
            guard remote.ok else { throw UpdateError("Could not read the update checkout's remote.") }
            // build.sh regenerates this tracked file; put it back so it doesn't count as a local change.
            _ = git(["checkout", "--quiet", "--", "App/Sources/AgentUsageBar/Version.swift"], tee: false)
            let porcelain = git(["status", "--porcelain"], tee: false)
            guard porcelain.ok else { throw UpdateError("Could not inspect the update checkout.") }
            if let why = CheckoutGuard.refusal(porcelain: porcelain.output, remote: remote.output, expected: expected) { throw UpdateError(why) }
            let f = git(["fetch", "--quiet", "--tags", "--force", "origin"], timeout: 300)
            guard f.ok else { throw UpdateError("Could not fetch the source: " + lastLine(f.output)) }
        }

        let ref = "refs/tags/\(tag)"
        let want = git(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], tee: false)
        let wantCommit = want.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard want.ok, !wantCommit.isEmpty else { throw UpdateError("Tag \(tag) was not found in the repository.") }
        if let e = expectedCommit, !e.isEmpty, e != wantCommit {
            throw UpdateError("Tag \(tag) now points at a different commit than the one you confirmed (\(e.prefix(7)) vs \(wantCommit.prefix(7))). Nothing was installed.")
        }
        let co = git(["checkout", "--quiet", "--detach", wantCommit])
        guard co.ok else { throw UpdateError("Could not check out \(tag): " + lastLine(co.output)) }
        let head = git(["rev-parse", "HEAD"], tee: false).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head == wantCommit else { throw UpdateError("Checked-out commit does not match tag \(tag).") }
        UpdateLog.write("checked out \(tag) = \(head)")

        // Build into a fresh staging folder.
        progress("Building \(tag) (a few minutes)…")
        try resetStaging()
        var benv = baseEnv()
        benv["INSTALL_DIR"] = UpdatePaths.staging.path
        benv["AUB_UPDATE_REPO"] = slug
        let b = Shell.run("/bin/bash", ["./build.sh"], cwd: src.path, env: benv, timeout: 600)
        // Whatever build.sh did to the generated Version.swift, leave the checkout clean.
        _ = git(["checkout", "--quiet", "--", "App/Sources/AgentUsageBar/Version.swift"], tee: false)
        guard b.ok else { throw UpdateError(b.timedOut ? "The build took longer than 10 minutes and was stopped." : "The build failed (exit \(b.status)).") }
        let staged = UpdatePaths.staging.appendingPathComponent("AgentUsageBar.app")
        let bin = staged.appendingPathComponent("Contents/MacOS/AgentUsageBar").path
        guard fm.isExecutableFile(atPath: bin) else { throw UpdateError("The build finished but produced no app.") }

        // Verify the staged binary before anything is replaced.
        progress("Checking the new build…")
        let want2 = String(tag.dropFirst())
        let v = Shell.run(bin, ["--version"], env: benv, timeout: 30)
        let reported = v.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.ok, reported == "Agent Usage Bar \(want2)" else {
            throw UpdateError("The new build reports \"\(lastLine(reported))\" instead of version \(want2).")
        }
        let plistVersion = Bundle(url: staged)?.infoDictionary?["CFBundleShortVersionString"] as? String
        guard plistVersion == want2 else { throw UpdateError("The new build's Info.plist version (\(plistVersion ?? "none")) does not match \(want2).") }
        let t = Shell.run(bin, ["--selftest"], env: benv, timeout: 90)
        guard t.ok else { throw UpdateError("The new build failed its own self-test: " + lastLine(t.output)) }
        UpdateLog.write("verified \(tag): \(lastLine(t.output))")
        return staged
    }

    // MARK: Staging, lock, commit lookup

    private static let stagingMarker = ".aub-staging"

    /// Empties <support>/staging. Only ever deletes that exact folder, and only when it carries the
    /// marker the updater itself wrote there (never a folder somebody else put at that path).
    static func resetStaging() throws {
        let fm = FileManager.default
        let dir = UpdatePaths.staging
        if let attrs = try? fm.attributesOfItem(atPath: dir.path) {
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                  fm.fileExists(atPath: dir.appendingPathComponent(stagingMarker).path) else {
                throw UpdateError("\(dir.path) was not created by the updater, so it was left alone. Move or delete it and try again.")
            }
            try fm.removeItem(at: dir)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard fm.createFile(atPath: dir.appendingPathComponent(stagingMarker).path, contents: Data()) else {
            throw UpdateError("Could not prepare the staging folder.")
        }
    }

    /// True only while THIS process holds the lock, so a blocked run never deletes someone else's lock.
    nonisolated(unsafe) private static var holdsLock = false

    /// True while some process (us or another) holds a live update lock. Used to keep housekeeping away from a running build.
    static var lockHeld: Bool {
        if holdsLock { return true }
        guard FileManager.default.fileExists(atPath: UpdatePaths.lockDir.path) else { return false }
        let pid = (try? String(contentsOf: UpdatePaths.lockDir.appendingPathComponent("pid"), encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let o = pid, o > 0 { return kill(o, 0) == 0 || errno == EPERM }
        return lockIsFresh()
    }

    /// A lock folder with no pid yet is a lock being created right now, unless it is old.
    private static func lockIsFresh() -> Bool {
        let m = (try? FileManager.default.attributesOfItem(atPath: UpdatePaths.lockDir.path)[.modificationDate]) as? Date
        return m.map { Date().timeIntervalSince($0) < 30 } ?? false
    }

    /// One update at a time: a lock folder holding our pid. A lock whose process is gone is stale and is cleared.
    static func acquireLock() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: UpdatePaths.support, withIntermediateDirectories: true)
        let pidFile = UpdatePaths.lockDir.appendingPathComponent("pid")
        for _ in 0..<2 {
            if mkdir(UpdatePaths.lockDir.path, 0o755) == 0 {
                do { try Data("\(getpid())\n".utf8).write(to: pidFile) }
                catch { rmdir(UpdatePaths.lockDir.path); throw error }
                holdsLock = true
                return
            }
            let other = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let o = other, o > 0, kill(o, 0) == 0 || errno == EPERM {
                throw UpdateError("Another update is already running (process \(o)).")
            }
            if other == nil, lockIsFresh() { throw UpdateError("Another update is already running (starting up).") }
            UpdateLog.write("clearing stale update lock (pid \(other.map(String.init) ?? "unknown"))")
            try? fm.removeItem(at: pidFile)
            rmdir(UpdatePaths.lockDir.path)
        }
        throw UpdateError("Could not take the update lock at \(UpdatePaths.lockDir.path).")
    }

    static func releaseLock() {
        guard holdsLock else { return }
        holdsLock = false
        try? FileManager.default.removeItem(at: UpdatePaths.lockDir.appendingPathComponent("pid"))
        rmdir(UpdatePaths.lockDir.path)
    }

    /// The commit that `tag` points at on the remote (peeled for annotated tags), found without downloading anything.
    static func resolveTagCommit(tag: String, source: String? = nil) throws -> String {
        guard UpdateTag.isValid(tag) else { throw UpdateError("Refusing unexpected tag name.") }
        guard let gitBin = gitPath() else { throw UpdateError(toolsMessage) }
        let remote = source.map { $0.hasPrefix("https://") ? $0 : ($0 as NSString).expandingTildeInPath } ?? "https://github.com/\(slug).git"
        let r = Shell.run(gitBin, gitOptions + gitProtocolOptions + ["ls-remote", "--", remote, "refs/tags/\(tag)", "refs/tags/\(tag)^{}"],
                          env: baseEnv(), timeout: 60, tee: false)
        guard r.ok else { throw UpdateError("Could not look up \(tag) on GitHub: " + lastLine(r.output)) }
        var direct: String?, peeled: String?
        for line in r.output.split(whereSeparator: \.isNewline) {
            let f = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard f.count == 2, f[0].count == 40, f[0].utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else { continue }
            if f[1] == "refs/tags/\(tag)^{}" { peeled = String(f[0]) } else if f[1] == "refs/tags/\(tag)" { direct = String(f[0]) }
        }
        guard let c = peeled ?? direct else { throw UpdateError("Tag \(tag) was not found on GitHub.") }
        return c
    }

    /// After an update, the new app drops the build cache of the managed checkout (hundreds of MB).
    static func cleanBuildCache() {
        let fm = FileManager.default
        let src = UpdatePaths.checkout
        guard fm.fileExists(atPath: src.appendingPathComponent(".git").path) else { return }   // only inside our own checkout
        guard !lockHeld else { return }   // an update may be building in there right now
        for sub in ["App/.build", ".build"] {
            let d = src.appendingPathComponent(sub)
            if fm.fileExists(atPath: d.path) { try? fm.removeItem(at: d); UpdateLog.write("removed build cache \(d.path)") }
        }
    }

    /// Whole update: lock, prepare, hand over to the swap helper. On success the lock stays (stale once the app quits).
    static func perform(tag: String, expectedCommit: String?, progress: @escaping (String) -> Void) throws {
        try acquireLock()
        do {
            let staged = try prepare(tag: tag, source: nil, expectedCommit: expectedCommit, progress: progress)
            progress("Restarting…")
            try launchSwap(staged: staged)
        } catch { releaseLock(); throw error }
    }

    /// Short text for a failed update check; the technical detail goes to the log.
    static func friendlyCheckError(_ error: Error) -> String {
        if error is URLError { return "Couldn't reach GitHub. Check your connection." }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return "Couldn't reach GitHub. Check your connection." }
        return "Couldn't check: \(error)"
    }

    static func lastLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "(no output)"
    }

    // MARK: Swap

    /// Copies the helper next to the checkout and starts it detached (new session, no stdio). The caller then quits the app.
    static func launchSwap(staged: URL) throws {
        let installed = Bundle.main.bundleURL
        guard installed.pathExtension == "app" else { throw UpdateError("Not running from an app bundle; cannot replace myself.") }
        guard !runningFromBackup else { throw UpdateError(backupMessage) }
        guard installed.lastPathComponent == "AgentUsageBar.app" else { throw UpdateError("The app is not named AgentUsageBar.app, so it can't replace itself.") }
        if !TestHooks.enabled {
            let expected = UpdatePaths.staging.appendingPathComponent("AgentUsageBar.app").standardizedFileURL.path
            guard staged.standardizedFileURL.path == expected else { throw UpdateError("Refusing a staged app outside the updater's staging folder.") }
        }
        guard let res = Bundle.main.resourceURL?.appendingPathComponent("aub-swap.sh"), FileManager.default.fileExists(atPath: res.path) else {
            throw UpdateError("This build has no swap helper (aub-swap.sh).")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: UpdatePaths.support, withIntermediateDirectories: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: UpdatePaths.helper.path, isDirectory: &isDir), !isDir.boolValue { try fm.removeItem(at: UpdatePaths.helper) }
        try fm.copyItem(at: res, to: UpdatePaths.helper)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: UpdatePaths.helper.path)

        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        for fd in [0, 1, 2] as [Int32] { posix_spawn_file_actions_addopen(&fa, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(0x0400))   // POSIX_SPAWN_SETSID: own session, survives our exit

        var args = ["/bin/bash", UpdatePaths.helper.path, String(getpid()), installed.path, staged.path, UpdatePaths.logFile.path, UpdatePaths.backupApp.path]
        if TestHooks.enabled { args.append("--test-hooks") }
        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        var henv = baseEnv()
        for k in ["AUB_OPEN_CMD", "AUB_SETTLE_SECONDS"] { if let v = TestHooks.env(k) { henv[k] = v } }   // test builds only
        let envp: [UnsafeMutablePointer<CChar>?] = henv.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        UpdateLog.write("launching swap helper for pid \(getpid()): \(installed.path) <- \(staged.path)")
        let rc = posix_spawn(&pid, "/bin/bash", &fa, &attr, argv, envp)
        guard rc == 0 else { throw UpdateError("Could not start the swap helper: \(String(cString: strerror(rc)))") }
    }

    // MARK: Command-line test hooks

    private final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    /// Handles --update-check and --update-dry-run; exits the process when one is present.
    static func runCLIIfRequested() {
        let a = CommandLine.arguments
        if a.contains("--update-check") {
            let out = Box<Result<String, Error>>(.failure(UpdateError("no result")))
            let sem = DispatchSemaphore(value: 0)
            let s = slug
            Task.detached { do { out.value = .success(try await fetchLatestTag(slug: s)) } catch { out.value = .failure(error) }; sem.signal() }
            sem.wait()
            switch out.value {
            case .success(let tag):
                let newer = SemVer.isNewer(UpdateTag.version(of: tag) ?? "", than: currentVersion)
                print("repo: \(s)\ncurrent: \(currentVersion)\nlatest: \(tag)\nnewer: \(newer ? "yes" : "no")")
                exit(0)
            case .failure(let e): print("error: \(e)"); exit(1)
            }
        }
        // Test hook: hand a given staged .app to the real swap helper, then quit (exercises the detached spawn).
        if let staged = TestHooks.arg("--update-swap-test") {
            do { try launchSwap(staged: URL(fileURLWithPath: staged)); print("swap helper launched"); exit(0) }
            catch { print("error: \(error)"); exit(1) }
        }
        if a.contains("--update-dry-run") {
            let tag: String
            if let t = arg("--update-tag") { tag = t }
            else {
                let out = Box<String?>(nil)
                let sem = DispatchSemaphore(value: 0)
                let s = slug
                Task.detached { out.value = try? await fetchLatestTag(slug: s); sem.signal() }
                sem.wait()
                guard let t = out.value else { print("error: could not determine the latest tag"); exit(1) }
                tag = t
            }
            do { try acquireLock() } catch {
                print("RESULT: FAILED \(error)")
                print("log: \(UpdatePaths.logFile.path)")
                exit(1)
            }
            do {
                let source = TestHooks.arg("--update-source")
                let commit = try resolveTagCommit(tag: tag, source: source)
                print("tag \(tag) = \(commit.prefix(7))")
                let staged = try prepare(tag: tag, source: source, expectedCommit: commit) { print("stage: \($0)"); fflush(stdout) }
                print("RESULT: ok tag=\(tag) staged=\(staged.path) version=verified selftest=passed")
                print("log: \(UpdatePaths.logFile.path)")
                releaseLock(); exit(0)
            } catch {
                releaseLock()
                print("RESULT: FAILED \(error)")
                print("log: \(UpdatePaths.logFile.path)")
                exit(1)
            }
        }
    }

    // MARK: Selftest

    static let versionCases: [(String, String, Bool)] = [
        ("0.3.0", "0.2.2", true), ("0.2.2", "0.2.2", false), ("0.2.1", "0.2.2", false),
        ("0.10.0", "0.9.9", true), ("1.0.0", "0.99.99", true), ("0.2.3", "0.2.2", true),
        ("1.2", "1.1.0", false), ("1.2.3-rc1", "1.0.0", false), ("x.y.z", "0.0.0", false), ("1.0.0", "garbage", false),
    ]
    static let tagCases: [(String, Bool)] = [
        ("v1.2.3", true), ("v0.3.0", true), ("v10.20.30", true),
        ("v1.2", false), ("v1.2.3-rc", false), ("v1.2.3.4", false), ("1.2.3", false), ("../x", false),
        ("v1.2.3\n", false), ("v1.2.3/../x", false), ("V1.2.3", false), ("v1.2.x", false), ("v", false), ("", false),
        ("v1.2.3 ", false), ("v-1.2.3", false), ("v1..3", false), ("v٣.2.1", false),
    ]
    static let locationCases: [(String, String?)] = [
        ("https://github.com/aishwaryasingh51/agent-usage-bar/releases/tag/v0.2.2", "v0.2.2"),
        ("/aishwaryasingh51/agent-usage-bar/releases/tag/v1.0.0", "v1.0.0"),
        ("https://github.com/AishwaryaSingh51/Agent-Usage-Bar/releases/tag/v0.2.2", "v0.2.2"),
        ("https://github.com/aishwaryasingh51/agent-usage-bar/releases/tag/v0.2.2?x=1", "v0.2.2"),
        ("https://evil.example/aishwaryasingh51/agent-usage-bar/releases/tag/v0.2.2", nil),
        ("http://github.com/aishwaryasingh51/agent-usage-bar/releases/tag/v0.2.2", nil),
        ("https://github.com/someone/else/releases/tag/v0.2.2", nil),
        ("https://github.com/aishwaryasingh51/agent-usage-bar/releases/tag/v0.2.2-rc1", nil),
        ("https://github.com/aishwaryasingh51/agent-usage-bar/releases/tag/..", nil),
        ("https://github.com/aishwaryasingh51/agent-usage-bar/releases/tag/%2e%2e", nil),
        ("https://github.com/aishwaryasingh51/agent-usage-bar/releases", nil),
        ("https://github.com/aishwaryasingh51/agent-usage-bar/login?return_to=/x", nil),
        ("ftp://github.com/aishwaryasingh51/agent-usage-bar/releases/tag/v0.2.2", nil),
    ]
    static let remoteCases: [(String, String, Bool)] = [
        ("https://github.com/aishwaryasingh51/agent-usage-bar.git", "https://github.com/aishwaryasingh51/agent-usage-bar.git", true),
        ("https://github.com/aishwaryasingh51/agent-usage-bar", "https://github.com/aishwaryasingh51/agent-usage-bar.git", true),
        ("https://GitHub.com/AishwaryaSingh51/agent-usage-bar.git\n", "https://github.com/aishwaryasingh51/agent-usage-bar.git", true),
        ("https://github.com/evil/agent-usage-bar.git", "https://github.com/aishwaryasingh51/agent-usage-bar.git", false),
        ("git@github.com:aishwaryasingh51/agent-usage-bar.git", "https://github.com/aishwaryasingh51/agent-usage-bar.git", false),
        ("/Users/x/repo", "/Users/x/repo/", true),
        ("/Users/x/repo", "/Users/x/Repo", false),
    ]
    static let refusalCases: [(String, String, String, Bool)] = [
        ("", "https://github.com/a/b.git", "https://github.com/a/b.git", false),
        ("\n", "https://github.com/a/b.git", "https://github.com/a/b.git", false),
        (" M build.sh\n", "https://github.com/a/b.git", "https://github.com/a/b.git", true),
        ("?? notes.txt\n", "https://github.com/a/b.git", "https://github.com/a/b.git", true),
        ("", "https://github.com/c/d.git", "https://github.com/a/b.git", true),
        (" M x\n", "https://github.com/c/d.git", "https://github.com/a/b.git", true),
    ]
    static let slugCases: [(String, Bool)] = [
        ("aishwaryasingh51/agent-usage-bar", true), ("a/b", true), ("a-b_c.d/e", true),
        ("a", false), ("a/b/c", false), ("/b", false), ("a/", false), ("../x", false), ("a/..", false), ("a b/c", false), ("a/b;rm", false),
    ]

    static let backupCases: [(String, String, Bool)] = [
        ("/Users/x/Library/Application Support/AgentUsageBar/previous/AgentUsageBar.app", "/Users/x/Library/Application Support/AgentUsageBar/previous", true),
        ("/Users/x/Applications/AgentUsageBar.previous.app", "/Users/x/Library/Application Support/AgentUsageBar/previous", true),
        ("/Users/x/Applications/AgentUsageBar.app", "/Users/x/Library/Application Support/AgentUsageBar/previous", false),
        ("/Applications/AgentUsageBar.app", "/Users/x/Library/Application Support/AgentUsageBar/previous", false),
        ("/Users/x/Library/Application Support/AgentUsageBar/previous/../AgentUsageBar.app", "/Users/x/Library/Application Support/AgentUsageBar/previous", false),
    ]

    static func selfTest() -> [String] {
        var f: [String] = []
        for (b, d, want) in backupCases where isBackupCopy(bundle: b, backupDir: d) != want { f.append("backup \(b): want \(want)") }
        if friendlyCheckError(URLError(.notConnectedToInternet)) != "Couldn't reach GitHub. Check your connection." { f.append("friendly error: network") }
        if friendlyCheckError(UpdateError("No releases published yet.")) != "Couldn't check: No releases published yet." { f.append("friendly error: other") }
        for (a, b, want) in versionCases where SemVer.isNewer(a, than: b) != want { f.append("semver \(a) > \(b): want \(want)") }
        for (t, want) in tagCases where UpdateTag.isValid(t) != want { f.append("tag \(t.debugDescription): want valid=\(want)") }
        for (loc, want) in locationCases {
            let got = UpdateTag.parseLocation(loc, slug: "aishwaryasingh51/agent-usage-bar")
            if got != want { f.append("location \(loc): got \(got ?? "nil"), want \(want ?? "nil")") }
        }
        for (a, b, want) in remoteCases where CheckoutGuard.remoteMatches(a, b) != want { f.append("remote \(a) vs \(b): want \(want)") }
        for (p, r, e, refuse) in refusalCases where (CheckoutGuard.refusal(porcelain: p, remote: r, expected: e) != nil) != refuse {
            f.append("refusal porcelain=\(p.debugDescription) remote=\(r): want refuse=\(refuse)")
        }
        for (s, want) in slugCases where UpdateTag.isValidSlug(s) != want { f.append("slug \(s): want \(want)") }
        return f
    }
}
