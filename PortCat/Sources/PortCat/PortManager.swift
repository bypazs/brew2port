import AppKit
import CryptoKit
import Foundation
import ServiceManagement

struct OutdatedPort: Identifiable, Hashable {
    let name: String
    let current: String
    let latest: String
    var id: String { name }
}

/// Talks to MacPorts. Read-only checks run as you; anything that changes
/// the system goes through the macOS admin password dialog.
@MainActor
final class PortManager: NSObject, ObservableObject {
    static let portPath = "/opt/local/bin/port"
    private static let lastSyncKey = "lastSync"
    private static let autoCheckInterval: TimeInterval = 3 * 60 * 60

    @Published private(set) var outdated: [OutdatedPort] = [] { didSet { onChange?() } }
    @Published private(set) var requested: [String] = []
    @Published private(set) var busyMessage: String? = nil { didSet { onChange?() } }
    @Published private(set) var problem: String? = nil { didSet { onChange?() } }
    @Published private(set) var celebrating = false { didSet { onChange?() } }
    @Published private(set) var notice: String? = nil
    @Published private(set) var lastChecked: Date? = nil
    @Published private(set) var lastSync: Date? = UserDefaults.standard.object(forKey: PortManager.lastSyncKey) as? Date
    @Published private(set) var version = ""
    @Published private(set) var log = ""
    /// Formulae still installed by Homebrew, minus the ones you chose to keep
    /// there (nil = Homebrew not found).
    @Published private(set) var homebrewLeftNames: [String]? = nil
    /// Homebrew dependencies nothing needs anymore (brew autoremove would remove them).
    @Published private(set) var homebrewOrphans: [String] = []
    @Published private(set) var keptInHomebrew: [String] =
        UserDefaults.standard.stringArray(forKey: PortManager.keptKey) ?? []
    private static let keptKey = "keptInHomebrew"
    /// Set after sending the user to Terminal; the next refresh clears the notice.
    private var clearNoticeOnRefresh = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Called whenever something that affects the cat changes.
    var onChange: (@MainActor () -> Void)?

    private var autoTimer: Timer?

