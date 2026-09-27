import Foundation

struct CommandResult: Sendable {
    let status: Int32
    let output: String

    var succeeded: Bool { status == 0 }
    /// osascript reports -128 when the user presses Cancel in the password dialog.
    var userCancelled: Bool { status != 0 && output.contains("-128") }
}

enum Shell {
    static let searchPath = "/opt/local/bin:/opt/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Runs a program without a shell (no quoting issues) off the main thread.
    static func run(_ executable: String, _ arguments: [String],
                    extraEnv: [String: String] = [:]) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = searchPath
                env.merge(extraEnv) { _, new in new }
                process.environment = env

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: CommandResult(status: -1, output: "\(error)"))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    output: String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Runs a shell command as root. macOS shows its standard password dialog
    /// every time (it may reuse the password for a few minutes).
    /// Only pass commands built from fixed strings and validated port names.
    static func runAsAdmin(_ command: String) async -> CommandResult {
        let escaped = "\(command) 2>&1"
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        do shell script "\(escaped)" with prompt "PortCat needs your password to run MacPorts." with administrator privileges
        """
        return await run("/usr/bin/osascript", ["-e", script])
    }
}
