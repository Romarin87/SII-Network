import Foundation
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var statusText = "未启用"
    @Published private(set) var lastError = ""

    init() { refresh() }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            statusText = "已启用"
        case .requiresApproval:
            isEnabled = false
            statusText = "等待用户批准"
        case .notFound:
            isEnabled = false
            statusText = "应用尚未安装到标准位置"
        case .notRegistered:
            isEnabled = false
            statusText = "未启用"
        @unknown default:
            isEnabled = false
            statusText = "未知状态"
        }
    }

    func setEnabled(_ enabled: Bool) {
        lastError = ""
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
