import Foundation

final class ProcessNetworkSampler {
    private struct Totals {
        let received: UInt64
        let sent: UInt64
    }

    private var previous: [String: Totals] = [:]
    private var previousDate = Date()

    func sample() -> [ProcessNetworkRate] {
        guard let output = try? CommandRunner.run(
            "/usr/bin/nettop",
            ["-P", "-t", "external", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"]
        ) else { return [] }

        let rows = output.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerIndex = rows.firstIndex(where: { $0.contains("bytes_in") && $0.contains("bytes_out") }) else {
            return []
        }
        let headers = rows[headerIndex].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let receivedIndex = headers.firstIndex(of: "bytes_in"),
              let sentIndex = headers.firstIndex(of: "bytes_out") else { return [] }

        let now = Date()
        let elapsed = max(0.1, now.timeIntervalSince(previousDate))
        var current: [String: Totals] = [:]
        var rates: [ProcessNetworkRate] = []

        for row in rows.dropFirst(headerIndex + 1) {
            let fields = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count > max(receivedIndex, sentIndex),
                  !fields[0].isEmpty,
                  let received = UInt64(fields[receivedIndex]),
                  let sent = UInt64(fields[sentIndex]) else { continue }

            let key = fields[0]
            current[key] = Totals(received: received, sent: sent)
            let old = previous[key]
            let receivedDelta = old.map { received >= $0.received ? received - $0.received : 0 } ?? 0
            let sentDelta = old.map { sent >= $0.sent ? sent - $0.sent : 0 } ?? 0

            let split = key.lastIndex(of: ".")
            let pid = split.flatMap { Int(key[key.index(after: $0)...]) }
            let name = split.map { String(key[..<$0]) } ?? key
            rates.append(
                ProcessNetworkRate(
                    id: key,
                    name: name,
                    pid: pid,
                    downloadBytesPerSecond: Double(receivedDelta) / elapsed,
                    uploadBytesPerSecond: Double(sentDelta) / elapsed,
                    totalReceivedBytes: received,
                    totalSentBytes: sent
                )
            )
        }

        previous = current
        previousDate = now
        return rates.sorted {
            ($0.downloadBytesPerSecond + $0.uploadBytesPerSecond)
                > ($1.downloadBytesPerSecond + $1.uploadBytesPerSecond)
        }
    }
}
