import XCTest
@testable import PortCat

final class ParserTests: XCTestCase {
    func testCodexVersions() {
        XCTAssertEqual(Codex.parseVersion("codex-cli 0.151.0\n"), "0.151.0")
        XCTAssertEqual(Codex.parseVersion("rust-v0.152.0-alpha.1"), "0.152.0-alpha.1")
        XCTAssertNil(Codex.parseVersion("command not found"))
        XCTAssertTrue(Codex.isNewer("0.151.0", than: "0.150.9"))
        XCTAssertTrue(Codex.isNewer("1.0.0", than: "0.999.0"))
        XCTAssertFalse(Codex.isNewer("0.151.0", than: "0.151.0"))
        XCTAssertFalse(Codex.isNewer("0.151.0-alpha.1", than: "0.151.0"))
    }

    func testBrewOutdatedJSON() {
        let json = """
        {"formulae":[
          {"name":"wget","installed_versions":["1.24.5"],"current_version":"1.25.0","pinned":false},
          {"name":"pinned-thing","installed_versions":["1.0"],"current_version":"2.0","pinned":true},
          {"name":"codex","installed_versions":["0.1"],"current_version":"0.2","pinned":false}],
         "casks":[{"name":"visual-studio-code","installed_versions":"1.95.0","current_version":"1.96.0"}]}
        """
        let items = Extras.parseBrew(json)
        XCTAssertEqual(items.map(\.name), ["wget", "visual-studio-code"])
        XCTAssertEqual(items[0].current, "1.24.5")
        XCTAssertEqual(items[1].source, .brewCask)
        XCTAssertTrue(items[1].needsTerminal)
        XCTAssertEqual(Extras.parseBrew("Error: no JSON here"), [])
    }

    func testNpmOutdatedJSON() {
        let text = """
        npm warn something
        {"@anthropic-ai/claude-code":{"current":"2.0.1","wanted":"2.0.5","latest":"2.0.5"},
         "@openai/codex":{"current":"0.1.0","latest":"0.2.0"},
         "typescript":{"current":"5.6.0","latest":"5.7.2"}}
        """
        let items = Extras.parseNpm(text, needsAdmin: true)
        XCTAssertEqual(items.map(\.name), ["@anthropic-ai/claude-code", "typescript"])
        XCTAssertTrue(items.allSatisfy(\.needsTerminal))
        XCTAssertEqual(Extras.parseNpm(""), [])
    }

    func testMasOutdated() {
        let items = Extras.parseMas("497799835 Xcode (16.0 -> 16.1)\n  409183694 Keynote (14.1 -> 14.2)\ngarbage\n")
        XCTAssertEqual(items.map(\.name), ["497799835", "409183694"])
        XCTAssertEqual(items[0].title, "Xcode")
        XCTAssertEqual(items[1].latest, "14.2")
    }

    func testNameValidation() {
        XCTAssertTrue(Extras.isValidName("@scope/pkg"))
        XCTAssertTrue(Extras.isValidName("supabase/tap/supabase"))
        XCTAssertFalse(Extras.isValidName("--force"))
        XCTAssertFalse(Extras.isValidName("a b"))
        XCTAssertFalse(Extras.isValidName("x;rm"))
    }

    func testNvmPicksDefaultThenNewest() throws {
        let home = NSTemporaryDirectory() + "portcat-nvm-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        for version in ["v20.1.0", "v26.13.1", "v9.9.9"] {
            let bin = "\(home)/.nvm/versions/node/\(version)/bin"
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: bin + "/npm", contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
        }
        // No alias: the newest wins (26 is newer than 9, even though "v9" sorts after "v26" as text).
        XCTAssertEqual(Extras.nvmBin(home: home), home + "/.nvm/versions/node/v26.13.1/bin")
        XCTAssertEqual(Extras.locate("npm", home: home), home + "/.nvm/versions/node/v26.13.1/bin/npm")
        // An alias like "20" picks the matching installed version.
        try FileManager.default.createDirectory(atPath: home + "/.nvm/alias", withIntermediateDirectories: true)
        try "20\n".write(toFile: home + "/.nvm/alias/default", atomically: true, encoding: .utf8)
        XCTAssertEqual(Extras.nvmBin(home: home), home + "/.nvm/versions/node/v20.1.0/bin")
        // No nvm at all.
        XCTAssertNil(Extras.nvmBin(home: home + "/missing"))
    }
}
