import CoreWLAN
import Foundation

protocol WiFiPowerControlling {
    func readPower() async throws -> Bool
    // Returns only after the requested radio power has been independently verified.
    func setPower(_ enabled: Bool) async throws
    func restoreBeforeTermination() throws
}

enum WiFiPowerError: LocalizedError {
    case interfaceUnavailable
    case unreadableState
    case stateMismatch
    case timedOut

    var errorDescription: String? {
        switch self {
        case .interfaceUnavailable: return "暂时无法找到 Wi-Fi 接口。"
        case .unreadableState: return "无法确认 Wi-Fi 电源状态。"
        case .stateMismatch: return "Wi-Fi 电源尚未切换到目标状态。"
        case .timedOut: return "读取 Wi-Fi 电源状态超时。"
        }
    }
}

final class SystemWiFiPowerController: WiFiPowerControlling {
    private let queue = DispatchQueue(label: "NetWatchSII.wifi-power", qos: .utility)

    func readPower() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try Self.readPowerSync() })
            }
        }
    }

    func setPower(_ enabled: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                continuation.resume(with: Result { try Self.setPowerSync(enabled) })
            }
        }
    }

    func restoreBeforeTermination() throws {
        try queue.sync { try Self.setPowerSync(true) }
    }

    private static func setPowerSync(_ enabled: Bool) throws {
        guard let interface = CWWiFiClient.shared().interface(),
              let device = interface.interfaceName else {
            throw WiFiPowerError.interfaceUnavailable
        }
        var requestError: Error?
        do {
            try interface.setPower(enabled)
        } catch {
            requestError = error
        }
        // The request can return before the radio changes. Verify power, not SSID
        // association; give the system a bounded time to complete the transition.
        for attempt in 0..<4 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            if let actual = try? readPowerSync(device: device), actual == enabled { return }
        }
        if let requestError { throw requestError }
        throw WiFiPowerError.stateMismatch
    }

    private static func readPowerSync(device suppliedDevice: String? = nil) throws -> Bool {
        guard let device = suppliedDevice ?? CWWiFiClient.shared().interface()?.interfaceName else {
            throw WiFiPowerError.interfaceUnavailable
        }
        // CoreWLAN.powerOn() also returns false on query errors. The command's
        // explicit On/Off response lets us distinguish unknown from confirmed off.
        let process = Process()
        let pipe = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-getairportpower", device]
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 3) == .success else {
            process.terminate()
            throw WiFiPowerError.timedOut
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { throw WiFiPowerError.unreadableState }
        return try parsePowerOutput(String(decoding: data, as: UTF8.self), device: device)
    }

    static func parsePowerOutput(_ output: String, device: String) throws -> Bool {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Wi-Fi Power (\(device)): On": return true
        case "Wi-Fi Power (\(device)): Off": return false
        default: throw WiFiPowerError.unreadableState
        }
    }
}
