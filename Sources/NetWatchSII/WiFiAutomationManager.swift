import AppKit
import Combine
import CoreWLAN
import Foundation

enum WiFiAutomationAction: Equatable {
    case none
    case turnPowerOn
    case turnPowerOff
}

enum WiFiAutomationPolicy {
    static func action(
        isEnabled: Bool,
        wiredIsActive: Bool,
        wifiIsPowered: Bool?,
        wifiWasDisabledByApp: Bool
    ) -> WiFiAutomationAction {
        if !isEnabled {
            return wifiWasDisabledByApp ? .turnPowerOn : .none
        }
        if wiredIsActive {
            return wifiIsPowered == true ? .turnPowerOff : .none
        }
        return wifiWasDisabledByApp ? .turnPowerOn : .none
    }
}

@MainActor
final class WiFiAutomationManager: NSObject, ObservableObject {
    @Published private(set) var status = "未启用"
    @Published private(set) var lastError = ""

    private struct ReconciliationKey: Equatable {
        let isEnabled: Bool
        let wiredIsActive: Bool
        let wifiWasDisabledByApp: Bool
    }

    private static let ownershipKey = "wifiDisabledByEthernetAutomation"
    private static let requiredStableSamples = 2

    private let defaults = UserDefaults.standard
    private var lastObservedWiredState: Bool?
    private var stableSampleCount = 0
    private var lastReconciliation: ReconciliationKey?
    private var lastEnabledState: Bool?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    func tick(isEnabled: Bool, hasActiveWiredInterface wiredIsActive: Bool) {
        if lastEnabledState != isEnabled {
            lastEnabledState = isEnabled
            lastReconciliation = nil
        }

        if !isEnabled, wifiWasDisabledByApp {
            reconcile(isEnabled: false, wiredIsActive: wiredIsActive)
            return
        }

        if lastObservedWiredState == wiredIsActive {
            stableSampleCount += 1
        } else {
            lastObservedWiredState = wiredIsActive
            stableSampleCount = 1
        }

        guard stableSampleCount >= Self.requiredStableSamples else {
            if isEnabled {
                setStatus("正在确认网络状态…")
            } else {
                setStatus("未启用")
            }
            return
        }

        reconcile(isEnabled: isEnabled, wiredIsActive: wiredIsActive)
    }

    func applyPreference(isEnabled: Bool, hasActiveWiredInterface wiredIsActive: Bool) {
        lastEnabledState = isEnabled
        lastObservedWiredState = wiredIsActive
        stableSampleCount = Self.requiredStableSamples
        lastReconciliation = nil
        reconcile(isEnabled: isEnabled, wiredIsActive: wiredIsActive)
    }

    func retry(isEnabled: Bool, hasActiveWiredInterface wiredIsActive: Bool) {
        lastReconciliation = nil
        reconcile(isEnabled: isEnabled, wiredIsActive: wiredIsActive)
    }

    func restoreBeforeTermination() {
        guard wifiWasDisabledByApp,
              let interface = CWWiFiClient.shared().interface() else { return }
        do {
            try interface.setPower(true)
            wifiWasDisabledByApp = false
        } catch {
            // Termination cannot be delayed safely here. Keep the ownership marker
            // so the next launch can retry restoring Wi-Fi.
        }
    }

    private var wifiWasDisabledByApp: Bool {
        get { defaults.bool(forKey: Self.ownershipKey) }
        set { defaults.set(newValue, forKey: Self.ownershipKey) }
    }

    private func reconcile(isEnabled: Bool, wiredIsActive: Bool) {
        let key = ReconciliationKey(
            isEnabled: isEnabled,
            wiredIsActive: wiredIsActive,
            wifiWasDisabledByApp: wifiWasDisabledByApp
        )
        guard key != lastReconciliation else { return }
        lastReconciliation = key

        let interface = CWWiFiClient.shared().interface()
        let action = WiFiAutomationPolicy.action(
            isEnabled: isEnabled,
            wiredIsActive: wiredIsActive,
            wifiIsPowered: interface?.powerOn(),
            wifiWasDisabledByApp: wifiWasDisabledByApp
        )

        switch action {
        case .turnPowerOn:
            restoreWiFi(
                using: interface,
                statusOnSuccess: isEnabled
                    ? "网线已拔出，Wi-Fi 已自动开启"
                    : "已关闭自动切换，Wi-Fi 已恢复"
            )

        case .turnPowerOff:
            guard let interface else {
                lastReconciliation = nil
                setFailure("未发现可控制的 Wi-Fi 接口。")
                return
            }

            // Record ownership before changing power. If the app exits between the
            // two operations, the next launch will still know it should restore Wi-Fi.
            wifiWasDisabledByApp = true
            do {
                try interface.setPower(false)
                rememberCurrentReconciliation(isEnabled: isEnabled, wiredIsActive: wiredIsActive)
                setStatus("有线网络已连接，Wi-Fi 已自动关闭")
            } catch {
                if interface.powerOn() {
                    wifiWasDisabledByApp = false
                }
                setFailure(powerErrorMessage(prefix: "无法自动关闭 Wi-Fi", error: error))
            }

        case .none:
            guard isEnabled else {
                setStatus("未启用")
                return
            }
            guard let interface else {
                lastReconciliation = nil
                setFailure("未发现可控制的 Wi-Fi 接口。")
                return
            }
            if wiredIsActive {
                setStatus(wifiWasDisabledByApp ? "有线网络已连接，Wi-Fi 已关闭" : "Wi-Fi 原本已关闭")
            } else {
                setStatus(interface.powerOn() ? "等待有线网络连接" : "Wi-Fi 保持手动关闭")
            }
        }
    }

    private func restoreWiFi(using suppliedInterface: CWInterface?, statusOnSuccess: String) {
        guard let interface = suppliedInterface ?? CWWiFiClient.shared().interface() else {
            lastReconciliation = nil
            setFailure("未发现可控制的 Wi-Fi 接口，暂时无法恢复 Wi-Fi。")
            return
        }
        do {
            if !interface.powerOn() {
                try interface.setPower(true)
            }
            wifiWasDisabledByApp = false
            rememberCurrentReconciliation(
                isEnabled: lastEnabledState ?? false,
                wiredIsActive: lastObservedWiredState ?? false
            )
            setStatus(statusOnSuccess)
        } catch {
            setFailure(powerErrorMessage(prefix: "无法自动开启 Wi-Fi", error: error))
        }
    }

    private func rememberCurrentReconciliation(isEnabled: Bool, wiredIsActive: Bool) {
        lastReconciliation = ReconciliationKey(
            isEnabled: isEnabled,
            wiredIsActive: wiredIsActive,
            wifiWasDisabledByApp: wifiWasDisabledByApp
        )
    }

    private func powerErrorMessage(prefix: String, error: Error) -> String {
        "\(prefix)：\(error.localizedDescription) 请在系统提示中授权后重试。"
    }

    private func setStatus(_ text: String) {
        status = text
        lastError = ""
    }

    private func setFailure(_ message: String) {
        status = "自动切换失败"
        lastError = message
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        restoreBeforeTermination()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
