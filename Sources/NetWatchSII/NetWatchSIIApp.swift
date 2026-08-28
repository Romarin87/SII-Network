import SwiftUI

@main
struct NetWatchSIIApp: App {
    @StateObject private var monitor = NetworkMonitor()
    @StateObject private var loginItem = LoginItemManager()
    @State private var detailsWindowVisible = false
    @AppStorage("alwaysOnTop") private var alwaysOnTop = true
    @AppStorage("themeMode") private var themeModeRaw = ThemeMode.system.rawValue

    private var themeMode: ThemeMode {
        ThemeMode(rawValue: themeModeRaw) ?? .system
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(monitor: monitor)
                .preferredColorScheme(themeMode.preferredColorScheme)
        } label: {
            MenuBarSpeedLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Window("网络详情", id: "details") {
            DashboardView(
                monitor: monitor,
                loginItem: loginItem,
                isWindowVisible: detailsWindowVisible
            )
                .preferredColorScheme(themeMode.preferredColorScheme)
                .background(
                    FloatingWindowAccessor(alwaysOnTop: alwaysOnTop) { isVisible in
                        if detailsWindowVisible != isVisible {
                            detailsWindowVisible = isVisible
                        }
                    }
                )
        }
        .defaultSize(width: 840, height: 620)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(monitor: monitor, loginItem: loginItem)
                .frame(width: 520, height: 460)
                .preferredColorScheme(themeMode.preferredColorScheme)
        }
    }
}
