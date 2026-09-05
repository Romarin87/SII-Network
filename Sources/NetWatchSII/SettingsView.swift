import SwiftUI

struct SettingsView: View {
    @ObservedObject var monitor: NetworkMonitor
    @ObservedObject var loginItem: LoginItemManager
    @AppStorage("speedUnit") private var speedUnitRaw = SpeedUnit.bytes.rawValue
    @AppStorage("themeMode") private var themeModeRaw = ThemeMode.system.rawValue
    @AppStorage("alwaysOnTop") private var alwaysOnTop = true
    @AppStorage("srunAutoReconnect") private var srunAutoReconnect = false
    @AppStorage("disableWiFiWhenWired") private var disableWiFiWhenWired = false
    @AppStorage("externalIPAutoRefresh") private var externalIPAutoRefresh = false
    @StateObject private var srunCredentials = SRunCredentialStore()
    @State private var srunUsername = ""
    @State private var srunPassword = ""

    var body: some View {
        Form {
            Section("显示") {
                Picker("速度单位", selection: $speedUnitRaw) {
                    ForEach(SpeedUnit.allCases) { unit in
                        Text(unit.title).tag(unit.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Picker("界面主题", selection: $themeModeRaw) {
                    ForEach(ThemeMode.allCases) { theme in
                        Text(theme.title).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("详细窗口始终置顶", isOn: $alwaysOnTop)
                Text("可固定使用浅色或深色主题，也可随 macOS 外观自动切换。")
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

            Section("网络切换") {
                Toggle(
                    "连接有线网时自动关闭 Wi-Fi",
                    isOn: Binding(
                        get: { disableWiFiWhenWired },
                        set: { enabled in
                            disableWiFiWhenWired = enabled
                            monitor.setWiFiAutomationEnabled(enabled)
                        }
                    )
                )
                LabeledContent("状态", value: monitor.wifiAutomation.status)
                if !monitor.wifiAutomation.lastError.isEmpty {
                    Text(monitor.wifiAutomation.lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("重试 Wi-Fi 切换") {
                        monitor.retryWiFiAutomation()
                    }
                }
                Text("有线网络稳定连接后关闭 Wi-Fi；网线拔出后，仅当 Wi-Fi 是由本程序关闭时才重新开启。首次切换时 macOS 可能要求管理员授权。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("校园网自动重连") {
                Toggle("启用 SRun 有线网自动重连", isOn: $srunAutoReconnect)
                LabeledContent("状态", value: monitor.srun.status)

                TextField("校园网账号", text: $srunUsername)
                    .textContentType(.username)
                SecureField("校园网密码", text: $srunPassword)
                    .textContentType(.password)
                HStack {
                    Button("保存凭据") {
                        if srunCredentials.save(username: srunUsername, password: srunPassword) {
                            srunUsername = srunCredentials.configuredUsername
                            srunPassword = ""
                        }
                    }
                    .disabled(
                        srunUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || srunPassword.isEmpty
                    )
                    Spacer()
                    LabeledContent("配置", value: srunCredentials.statusText)
                }

                if !srunCredentials.feedbackText.isEmpty {
                    Text(srunCredentials.feedbackText)
                        .font(.caption)
                        .foregroundStyle(srunCredentials.feedbackIsError ? .red : .green)
                }

                Text("密码只保存在 macOS 钥匙串；账号和固定的官方认证参数保存在当前用户的应用支持目录。应用仅在检测到活动以太网接口时执行认证检查。")
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
        .onAppear {
            srunCredentials.refresh()
            if srunUsername.isEmpty {
                srunUsername = srunCredentials.configuredUsername
            }
        }
    }
}
