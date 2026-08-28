import Charts
import SwiftUI

struct DashboardView: View {
    private enum Tab: Hashable {
        case overview
        case processes
        case connections
        case settings
    }

    let monitor: NetworkMonitor
    let loginItem: LoginItemManager
    let isWindowVisible: Bool
    @State private var selectedTab: Tab = .overview

    var body: some View {
        Group {
            if isWindowVisible {
                detailTabs
            } else {
                Color.clear
            }
        }
        .padding(12)
        .frame(minWidth: 680, minHeight: 480)
        .onAppear {
            updateDetailSampling()
        }
        .onChange(of: selectedTab) { _ in
            updateDetailSampling()
        }
        .onChange(of: isWindowVisible) { _ in
            updateDetailSampling()
        }
        .onDisappear {
            monitor.setDetailSampling(processes: false, connections: false)
        }
    }

    private var detailTabs: some View {
        TabView(selection: $selectedTab) {
            OverviewView(monitor: monitor)
                .tabItem { Label("概览", systemImage: "chart.xyaxis.line") }
                .tag(Tab.overview)
            ProcessesView(monitor: monitor)
                .tabItem { Label("活动进程", systemImage: "square.stack.3d.up") }
                .tag(Tab.processes)
            ConnectionsView(monitor: monitor)
                .tabItem { Label("连接", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(Tab.connections)
            SettingsView(monitor: monitor, loginItem: loginItem)
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
    }

    private func updateDetailSampling() {
        guard isWindowVisible else {
            monitor.setDetailSampling(processes: false, connections: false)
            return
        }
        monitor.setDetailSampling(
            processes: selectedTab == .processes,
            connections: selectedTab == .connections
        )
    }
}

private struct OverviewView: View {
    @ObservedObject var monitor: NetworkMonitor
    @AppStorage("speedUnit") private var speedUnitRaw = SpeedUnit.bytes.rawValue
    private var unit: SpeedUnit { SpeedUnit(rawValue: speedUnitRaw) ?? .bytes }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                metric("下载", "arrow.down", monitor.downloadBytesPerSecond, .blue)
                metric("上传", "arrow.up", monitor.uploadBytesPerSecond, .orange)
                VStack(alignment: .leading, spacing: 5) {
                    Label("外部 IP", systemImage: "globe")
                    Text(monitor.publicIP).font(.title3.weight(.semibold)).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("最近两分钟") {
                Chart(monitor.history) { point in
                    LineMark(
                        x: .value("时间", point.date),
                        y: .value("下载", unit == .bits ? point.downloadBytesPerSecond * 8 : point.downloadBytesPerSecond)
                    )
                    .foregroundStyle(by: .value("方向", "下载"))
                    LineMark(
                        x: .value("时间", point.date),
                        y: .value("上传", unit == .bits ? point.uploadBytesPerSecond * 8 : point.uploadBytesPerSecond)
                    )
                    .foregroundStyle(by: .value("方向", "上传"))
                }
                .chartForegroundStyleScale(["下载": Color.blue, "上传": Color.orange])
                .frame(minHeight: 210)
                .padding(8)
            }

            GroupBox("网络适配器") {
                VStack(spacing: 0) {
                    ForEach(monitor.interfaces) { item in
                        HStack {
                            Label(item.displayName, systemImage: item.kind.systemImage)
                            Text(item.name).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("↓ \(unit.format(item.downloadBytesPerSecond))")
                                .monospacedDigit().foregroundStyle(.blue)
                            Text("↑ \(unit.format(item.uploadBytesPerSecond))")
                                .monospacedDigit().foregroundStyle(.orange)
                            Circle().fill(item.isActive ? .green : .gray).frame(width: 8, height: 8)
                        }
                        .padding(.vertical, 7)
                        if item.id != monitor.interfaces.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(8)
    }

    private func metric(_ title: String, _ image: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: image).foregroundStyle(color)
            Text(unit.format(value)).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProcessesView: View {
    @ObservedObject var monitor: NetworkMonitor
    @AppStorage("speedUnit") private var speedUnitRaw = SpeedUnit.bytes.rawValue
    @AppStorage("showProcessTotalDownload") private var showTotalDownload = true
    @AppStorage("showProcessTotalUpload") private var showTotalUpload = true
    @State private var sortOrder = [
        KeyPathComparator(\ProcessNetworkRate.downloadBytesPerSecond, order: .reverse)
    ]

    private var unit: SpeedUnit { SpeedUnit(rawValue: speedUnitRaw) ?? .bytes }
    private var sortedProcesses: [ProcessNetworkRate] {
        monitor.processes.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("点击列标题排序。普通用户权限可能看不到部分系统进程。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("累计下载", isOn: $showTotalDownload)
                    .toggleStyle(.checkbox)
                    .onChange(of: showTotalDownload) { isShown in
                        if !isShown {
                            resetSortIfUsing(\ProcessNetworkRate.totalReceivedBytes)
                        }
                    }
                Toggle("累计上传", isOn: $showTotalUpload)
                    .toggleStyle(.checkbox)
                    .onChange(of: showTotalUpload) { isShown in
                        if !isShown {
                            resetSortIfUsing(\ProcessNetworkRate.totalSentBytes)
                        }
                    }
            }
            processTable
        }
        .padding(8)
    }

    private func resetSortIfUsing(_ keyPath: PartialKeyPath<ProcessNetworkRate>) {
        guard sortOrder.contains(where: { $0.keyPath == keyPath }) else { return }
        sortOrder = [
            KeyPathComparator(\ProcessNetworkRate.downloadBytesPerSecond, order: .reverse)
        ]
    }

    @ViewBuilder
    private var processTable: some View {
        if showTotalDownload && showTotalUpload {
            Table(sortedProcesses, sortOrder: $sortOrder) {
                TableColumn("应用", value: \.name) { row in Text(row.name) }
                TableColumn("PID", value: \.pidSortValue) { row in
                    Text(row.pid.map(String.init) ?? "—").monospacedDigit()
                }
                .width(70)
                TableColumn("下载", value: \.downloadBytesPerSecond) { row in
                    Text(unit.format(row.downloadBytesPerSecond)).monospacedDigit()
                }
                .width(120)
                TableColumn("上传", value: \.uploadBytesPerSecond) { row in
                    Text(unit.format(row.uploadBytesPerSecond)).monospacedDigit()
                }
                .width(120)
                TableColumn("累计下载", value: \.totalReceivedBytes) { row in
                    Text(unit.formatTotal(row.totalReceivedBytes)).monospacedDigit()
                }
                .width(110)
                TableColumn("累计上传", value: \.totalSentBytes) { row in
                    Text(unit.formatTotal(row.totalSentBytes)).monospacedDigit()
                }
                .width(110)
            }
        } else if showTotalDownload {
            Table(sortedProcesses, sortOrder: $sortOrder) {
                TableColumn("应用", value: \.name) { row in Text(row.name) }
                TableColumn("PID", value: \.pidSortValue) { row in
                    Text(row.pid.map(String.init) ?? "—").monospacedDigit()
                }
                .width(70)
                TableColumn("下载", value: \.downloadBytesPerSecond) { row in
                    Text(unit.format(row.downloadBytesPerSecond)).monospacedDigit()
                }
                .width(120)
                TableColumn("上传", value: \.uploadBytesPerSecond) { row in
                    Text(unit.format(row.uploadBytesPerSecond)).monospacedDigit()
                }
                .width(120)
                TableColumn("累计下载", value: \.totalReceivedBytes) { row in
                    Text(unit.formatTotal(row.totalReceivedBytes)).monospacedDigit()
                }
                .width(110)
            }
        } else if showTotalUpload {
            Table(sortedProcesses, sortOrder: $sortOrder) {
                TableColumn("应用", value: \.name) { row in Text(row.name) }
                TableColumn("PID", value: \.pidSortValue) { row in
                    Text(row.pid.map(String.init) ?? "—").monospacedDigit()
                }
                .width(70)
                TableColumn("下载", value: \.downloadBytesPerSecond) { row in
                    Text(unit.format(row.downloadBytesPerSecond)).monospacedDigit()
                }
                .width(120)
                TableColumn("上传", value: \.uploadBytesPerSecond) { row in
                    Text(unit.format(row.uploadBytesPerSecond)).monospacedDigit()
                }
                .width(120)
                TableColumn("累计上传", value: \.totalSentBytes) { row in
                    Text(unit.formatTotal(row.totalSentBytes)).monospacedDigit()
                }
                .width(110)
            }
        } else {
            Table(sortedProcesses, sortOrder: $sortOrder) {
                TableColumn("应用", value: \.name) { row in Text(row.name) }
                TableColumn("PID", value: \.pidSortValue) { row in
                    Text(row.pid.map(String.init) ?? "—").monospacedDigit()
                }
                .width(70)
                TableColumn("下载", value: \.downloadBytesPerSecond) { row in
                    Text(unit.format(row.downloadBytesPerSecond)).monospacedDigit()
                }
                .width(120)
                TableColumn("上传", value: \.uploadBytesPerSecond) { row in
                    Text(unit.format(row.uploadBytesPerSecond)).monospacedDigit()
                }
                .width(120)
            }
        }
    }
}

private struct ConnectionsView: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("显示当前用户有权限查看的 TCP/UDP socket；不进行 DNS 反查。")
                .font(.caption).foregroundStyle(.secondary)
            Table(monitor.connections) {
                TableColumn("进程") { row in Text(row.process) }
                TableColumn("PID") { row in Text(row.pid.map(String.init) ?? "—").monospacedDigit() }
                    .width(65)
                TableColumn("协议") { row in Text(row.proto) }.width(60)
                TableColumn("本地端点") { row in Text(row.localEndpoint).textSelection(.enabled) }
                TableColumn("远端端点") { row in Text(row.remoteEndpoint).textSelection(.enabled) }
                TableColumn("状态") { row in Text(row.state.isEmpty ? "—" : row.state) }.width(100)
            }
        }
        .padding(8)
    }
}
