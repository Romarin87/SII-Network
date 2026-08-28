import AppKit
import SwiftUI

struct MenuBarSpeedLabel: View {
    @ObservedObject var monitor: NetworkMonitor
    @AppStorage("speedUnit") private var speedUnitRaw = SpeedUnit.bytes.rawValue

    private var unit: SpeedUnit { SpeedUnit(rawValue: speedUnitRaw) ?? .bytes }

    var body: some View {
        Text("↓\(unit.format(monitor.downloadBytesPerSecond, compact: true))  ↑\(unit.format(monitor.uploadBytesPerSecond, compact: true))")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .monospacedDigit()
    }
}

struct MenuBarPanel: View {
    @ObservedObject var monitor: NetworkMonitor
    @Environment(\.openWindow) private var openWindow
    @AppStorage("speedUnit") private var speedUnitRaw = SpeedUnit.bytes.rawValue

    private var unit: SpeedUnit { SpeedUnit(rawValue: speedUnitRaw) ?? .bytes }
    private var activeInterfaces: [InterfaceRate] {
        monitor.interfaces.filter(\.isActive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                speedBlock(title: "下载", image: "arrow.down", value: monitor.downloadBytesPerSecond, color: .blue)
                speedBlock(title: "上传", image: "arrow.up", value: monitor.uploadBytesPerSecond, color: .orange)
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                ForEach(activeInterfaces) { item in
                    HStack {
                        Image(systemName: item.kind.systemImage)
                            .foregroundStyle(.green)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.displayName).lineLimit(1)
                            Text(item.name).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("已连接")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if activeInterfaces.isEmpty {
                    Text("没有活动的以太网或 Wi-Fi 适配器")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Label("外部 IP", systemImage: "globe")
                Spacer()
                Text(monitor.publicIP).textSelection(.enabled).monospacedDigit()
                Button { monitor.refreshPublicIP() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新外部 IP")
            }

            HStack(alignment: .top) {
                Label("校园网", systemImage: "network")
                Spacer()
                Text(monitor.srun.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 210, alignment: .trailing)
            }

            Divider()

            HStack {
                Button("打开详细窗口") {
                    openWindow(id: "details")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func speedBlock(title: String, image: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: image).foregroundStyle(color)
            Text(unit.format(value))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
