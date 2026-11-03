import AppKit
import Combine
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

    private struct Input: Equatable {
        let isEnabled: Bool
        let wiredIsActive: Bool
    }

    static let ownershipKey = "wifiDisabledByEthernetAutomation"
    private let defaults: UserDefaults
    private let power: WiFiPowerControlling
    private let now: () -> Date
    private var input: Input?
    private var stableSampleCount = 0
    private var revision: UInt64 = 0
    private var nextCheck = Date.distantPast
    private var isChecking = false
    private var terminating = false

    init(
        defaults: UserDefaults = .standard,
        power: WiFiPowerControlling = SystemWiFiPowerController(),
        now: @escaping () -> Date = Date.init,
        observeLifecycle: Bool = true
    ) {
        self.defaults = defaults
        self.power = power
        self.now = now
        super.init()
        if observeLifecycle {
            NotificationCenter.default.addObserver(
                self, selector: #selector(applicationWillTerminate(_:)),
                name: NSApplication.willTerminateNotification, object: nil
            )
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(systemDidWake(_:)),
                name: NSWorkspace.didWakeNotification, object: nil
            )
        }
    }

    func tick(isEnabled: Bool, hasActiveWiredInterface wiredIsActive: Bool) {
        guard !terminating else { return }
        let observed = Input(isEnabled: isEnabled, wiredIsActive: wiredIsActive)
        if input != observed {
            input = observed
            stableSampleCount = 1
            revision &+= 1
            nextCheck = .distantPast
        } else {
            stableSampleCount = min(2, stableSampleCount + 1)
        }
        guard !isEnabled || stableSampleCount >= 2 else {
            setStatus("正在确认网络状态…")
            return
        }
        reconcileIfDue()
    }

    func applyPreference(isEnabled: Bool, hasActiveWiredInterface wiredIsActive: Bool) {
        nextCheck = .distantPast
        tick(isEnabled: isEnabled, hasActiveWiredInterface: wiredIsActive)
    }

    func retry(isEnabled: Bool, hasActiveWiredInterface wiredIsActive: Bool) {
        nextCheck = .distantPast
        tick(isEnabled: isEnabled, hasActiveWiredInterface: wiredIsActive)
    }

    func restoreBeforeTermination() {
        guard !terminating else { return }
        terminating = true
        guard wifiWasDisabledByApp else { return }
        do {
            // The controller serializes this with any pending power operation.
            try power.restoreBeforeTermination()
            wifiWasDisabledByApp = false
        } catch {
            // Retain the marker so the next launch can recover the power state.
        }
    }

    private var wifiWasDisabledByApp: Bool {
        get { defaults.bool(forKey: Self.ownershipKey) }
        set { defaults.set(newValue, forKey: Self.ownershipKey) }
    }

    private func reconcileIfDue() {
        guard let input, !terminating, !isChecking, now() >= nextCheck else { return }
        guard input.isEnabled || wifiWasDisabledByApp else {
            setStatus("未启用")
            return
        }
        let startedRevision = revision
        isChecking = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isChecking = false
                // A cable/preference change during an operation must be reconciled
                // using the new input after the actual operation has finished.
                if !self.terminating, self.revision != startedRevision {
                    self.nextCheck = .distantPast
                    if self.stableSampleCount >= 2 || self.input?.isEnabled == false {
                        self.reconcileIfDue()
                    }
                }
            }
            do {
                let powered = try await self.power.readPower()
                guard !self.terminating, self.revision == startedRevision else { return }
                let action = WiFiAutomationPolicy.action(
                    isEnabled: input.isEnabled,
                    wiredIsActive: input.wiredIsActive,
                    wifiIsPowered: powered,
                    wifiWasDisabledByApp: self.wifiWasDisabledByApp
                )
                switch action {
                case .turnPowerOff:
                    let previouslyOwned = self.wifiWasDisabledByApp
                    self.wifiWasDisabledByApp = true
                    self.setStatus("正在关闭 Wi-Fi 电源…")
                    do {
                        try await self.power.setPower(false)
                    } catch {
                        // Only roll back new ownership if the radio is confirmed on.
                        // An unknown result may still require recovery after unplug.
                        let afterFailure = try? await self.power.readPower()
                        if !self.terminating, !previouslyOwned, afterFailure == true {
                            self.wifiWasDisabledByApp = false
                        }
                        throw error
                    }
                    guard !self.terminating, self.revision == startedRevision else { return }
                    self.setStatus("有线网络已连接，Wi-Fi 电源已关闭")

                case .turnPowerOn:
                    self.setStatus("正在恢复 Wi-Fi 电源…")
                    if !powered { try await self.power.setPower(true) }
                    guard !self.terminating else { return }
                    self.wifiWasDisabledByApp = false
                    guard self.revision == startedRevision else { return }
                    self.setStatus(input.isEnabled
                        ? "有线网络已断开，Wi-Fi 电源已开启"
                        : "已关闭自动切换，Wi-Fi 电源已恢复")

                case .none:
                    self.setStatus(input.wiredIsActive
                        ? "有线网络已连接，Wi-Fi 电源已关闭"
                        : (powered ? "等待有线网络连接" : "Wi-Fi 保持手动关闭"))
                }
                // Check the radio itself periodically, even if Ethernet is unchanged.
                self.nextCheck = self.now().addingTimeInterval(5)
            } catch {
                guard !self.terminating, self.revision == startedRevision else { return }
                self.status = "自动切换待重试"
                self.lastError = "\(error.localizedDescription) 30 秒后自动重试，也可点击重试按钮。"
                self.nextCheck = self.now().addingTimeInterval(30)
            }
        }
    }

    private func setStatus(_ text: String) {
        if status != text { status = text }
        if !lastError.isEmpty { lastError = "" }
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        restoreBeforeTermination()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        stableSampleCount = 0
        revision &+= 1
        nextCheck = .distantPast
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
