import SwiftUI

struct SettingsView: View {
    @ObservedObject var monitor: NetworkMonitor
    @ObservedObject var loginItem: LoginItemManager
    @AppStorage("speedUnit") private var speedUnitRaw = SpeedUnit.bytes.rawValue
    @AppStorage("alwaysOnTop") private var alwaysOnTop = true
    @AppStorage("srunAutoReconnect") private var srunAutoReconnect = false
    @AppStorage("externalIPAutoRefresh") private var externalIPAutoRefresh = false

    var body: some View {
        Form {
            Section("显示") {
                Picker("速度单位", selection: $speedUnitRaw) {
                    ForEach(SpeedUnit.allCases) { unit in
                        Text(unit.title).tag(unit.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("详细窗口始终置顶", isOn: $alwaysOnTop)
                Text("界面使用系统语义色，会自动跟随 macOS 深色模式。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("启动") {
                Toggle(
                    "登录 Mac 时自动启动",
                    isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { loginItem.setEnabled($0) }
                    )
                )
                Text(loginItem.statusText).font(.caption).foregroundStyle(.secondary)
                if !loginItem.lastError.isEmpty {
                    Text(loginItem.lastError).font(.caption).foregroundStyle(.red)
                }
                if loginItem.statusText == "等待用户批准" {
                    Button("打开系统登录项设置") { loginItem.openSystemSettings() }
                }
            }

            Section("校园网自动重连") {
                Toggle("启用 SRun 有线网自动重连", isOn: $srunAutoReconnect)
                LabeledContent("状态", value: monitor.srun.status)
                Text("初版调用随应用打包的 Python helper。请先运行 helper 的 setup 保存账号；应用只在检测到活动以太网接口时调用一次性检查。不要同时运行旧的 Python watch/LaunchAgent。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("外部 IP") {
                LabeledContent("当前地址", value: monitor.publicIP)
                Toggle(
                    "自动查询外部 IP",
                    isOn: Binding(
                        get: { externalIPAutoRefresh },
                        set: {
                            externalIPAutoRefresh = $0
                            monitor.setExternalIPAutoRefresh($0)
                        }
                    )
                )
                Button("立即刷新") { monitor.refreshPublicIP() }
                Text("默认不发起查询。手动刷新或启用自动查询后会访问 api64.ipify.org，该服务会看到当前出口 IP。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }
}
