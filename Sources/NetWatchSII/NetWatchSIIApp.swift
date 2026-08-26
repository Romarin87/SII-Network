import SwiftUI

@main
struct NetWatchSIIApp: App {
    @StateObject private var monitor = NetworkMonitor()
    @StateObject private var loginItem = LoginItemManager()
    @AppStorage("alwaysOnTop") private var alwaysOnTop = true

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(monitor: monitor)
        } label: {
            MenuBarSpeedLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Window("网络详情", id: "details") {
            DashboardView(monitor: monitor, loginItem: loginItem)
                .background(FloatingWindowAccessor(alwaysOnTop: alwaysOnTop))
        }
        .defaultSize(width: 840, height: 620)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(monitor: monitor, loginItem: loginItem)
                .frame(width: 520, height: 460)
        }
    }
}