    static let brewPath: String? = ["/usr/local/bin/brew", "/opt/homebrew/bin/brew"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    var hasHomebrew: Bool { Self.brewPath != nil }

    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: Self.portPath) }
    var isBusy: Bool { busyMessage != nil }

    var mood: CatMood {
        if isBusy { return .running }
        if celebrating { return .happy }
        if !isInstalled || problem != nil { return .sad }
        if !outdated.isEmpty { return .waving }
        return .sleeping
    }

    /// Days since the package index was last synced, if known.
    var indexAgeDays: Int? {
        guard let lastSync else { return nil }
        return Calendar.current.dateComponents([.day], from: lastSync, to: Date()).day
    }

    // MARK: - Lifecycle

    func start() {
        Task { await refresh() }
        let timer = Timer(timeInterval: Self.autoCheckInterval, target: self,
                          selector: #selector(autoCheck), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        autoTimer = timer
    }

    @objc private func autoCheck() {
        guard !isBusy else { return }
        Task { await refresh() }
    }

    // MARK: - Read-only checks (no password)

    func refresh() async {
        guard !isBusy else { return }
        if clearNoticeOnRefresh { notice = nil; clearNoticeOnRefresh = false }
        await countHomebrewFormulae()
        guard isInstalled else {
            problem = nil
            outdated = []
            requested = []
            onChange?()
            return
        }
        busyMessage = "Checking your ports…"
        async let outdatedResult = Shell.run(Self.portPath, ["-q", "outdated"])
        async let requestedResult = Shell.run(Self.portPath, ["-q", "echo", "requested"])
        async let versionResult = Shell.run(Self.portPath, ["version"])
        let (o, r, v) = await (outdatedResult, requestedResult, versionResult)

        outdated = Self.parseOutdated(o.output)
        requested = Self.parseNames(r.output)
        version = v.output.components(separatedBy: ":").last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lastChecked = Date()
        busyMessage = nil
        if !o.succeeded { appendLog("port outdated", o.output) }
    }

    private func countHomebrewFormulae() async {
        guard let brew = Self.brewPath else { homebrewLeftNames = nil; homebrewOrphans = []; return }
        async let orphanResult = Shell.run(brew, ["autoremove", "--dry-run"], extraEnv: Self.brewEnv)
        let result = await Shell.run(brew, ["leaves", "--installed-on-request"], extraEnv: Self.brewEnv)
        homebrewOrphans = Self.parseAutoremove(await orphanResult.output)
        guard result.succeeded else { homebrewLeftNames = nil; return }
        let kept = Set(keptInHomebrew)
        homebrewLeftNames = result.output.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !kept.contains($0) }
    }

    private static let brewEnv = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1"]

    /// "==> Would autoremove 3 unneeded formulae:" followed by one name per line.
    static func parseAutoremove(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") && isValidName($0.components(separatedBy: "/").last ?? $0) }
    }

    /// Removes Homebrew dependencies nothing uses anymore, then clears
    /// Homebrew's download cache. Runs as you; no password needed.
    func cleanHomebrew() async {
        guard let brew = Self.brewPath, !isBusy, !homebrewOrphans.isEmpty else { return }
        let count = homebrewOrphans.count
        busyMessage = "Cleaning up Homebrew…"
        let removed = await Shell.run(brew, ["autoremove"], extraEnv: Self.brewEnv)
        appendLog("brew autoremove", removed.output)
        let cleaned = await Shell.run(brew, ["cleanup", "--prune=all"], extraEnv: Self.brewEnv)
        appendLog("brew cleanup --prune=all", cleaned.output)
        busyMessage = nil
        if removed.succeeded {
            notice = "Removed \(count) leftover Homebrew package\(count == 1 ? "" : "s") and cleared its download cache."
            await refresh()
            celebrate()
        } else {
            problem = removed.output.split(separator: "\n").suffix(6).joined(separator: "\n")
            await refresh()
        }
    }

    /// Remembers formulae you want to leave in Homebrew (e.g. no MacPorts port).
    func keepInHomebrew(_ names: [String]) {
        keptInHomebrew = Array(Set(keptInHomebrew).union(names)).sorted()
        UserDefaults.standard.set(keptInHomebrew, forKey: Self.keptKey)
        homebrewLeftNames = homebrewLeftNames?.filter { !names.contains($0) }
    }

    func forgetKept() {
        keptInHomebrew = []
        UserDefaults.standard.removeObject(forKey: Self.keptKey)
        Task { await refresh() }
    }

    func diagnose() async {
        guard isInstalled, !isBusy else { return }
        busyMessage = "Running port diagnose…"
        let result = await Shell.run(Self.portPath, ["diagnose", "--quiet"])
        busyMessage = nil
        appendLog("port diagnose", result.output)
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            problem = nil
            notice = "port diagnose found no problems."
        } else {
            problem = text
        }
    }

    // MARK: - Admin actions (password dialog)

    /// Syncs the package index, then re-checks what's outdated.
    func syncAndCheck() async {
        let ok = await admin("Updating MacPorts…", "\(Self.portPath) -N selfupdate")
        if ok { markSynced() }
        await refresh()
    }

    /// Syncs and upgrades everything in one password prompt.
    func upgradeAll() async {
        let ok = await admin("Upgrading \(outdated.count) port(s)…",
                             "\(Self.portPath) -N selfupdate && \(Self.portPath) -N upgrade outdated")
        if ok { markSynced() }
        await refresh()
        if ok { celebrate() }
    }

    func upgrade(_ port: OutdatedPort) async {
        guard Self.isValidName(port.name) else { return }
        let ok = await admin("Upgrading \(port.name)…", "\(Self.portPath) -N upgrade \(port.name)")
        await refresh()
        if ok { celebrate() }
    }

    func reclaim() async {
        let ok = await admin("Cleaning up old versions…", "\(Self.portPath) -N reclaim")
        if ok { notice = "Cleaned up old versions and unused files." }
    }

    /// Returns true on success. Cancel in the password dialog is not an error.
    private func admin(_ message: String, _ command: String, needsMacPorts: Bool = true) async -> Bool {
        guard !isBusy, isInstalled || !needsMacPorts else { return false }
        busyMessage = message
        notice = nil
        let result = await Shell.runAsAdmin(command)
        busyMessage = nil
        if result.userCancelled { return false }
        appendLog(command, result.output)
        if result.succeeded {
            problem = nil
            return true
        }
        let tail = result.output.split(separator: "\n").suffix(6).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        problem = tail.isEmpty ? "The command failed (exit code \(result.status))." : tail
        return false
    }

    // MARK: - Installing MacPorts

    private static let fallbackMacPortsVersion = "2.12.6"
    private static let installerNames = [11: "11-BigSur", 12: "12-Monterey", 13: "13-Ventura",
                                         14: "14-Sonoma", 15: "15-Sequoia", 26: "26-Tahoe"]

    /// Downloads the official .pkg for this macOS, verifies its SHA256 and
    /// Apple Developer ID signature, then installs it (password dialog).
    func installMacPorts() async {
        guard !isBusy, !isInstalled else { return }
        notice = nil
        problem = nil

        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard let suffix = Self.installerNames[major] else {
            problem = "There's no MacPorts installer I know of for macOS \(major). Use “Get MacPorts” instead."
            return
        }

        busyMessage = "Checking the Command Line Tools…"
        if !(await Shell.run("/usr/bin/xcode-select", ["-p"]).succeeded) {
            _ = await Shell.run("/usr/bin/xcode-select", ["--install"])
            busyMessage = nil
            problem = "MacPorts needs the Xcode Command Line Tools. Apple's installer just opened; " +
                      "press Install there, then come back and try again."
            return
        }

        busyMessage = "Finding the latest MacPorts…"
        let version = await Self.latestMacPortsVersion() ?? Self.fallbackMacPortsVersion
        let file = "MacPorts-\(version)-\(suffix).pkg"
        let base = "https://github.com/macports/macports-base/releases/download/v\(version)/"

        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PortCat", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let pkgURL = folder.appendingPathComponent(file)

            busyMessage = "Downloading \(file)…"
            let (downloaded, response) = try await URLSession.shared.download(from: URL(string: base + file)!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw InstallError("Download failed (\(file)).")
            }
            try? FileManager.default.removeItem(at: pkgURL)
            try FileManager.default.moveItem(at: downloaded, to: pkgURL)

            busyMessage = "Verifying the download…"
            let (checksums, _) = try await URLSession.shared.data(from: URL(string: base + "MacPorts-\(version).chk.txt")!)
            // MacPorts labels the .pkg hashes "SHA2-256(...)" and tarballs "SHA256(...)".
            let keys = ["SHA2-256(\(file))=", "SHA256(\(file))="]
            guard let line = String(decoding: checksums, as: UTF8.self)
                    .split(separator: "\n").first(where: { l in keys.contains { l.hasPrefix($0) } }),
                  let expected = line.split(separator: " ").last.map(String.init) else {
                throw InstallError("No published SHA256 for \(file). Not installing.")
            }
            let actual = SHA256.hash(data: try Data(contentsOf: pkgURL))
                .map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else {
                throw InstallError("SHA256 mismatch for \(file). Not installing.")
            }

            let signature = await Shell.run("/usr/sbin/pkgutil", ["--check-signature", pkgURL.path])
            guard signature.output.contains("signed by a developer certificate issued by Apple") else {
                throw InstallError("\(file) isn't signed with an Apple Developer ID. Not installing.")
            }
            appendLog("verify \(file)", "SHA256 OK\n" + signature.output)
            busyMessage = nil

            guard !pkgURL.path.contains("'") else { throw InstallError("Unexpected download path.") }
            let ok = await admin("Installing MacPorts \(version)…",
                                 "/usr/sbin/installer -pkg '\(pkgURL.path)' -target / && \(Self.portPath) -N selfupdate",
                                 needsMacPorts: false)
            try? FileManager.default.removeItem(at: pkgURL)
            if ok {
                markSynced()
                await refresh()
                notice = "MacPorts \(version) is installed. Welcome to the harbor!"
                celebrate()
            }
        } catch {
            busyMessage = nil
            var message = (error as? InstallError)?.message ?? error.localizedDescription
            if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { message = "\(error)" }
            problem = "Install failed: " + message
            appendLog("install MacPorts", "\(error)")
        }
    }

    /// Reads the version from GitHub's /releases/latest redirect.
    private static func latestMacPortsVersion() async -> String? {
        guard let url = URL(string: "https://github.com/macports/macports-base/releases/latest"),
              let result = try? await URLSession.shared.data(from: url),
              let tag = result.1.url?.lastPathComponent, tag.hasPrefix("v") else { return nil }
        let version = String(tag.dropFirst())
        return version.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil ? version : nil
    }

    // MARK: - Migrating from Homebrew

    /// Asks first, then runs brew2port with --uninstall-brew: it removes each
    /// Homebrew formula only after its MacPorts port is installed, and keeps
    /// anything with no match or that other formulae still need.
    func openRemoval() {
        let alert = NSAlert()
        alert.messageText = "Remove the old Homebrew copies?"
        alert.informativeText = """
        Terminal will open and show a plan first. For each package, the Homebrew copy is \
        removed only once the MacPorts version is installed. Packages with no MacPorts \
        match, or that other formulae still need, stay in Homebrew.

        Homebrew itself is not uninstalled (it can't be reinstalled on Intel Macs).
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue in Terminal")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openMigration(removeHomebrewCopies: true)
    }

    /// Opens Terminal and runs the bundled brew2port.sh, which shows the plan
    /// and asks before changing anything.
    func openMigration(removeHomebrewCopies: Bool = false) {
        guard let script = Bundle.main.path(forResource: "brew2port", ofType: "sh") else {
            problem = "brew2port.sh isn't bundled in this build. Rebuild with build-app.sh from the brew2port folder."
            return
        }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PortCat", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let command = folder.appendingPathComponent("brew2port.command")
            let body = """
            #!/bin/bash
            clear
            cd "$HOME"
            BREW2PORT_FROM_PORTCAT=1 bash '\(script)' --apply\(removeHomebrewCopies ? " --uninstall-brew" : "")
            echo
            read -r -p "All done. Press Enter to close this window… " _
            """
            try body.write(to: command, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
            NSWorkspace.shared.open(command)
            clearNoticeOnRefresh = true
            notice = removeHomebrewCopies
                ? "Removing old Homebrew copies in Terminal. When it's done, click me again to refresh."
                : "brew2port is running in Terminal. When it's done, click me again to refresh."
        } catch {
            problem = "Couldn't start brew2port: \(error.localizedDescription)"
        }
    }

    // MARK: - Misc

    func dismissProblem() { problem = nil }
    func dismissNotice() { notice = nil }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            notice = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func celebrate() {
        celebrating = true
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            celebrating = false
        }
    }

    private func markSynced() {
        let now = Date()
        lastSync = now
        UserDefaults.standard.set(now, forKey: Self.lastSyncKey)
    }

    private func appendLog(_ title: String, _ output: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        let entry = "[\(stamp)] $ \(title)\n\(output.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        log = String((entry + log).prefix(20_000))
    }

    // MARK: - Parsing

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.range(of: "^[A-Za-z0-9._+-]+$", options: .regularExpression) != nil
    }

    /// Lines look like: "git   2.50.0_0 < 2.51.0_0"
    static func parseOutdated(_ text: String) -> [OutdatedPort] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 4, parts[2] == "<", isValidName(parts[0]) else { return nil }
            return OutdatedPort(name: parts[0], current: parts[1], latest: parts[3])
        }
    }

    /// Lines look like: "git   @2.51.0_0" — keep the first word.
    static func parseNames(_ text: String) -> [String] {
        let names = text.split(separator: "\n").compactMap { line -> String? in
            guard let first = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { return nil }
            let name = String(first)
            return isValidName(name) ? name : nil
        }
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

struct InstallError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
