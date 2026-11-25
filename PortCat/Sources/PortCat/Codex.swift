import Foundation

/// What PortCat knows about the Codex CLI on this Mac.
struct CodexStatus: Equatable {
    let path: String
    let current: String
    let latest: String?
    /// Installed by the official installer (~/.local/bin/codex), so it can be
    /// updated in the background with no questions asked.
    let standalone: Bool

    var updateAvailable: Bool {
        guard let latest else { return false }
        return Codex.isNewer(latest, than: current)
    }
}

/// Codex updates through its own installer, not MacPorts or Homebrew.
/// Updating a Homebrew copy on Intel Macs can fail, so PortCat always uses
/// the official script.
enum Codex {
    static let installCommand = "curl -fsSL https://chatgpt.com/codex/install.sh | sh"

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    static var standalonePath: String { home + "/.local/bin/codex" }

    /// The official installer's copy wins; otherwise any Homebrew/MacPorts/npm copy.
    static func locate() -> String? {
        [standalonePath, "/usr/local/bin/codex", "/opt/local/bin/codex", "/opt/homebrew/bin/codex"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// "codex-cli 0.151.0" → "0.151.0", "rust-v0.151.0" → "0.151.0".
    static func parseVersion(_ text: String) -> String? {
        guard let range = text.range(of: "[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.]+)?",
                                     options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// Compares the numeric x.y.z part; pre-release suffixes are ignored.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let core = v.split(separator: "-", maxSplits: 1).first.map(String.init) ?? v
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0
            let q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Asks the same places the official installer uses: OpenAI's release
    /// channel first, then GitHub Releases. Tags look like "rust-v0.151.0".
    static func latestVersion() async -> String? {
        let sources = ["https://releases.openai.com/codex/channels/latest",
                       "https://api.github.com/repos/openai/codex/releases/latest"]
        for source in sources {
            guard let url = URL(string: source) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("PortCat", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String, tag.hasPrefix("rust-v"),
                  let version = parseVersion(tag) else { continue }
            return version
        }
        return nil
    }
}
