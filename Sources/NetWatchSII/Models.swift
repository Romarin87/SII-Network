import Foundation

enum SpeedUnit: String, CaseIterable, Identifiable {
    case bytes
    case bits

    var id: String { rawValue }
    var title: String { self == .bytes ? "字节/秒" : "比特/秒" }

    func format(_ bytesPerSecond: Double, compact: Bool = false) -> String {
        formatValue(bytesPerSecond, isRate: true, compact: compact)
    }

    func formatTotal(_ bytes: UInt64, compact: Bool = false) -> String {
        formatValue(Double(bytes), isRate: false, compact: compact)
    }

    private func formatValue(_ bytes: Double, isRate: Bool, compact: Bool) -> String {
        let clamped = max(0, bytes)
        let value = self == .bits ? clamped * 8 : clamped
        let base = self == .bits ? 1_000.0 : 1_024.0
        let units: [String]
        if self == .bits {
            units = isRate
                ? ["bit/s", "Kbit/s", "Mbit/s", "Gbit/s", "Tbit/s"]
                : ["bit", "Kbit", "Mbit", "Gbit", "Tbit"]
        } else {
            units = isRate
                ? ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
                : ["B", "KB", "MB", "GB", "TB"]
        }

        var scaled = value
        var index = 0
        while scaled >= base, index < units.count - 1 {
            scaled /= base
            index += 1
        }
        let decimals = scaled >= 100 ? 0 : (scaled >= 10 ? 1 : 2)
        let formatted = String(format: "%.*f", decimals, scaled)
        return compact ? "\(formatted) \(units[index])" : "\(formatted) \(units[index])"
    }
}

enum AdapterKind: String, Codable {
    case ethernet
    case wifi

    var title: String { self == .ethernet ? "以太网" : "Wi-Fi" }
    var systemImage: String { self == .ethernet ? "cable.connector" : "wifi" }
}

struct InterfaceRate: Identifiable, Equatable {
    let name: String
    let displayName: String
    let kind: AdapterKind
    let isActive: Bool
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let totalReceivedBytes: UInt64
    let totalSentBytes: UInt64

    var id: String { name }
}

struct ThroughputPoint: Identifiable {
    let id = UUID()
    let date: Date
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
}

struct ProcessNetworkRate: Identifiable {
    let id: String
    let name: String
    let pid: Int?
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let totalReceivedBytes: UInt64
    let totalSentBytes: UInt64

    var pidSortValue: Int { pid ?? -1 }
}

struct ConnectionRecord: Identifiable {
    let process: String
    let pid: Int?
    let descriptor: String
    let proto: String
    let localEndpoint: String
    let remoteEndpoint: String
    let state: String

    var id: String {
        "\(pid ?? -1)|\(descriptor)|\(proto)|\(localEndpoint)|\(remoteEndpoint)"
    }
}

struct PublicIPResponse: Decodable {
    let ip: String
}
