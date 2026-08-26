import Darwin
import Foundation

private struct AdapterDescriptor {
    let name: String
    let displayName: String
    let kind: AdapterKind
}

private struct InterfaceCounter {
    let received: UInt64
    let sent: UInt64
    let active: Bool
}

final class InterfaceSampler {
    private var previous: [String: InterfaceCounter] = [:]
    private var previousDate = Date()
    private var adapters: [String: AdapterDescriptor] = [:]
    private var lastCatalogRefresh = Date.distantPast

    func sample() -> [InterfaceRate] {
        let now = Date()
        if now.timeIntervalSince(lastCatalogRefresh) > 30 || adapters.isEmpty {
            refreshAdapterCatalog()
            lastCatalogRefresh = now
        }

        let current = readCounters()
        let elapsed = max(0.1, now.timeIntervalSince(previousDate))
        var result: [InterfaceRate] = []

        for (name, descriptor) in adapters {
            guard let counter = current[name] else { continue }
            let old = previous[name]
            let receivedDelta = old.map { counter.received >= $0.received ? counter.received - $0.received : 0 } ?? 0
            let sentDelta = old.map { counter.sent >= $0.sent ? counter.sent - $0.sent : 0 } ?? 0
            result.append(
                InterfaceRate(
                    name: name,
                    displayName: descriptor.displayName,
                    kind: descriptor.kind,
                    isActive: counter.active,
                    downloadBytesPerSecond: Double(receivedDelta) / elapsed,
                    uploadBytesPerSecond: Double(sentDelta) / elapsed,
                    totalReceivedBytes: counter.received,
                    totalSentBytes: counter.sent
                )
            )
        }

        previous = current
        previousDate = now
        return result.sorted {
            if $0.isActive != $1.isActive { return $0.isActive && !$1.isActive }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func refreshAdapterCatalog() {
        guard let output = try? CommandRunner.run("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return }
        var currentPort = ""
        var found: [String: AdapterDescriptor] = [:]

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                currentPort = String(line.dropFirst("Hardware Port:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("Device:"), !currentPort.isEmpty else { continue }
            let device = String(line.dropFirst("Device:".count)).trimmingCharacters(in: .whitespaces)
            let normalized = currentPort.lowercased()
            let kind: AdapterKind?
            if normalized.contains("wi-fi") || normalized.contains("airport") {
                kind = .wifi
            } else if normalized.contains("ethernet") || normalized.contains("lan") || normalized.contains("gigabit") {
                kind = .ethernet
            } else {
                kind = nil
            }
            if let kind, !device.isEmpty {
                found[device] = AdapterDescriptor(name: device, displayName: currentPort, kind: kind)
            }
        }
        if !found.isEmpty { adapters = found }
    }

    private func readCounters() -> [String: InterfaceCounter] {
        let interfacesWithIPv4 = ipv4InterfaceNames()
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var byteCount = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &byteCount, nil, 0) == 0,
              byteCount > 0 else { return [:] }

        var buffer = Data(count: byteCount)
        let readResult = buffer.withUnsafeMutableBytes { bytes in
            sysctl(&mib, UInt32(mib.count), bytes.baseAddress, &byteCount, nil, 0)
        }
        guard readResult == 0 else { return [:] }

        var output: [String: InterfaceCounter] = [:]
        buffer.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= byteCount {
                let generic = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr.self).pointee
                let messageLength = Int(generic.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= byteCount else { break }

                if Int32(generic.ifm_type) == RTM_IFINFO2,
                   messageLength >= MemoryLayout<if_msghdr2>.size {
                    let info = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr2.self).pointee
                    var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    let name: String? = nameBuffer.withUnsafeMutableBufferPointer { pointer in
                        guard let address = if_indextoname(UInt32(info.ifm_index), pointer.baseAddress) else {
                            return nil
                        }
                        return String(cString: address)
                    }
                    if let name {
                        let flags = Int32(info.ifm_flags)
                        output[name] = InterfaceCounter(
                            received: UInt64(info.ifm_data.ifi_ibytes),
                            sent: UInt64(info.ifm_data.ifi_obytes),
                            active: (flags & IFF_UP) != 0
                                && (flags & IFF_RUNNING) != 0
                                && interfacesWithIPv4.contains(name)
                        )
                    }
                }
                offset += messageLength
            }
        }
        return output
    }

    private func ipv4InterfaceNames() -> Set<String> {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return [] }
        defer { freeifaddrs(first) }

        var names = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = start
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_INET else { continue }
            names.insert(String(cString: item.pointee.ifa_name))
        }
        return names
    }
}
