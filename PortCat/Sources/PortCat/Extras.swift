import Foundation

/// Where an update comes from. MacPorts and Codex have their own code paths;
/// these are the other package managers PortCat can look at.
enum ExtraSource: String, CaseIterable {
    case brew = "Homebrew"
    case brewCask = "Homebrew app"
    case npm = "npm"
    case appStore = "App Store"
}

struct ExtraUpdate: Identifiable, Hashable {
    let source: ExtraSource
    /// What the tool needs to upgrade it: formula/cask/package name, or the App Store id.
    let name: String
    /// What to show in the list.
    let title: String
    let current: String
    let latest: String
    /// The install folder isn't yours (e.g. MacPorts' npm under /opt/local), so it needs sudo.
    var needsAdmin = false
    var id: String { source.rawValue + ":" + name }

    /// Cask installers and sudo can ask for a password, which needs a real Terminal.
    var needsTerminal: Bool { source == .brewCask || needsAdmin }
}

/// Finds, parses and builds commands for the extra package managers.
/// Everything here is pure or read-only; PortManager decides when to run it.
enum Extras {
    /// Codex has its own updater (see Codex.swift), so skip it here to avoid listing it twice.
    private static let skipped: Set<String> = ["codex", "@openai/codex"]

    /// Names are passed as arguments (never through a shell), but still refuse
    /// anything that could look like an option or contain odd characters.
    static func isValidName(_ name: String) -> Bool {
        name.range(of: "^@?[A-Za-z0-9][A-Za-z0-9@._+/-]*$", options: .regularExpression) != nil
    }

    // MARK: - Locating tools

    static func locate(_ tool: String) -> String? {
        ["/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin"]
            .map { "\($0)/\(tool)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// npm and its scripts start `node` through env, so node's folder must be on PATH.
    static func environment(for executable: String) -> [String: String] {
        let dir = (executable as NSString).deletingLastPathComponent
        return ["PATH": "\(dir):/usr/local/bin:" + Shell.searchPath,
                "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1"]
    }

    // MARK: - Commands

    /// The program and arguments that upgrade one item, or nil if the name looks unsafe.
    @MainActor
    static func upgradeCommand(for item: ExtraUpdate) -> (executable: String, arguments: [String])? {
        guard isValidName(item.name) || item.source == .appStore else { return nil }
        switch item.source {
        case .brew:
            guard let brew = PortManager.brewPath else { return nil }
            return (brew, ["upgrade", item.name])
        case .brewCask:
            guard let brew = PortManager.brewPath else { return nil }
            return (brew, ["upgrade", "--cask", item.name])
        case .npm:
            guard let npm = locate("npm") else { return nil }
            return (npm, ["install", "-g", "\(item.name)@latest"])
        case .appStore:
            guard let mas = locate("mas"), item.name.allSatisfy(\.isNumber), !item.name.isEmpty else { return nil }
            return (mas, ["upgrade", item.name])
        }
    }

    // MARK: - Parsing

    /// `brew outdated --json=v2`:
    /// {"formulae":[{"name","installed_versions":[..],"current_version","pinned"}],
    ///  "casks":[{"name","installed_versions":[..] or "..","current_version"}]}
    static func parseBrew(_ json: String) -> [ExtraUpdate] {
        guard let data = jsonSlice(json, open: "{", close: "}"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        func versions(_ value: Any?) -> String {
            if let list = value as? [String] { return list.last ?? "?" }
            return (value as? String) ?? "?"
        }
        func items(_ key: String, _ source: ExtraSource) -> [ExtraUpdate] {
            (root[key] as? [[String: Any]] ?? []).compactMap { entry in
                guard let name = entry["name"] as? String, isValidName(name),
                      !skipped.contains(name),
                      (entry["pinned"] as? Bool) != true,
                      let latest = entry["current_version"] as? String else { return nil }
                return ExtraUpdate(source: source, name: name, title: name,
                                   current: versions(entry["installed_versions"]), latest: latest)
            }
        }
        return items("formulae", .brew) + items("casks", .brewCask)
    }

    /// `npm outdated -g --json`: {"pkg":{"current","wanted","latest","location"}}.
    /// npm exits with 1 when something is outdated, and may print warnings around the JSON.
    static func parseNpm(_ text: String, needsAdmin: Bool = false) -> [ExtraUpdate] {
        guard let data = jsonSlice(text, open: "{", close: "}"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return root.compactMap { name, value -> ExtraUpdate? in
            guard isValidName(name), !skipped.contains(name),
                  let info = value as? [String: Any],
                  let current = info["current"] as? String,
                  let latest = info["latest"] as? String,
                  current != latest else { return nil }
            return ExtraUpdate(source: .npm, name: name, title: name, current: current, latest: latest,
                               needsAdmin: needsAdmin)
        }
        .sorted { $0.name < $1.name }
    }

    /// `mas outdated` lines: "497799835 Xcode (14.0 -> 14.1)".
    static func parseMas(_ text: String) -> [ExtraUpdate] {
        let pattern = try? NSRegularExpression(pattern: #"^\s*(\d+)\s+(.+?)\s+\((.+?)\s*->\s*(.+?)\)\s*$"#)
        return text.split(separator: "\n").compactMap { line -> ExtraUpdate? in
            let s = String(line)
            guard let m = pattern?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  m.numberOfRanges == 5 else { return nil }
            func group(_ i: Int) -> String { Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
            return ExtraUpdate(source: .appStore, name: group(1), title: group(2),
                               current: group(3), latest: group(4))
        }
    }

    /// The part of the output from the first `open` to the last `close`.
    private static func jsonSlice(_ text: String, open: Character, close: Character) -> Data? {
        guard let start = text.firstIndex(of: open), let end = text.lastIndex(of: close), start < end else { return nil }
        return String(text[start...end]).data(using: .utf8)
    }
}
