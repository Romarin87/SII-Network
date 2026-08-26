import Foundation

enum CommandRunnerError: LocalizedError {
    case failed(String, Int32)

    var errorDescription: String? {
        switch self {
        case let .failed(message, code):
            return message.isEmpty ? "命令执行失败（\(code)）" : message
        }
    }
}

enum CommandRunner {
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CommandRunnerError.failed(output.trimmingCharacters(in: .whitespacesAndNewlines), process.terminationStatus)
        }
        return output
    }
}
