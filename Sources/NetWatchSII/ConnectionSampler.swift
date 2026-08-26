import Foundation

enum ConnectionSampler {
    static func sample() -> [ConnectionRecord] {
        guard let output = try? CommandRunner.run(
            "/usr/sbin/lsof",
            ["-nP", "-iTCP", "-iUDP", "-FpcfPnT"]
        ) else { return [] }

        var process = ""
        var pid: Int?
        var descriptor = ""
        var proto = ""
        var endpoint = ""
        var state = ""
        var records: [ConnectionRecord] = []

        func appendCurrent() {
            guard !endpoint.isEmpty else { return }
            let halves = endpoint.components(separatedBy: "->")
            records.append(
                ConnectionRecord(
                    process: process,
                    pid: pid,
                    descriptor: descriptor,
                    proto: proto,
                    localEndpoint: halves.first ?? endpoint,
                    remoteEndpoint: halves.count > 1 ? halves[1] : "—",
                    state: state
                )
            )
        }

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())
            switch marker {
            case "p":
                appendCurrent()
                endpoint = ""
                state = ""
                pid = Int(value)
            case "c": process = value
            case "f":
                appendCurrent()
                descriptor = value
                endpoint = ""
                state = ""
            case "P": proto = value
            case "n": endpoint = value
            case "T":
                if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default: break
            }
        }
        appendCurrent()
        return records
    }
}
