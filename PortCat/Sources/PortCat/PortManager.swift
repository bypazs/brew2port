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
    /// The Codex CLI, if installed (nil = not found).
    @Published private(set) var codex: CodexStatus? = nil { didSet { if oldValue != codex { onChange?() } } }
    private var codexLatest: (version: String, fetched: Date)?
    /// Updates from Homebrew, npm and the App Store.
    @Published private(set) var extras: [ExtraUpdate] = [] { didSet { if oldValue != extras { onChange?() } } }
    private var lastBrewUpdate: Date?
    private static let notifiedExtrasKey = "notifiedExtras"
    private static let disabledKey = "disabledSources"
    private static let snoozeKey = "snoozedUntil"
    static let codexKey = "Codex"

    /// Sources you turned off (ExtraSource raw values, or "Codex").
    @Published private(set) var disabledSources: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: PortManager.disabledKey) ?? [])
    /// Notifications are paused until this time. The cat and the list still update.
    @Published private(set) var snoozedUntil: Date? =
        UserDefaults.standard.object(forKey: PortManager.snoozeKey) as? Date

    var isSnoozed: Bool { snoozedUntil.map { $0 > Date() } ?? false }
    func isEnabled(_ source: String) -> Bool { !disabledSources.contains(source) }

    func setEnabled(_ source: String, _ enabled: Bool) {
        if enabled { disabledSources.remove(source) } else { disabledSources.insert(source) }
        UserDefaults.standard.set(Array(disabledSources).sorted(), forKey: Self.disabledKey)
        Task { await refresh() }
    }

    func snoozeAlerts(days: Int = 1) {
        let until = Calendar.current.date(byAdding: .day, value: days, to: Date())
        snoozedUntil = until
        UserDefaults.standard.set(until, forKey: Self.snoozeKey)
    }

    func resumeAlerts() {
        snoozedUntil = nil
        UserDefaults.standard.removeObject(forKey: Self.snoozeKey)
    }
    private static let notifiedCodexKey = "notifiedCodexVersion"
    private static let notifiedPortsKey = "notifiedPorts"

    /// Posts macOS notifications; set by the app delegate.
    var notifier: Notifier?

    /// Called whenever something that affects the cat changes.
    var onChange: (@MainActor () -> Void)?

    private var autoTimer: Timer?

    static let brewPath: String? = ["/usr/local/bin/brew", "/opt/homebrew/bin/brew"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    var hasHomebrew: Bool { Self.brewPath != nil }

    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: Self.portPath) }
    var isBusy: Bool { busyMessage != nil }

    /// Outdated ports plus Codex, if it has an update.
    var updateCount: Int { outdated.count + extras.count + (codex?.updateAvailable == true ? 1 : 0) }

    var mood: CatMood {
        if isBusy { return .running }
        if celebrating { return .happy }
        if !isInstalled || problem != nil { return .sad }
        if updateCount > 0 { return .waving }
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
        await checkCodex()
        await checkExtras()
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
        notifyPortsIfNeeded()
    }

    // MARK: - Homebrew, npm and App Store updates

    private func checkExtras() async {
        var found: [ExtraUpdate] = []

        if let brew = Self.brewPath, isEnabled(ExtraSource.brew.rawValue) || isEnabled(ExtraSource.brewCask.rawValue) {
            // Refresh Homebrew's index now and then, otherwise "outdated" goes stale.
            if lastBrewUpdate == nil || Date().timeIntervalSince(lastBrewUpdate!) > 6 * 3600 {
                _ = await Shell.run(brew, ["update", "--quiet"], extraEnv: ["HOMEBREW_NO_ENV_HINTS": "1"])
                lastBrewUpdate = Date()
            }
            let result = await Shell.run(brew, ["outdated", "--json=v2"], extraEnv: Self.brewEnv)
            if result.succeeded { found += Extras.parseBrew(result.output) }
        }
        if let npm = Extras.locate("npm"), isEnabled(ExtraSource.npm.rawValue) {
            // Exit code 1 only means "something is outdated".
            let result = await Shell.run(npm, ["outdated", "-g", "--json"], extraEnv: Extras.environment(for: npm))
            found += Extras.parseNpm(result.output)
        }
        if let mas = Extras.locate("mas"), isEnabled(ExtraSource.appStore.rawValue) {
            let result = await Shell.run(mas, ["outdated"], extraEnv: Extras.environment(for: mas))
            if result.succeeded { found += Extras.parseMas(result.output) }
        }
        extras = found.filter { isEnabled($0.source.rawValue) }
        notifyExtrasIfNeeded()
    }

    /// Runs one upgrade without a shell. Returns nil if the tool or name isn't usable.
    private func runExtra(_ item: ExtraUpdate) async -> CommandResult? {
        guard let command = Extras.upgradeCommand(for: item) else { return nil }
        let result = await Shell.run(command.executable, command.arguments,
                                     extraEnv: Extras.environment(for: command.executable))
        appendLog("\(item.source.rawValue): \(item.title)", result.output)
        return result
    }

    func updateExtra(_ item: ExtraUpdate) async {
        guard !isBusy else { return }
        if item.needsTerminal { openExtrasInTerminal([item]); return }
        busyMessage = "Updating \(item.title)…"
        notice = nil
        let result = await runExtra(item)
        busyMessage = nil
        if let result, result.succeeded {
            problem = nil
            await refresh()
            notice = "\(item.title) is updated."
            celebrate()
        } else {
            let tail = result?.output.split(separator: "\n").suffix(6).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            problem = "\(item.title) didn't update.\n" + (tail.isEmpty ? "Check the log below." : tail)
            await refresh()
        }
    }

    /// Updates everything that doesn't need a password in the background,
    /// then opens Terminal for Homebrew apps (their installers can ask for one).
    func updateAllExtras() async {
        guard !isBusy else { return }
        let background = extras.filter { !$0.needsTerminal }
        let casks = extras.filter(\.needsTerminal)
        var failed: [String] = []
        notice = nil
        for (index, item) in background.enumerated() {
            busyMessage = "Updating \(item.title) (\(index + 1)/\(background.count))…"
            let result = await runExtra(item)
            if result?.succeeded != true { failed.append(item.title) }
        }
        busyMessage = nil
        if !casks.isEmpty { openExtrasInTerminal(casks) }
        if failed.isEmpty {
            problem = nil
            if !background.isEmpty { notice = "Updated \(background.count) package\(background.count == 1 ? "" : "s")." }
            if !background.isEmpty { celebrate() }
        } else {
            problem = "These didn't update: \(failed.joined(separator: ", ")). See the log below."
        }
        await refresh()
    }

    private func openExtrasInTerminal(_ items: [ExtraUpdate]) {
        let lines = items.compactMap { item -> String? in
            guard let command = Extras.upgradeCommand(for: item) else { return nil }
            return ([command.executable] + command.arguments).map { "'\($0)'" }.joined(separator: " ")
        }
        guard !lines.isEmpty else { problem = "Couldn't build the update command."; return }
        let body = """
        #!/bin/bash
        clear
        echo "Updating \(items.map(\.title).joined(separator: ", "))…"
        echo
        \(lines.joined(separator: "\n"))
        echo
        read -r -p "Done. Press Enter to close this window… " _
        """
        do {
            try runInTerminal("extras-update.command", body)
            clearNoticeOnRefresh = true
            notice = "Updating in Terminal. When it's done, click me again to refresh."
        } catch {
            problem = "Couldn't open Terminal: \(error.localizedDescription)"
        }
    }

    /// Notifies once per new set of versions, not on every check.
    private func notifyExtrasIfNeeded() {
        guard !isSnoozed, !extras.isEmpty else { return }
        let current = Set(extras.map { "\($0.id)@\($0.latest)" })
        let seen = Set(UserDefaults.standard.stringArray(forKey: Self.notifiedExtrasKey) ?? [])
        guard !current.isSubset(of: seen) else { return }
        UserDefaults.standard.set(Array(current), forKey: Self.notifiedExtrasKey)
        let names = extras.prefix(4).map(\.title).joined(separator: ", ") + (extras.count > 4 ? "…" : "")
        notifier?.post(id: "extras",
                       title: "\(extras.count) app update\(extras.count == 1 ? "" : "s") available",
                       body: names,
                       category: NotifyID.extrasCategory)
    }

    // MARK: - Codex (updates through its own installer)

    private func checkCodex() async {
        guard isEnabled(Self.codexKey), let path = Codex.locate() else { codex = nil; return }
        let result = await Shell.run(path, ["--version"])
        guard result.succeeded, let current = Codex.parseVersion(result.output) else { codex = nil; return }
        // Ask the network at most once an hour.
        if codexLatest == nil || Date().timeIntervalSince(codexLatest!.fetched) > 60 * 60,
           let fresh = await Codex.latestVersion() {
            codexLatest = (fresh, Date())
        }
        codex = CodexStatus(path: path, current: current, latest: codexLatest?.version,
                            standalone: path == Codex.standalonePath)
        notifyCodexIfNeeded()
    }

    /// Official-installer copies update in the background (no password).
    /// Homebrew/npm copies open Terminal, so the installer can offer to
    /// replace them; after that, updates are one click.
    func updateCodex() async {
        guard let current = codex, !isBusy else { return }
        guard current.standalone else { openCodexInstaller(); return }

        busyMessage = "Updating Codex…"
        notice = nil
        let env = ["CODEX_NON_INTERACTIVE": "1",
                   "PATH": Codex.home + "/.local/bin:" + Shell.searchPath]
        let result = await Shell.run("/bin/bash", ["-c", "set -o pipefail; " + Codex.installCommand], extraEnv: env)
        busyMessage = nil
        appendLog(Codex.installCommand, result.output)
        await checkCodex()
        if result.succeeded, let now = codex, !now.updateAvailable {
            problem = nil
            notice = "Codex is updated to \(now.current)."
            celebrate()
        } else {
            let tail = result.output.split(separator: "\n").suffix(6).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            problem = "Codex didn't update. \(tail)\nYou can also run it in Terminal:\n\(Codex.installCommand)"
        }
    }

    private func openCodexInstaller() {
        let body = """
        #!/bin/bash
        clear
        echo "Updating Codex with the official installer…"
        echo
        \(Codex.installCommand)
        echo
        read -r -p "Done. Press Enter to close this window… " _
        """
        do {
            try runInTerminal("codex-update.command", body)
            clearNoticeOnRefresh = true
            notice = "Codex is updating in Terminal. When it's done, click me again to refresh."
        } catch {
            problem = "Couldn't open Terminal: \(error.localizedDescription)"
        }
    }

    private func notifyCodexIfNeeded() {
        guard !isSnoozed, let status = codex, status.updateAvailable, let latest = status.latest,
              UserDefaults.standard.string(forKey: Self.notifiedCodexKey) != latest else { return }
        UserDefaults.standard.set(latest, forKey: Self.notifiedCodexKey)
        notifier?.post(id: "codex-\(latest)",
                       title: "Codex \(latest) is available",
                       body: "You have \(status.current). Press Update now to install it.",
                       category: NotifyID.codexCategory)
    }

    /// Notifies once per new version, not on every check.
    private func notifyPortsIfNeeded() {
        guard !isSnoozed, !outdated.isEmpty else { return }
        let current = Set(outdated.map { "\($0.name)@\($0.latest)" })
        let seen = Set(UserDefaults.standard.stringArray(forKey: Self.notifiedPortsKey) ?? [])
        guard !current.isSubset(of: seen) else { return }
        UserDefaults.standard.set(Array(current), forKey: Self.notifiedPortsKey)
        let names = outdated.prefix(4).map(\.name).joined(separator: ", ") + (outdated.count > 4 ? "…" : "")
        notifier?.post(id: "ports",
                       title: "\(outdated.count) MacPorts update\(outdated.count == 1 ? "" : "s") available",
                       body: names,
                       category: NotifyID.portsCategory)
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
            let body = """
            #!/bin/bash
            clear
            cd "$HOME"
            BREW2PORT_FROM_PORTCAT=1 bash '\(script)' --apply\(removeHomebrewCopies ? " --uninstall-brew" : "")
            echo
            read -r -p "All done. Press Enter to close this window… " _
            """
            try runInTerminal("brew2port.command", body)
            clearNoticeOnRefresh = true
            notice = removeHomebrewCopies
                ? "Removing old Homebrew copies in Terminal. When it's done, click me again to refresh."
                : "brew2port is running in Terminal. When it's done, click me again to refresh."
        } catch {
            problem = "Couldn't start brew2port: \(error.localizedDescription)"
        }
    }

    /// Writes a .command script to a temp folder and opens it in Terminal.
    private func runInTerminal(_ name: String, _ body: String) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PortCat", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let command = folder.appendingPathComponent(name)
        try body.write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        NSWorkspace.shared.open(command)
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
