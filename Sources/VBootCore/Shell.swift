import Foundation

public struct ShellResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public var ok: Bool { exitCode == 0 }
}

public enum Shell {
    @discardableResult
    public static func run(_ launchPath: String, _ args: [String], env: [String: String]? = nil) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        if let env { process.environment = env }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ShellResult(exitCode: -1, stdout: "", stderr: "Failed to launch (\(launchPath)): \(error)")
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    public static func which(_ tool: String) -> String? {
        let r = run("/usr/bin/which", [tool])
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.ok && !path.isEmpty) ? path : nil
    }
}
