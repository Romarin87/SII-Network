import Foundation

private final class FakePower: WiFiPowerControlling {
    var powered = true
    var failReads = false
    var failWrites = false
    var pauseRead = false
    var pauseWrite = false
    var pendingRead: CheckedContinuation<Void, Never>?
    var pendingWrite: CheckedContinuation<Void, Never>?
    var reads = 0
    var writes: [Bool] = []

    func readPower() async throws -> Bool {
        reads += 1
        if pauseRead {
            pauseRead = false
            await withCheckedContinuation { pendingRead = $0 }
        }
        if failReads { throw WiFiPowerError.unreadableState }
        return powered
    }

    func setPower(_ enabled: Bool) async throws {
        writes.append(enabled)
        if pauseWrite {
            pauseWrite = false
            await withCheckedContinuation { pendingWrite = $0 }
        }
        if failWrites { throw WiFiPowerError.stateMismatch }
        powered = enabled
    }

    func restoreBeforeTermination() throws {
        writes.append(true)
        powered = true
    }
}

@MainActor
private final class Fixture {
    let suite = "NetWatchSII.tests." + UUID().uuidString
    let radio = FakePower()
    var time = Date(timeIntervalSince1970: 1_000)
    lazy var defaults = UserDefaults(suiteName: suite)!
    lazy var manager = WiFiAutomationManager(
        defaults: defaults, power: radio,
        now: { [unowned self] in self.time }, observeLifecycle: false
    )
    var owned: Bool { defaults.bool(forKey: WiFiAutomationManager.ownershipKey) }

    func input(enabled: Bool = true, wired: Bool = true) {
        manager.tick(isEnabled: enabled, hasActiveWiredInterface: wired)
        manager.tick(isEnabled: enabled, hasActiveWiredInterface: wired)
    }

    func clean() { defaults.removePersistentDomain(forName: suite) }
}

@main
private enum Regression {
    @MainActor static func settle() async {
        for _ in 0..<30 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    @MainActor static func main() async throws {
        do {
            let f = Fixture(); defer { f.clean() }
            f.input(); await settle()
            check(f.radio.writes == [false] && !f.radio.powered && f.owned, "Initial wired power-off")
            f.radio.powered = true
            f.time += 4; f.input(); await settle()
            check(f.radio.writes.count == 1, "Checks must be throttled")
            f.time += 1; f.input(); await settle()
            check(f.radio.writes == [false, false] && !f.radio.powered, "Recheck radio despite unchanged Ethernet")
            f.input(wired: false); await settle()
            check(f.radio.powered && !f.owned, "Unplug restores owned power")
        }
        do {
            let f = Fixture(); defer { f.clean() }
            f.radio.powered = false
            f.input(); await settle()
            f.input(wired: false); await settle()
            check(f.radio.writes.isEmpty && !f.owned, "Preserve Wi-Fi originally switched off by user")
        }
        do {
            let f = Fixture(); defer { f.clean() }
            f.radio.failWrites = true
            f.input(); await settle()
            check(!f.manager.lastError.isEmpty && !f.owned, "Failed request must not report success")
            f.radio.failWrites = false
            f.time += 29; f.input(); await settle()
            check(f.radio.writes.count == 1, "Failed requests use backoff")
            f.time += 1; f.input(); await settle()
            check(f.radio.writes.count == 2 && !f.radio.powered && f.manager.lastError.isEmpty,
                  "Failure retries automatically without cable changes")
        }
        do {
            let f = Fixture(); defer { f.clean() }
            f.radio.failReads = true
            f.input(); await settle()
            check(f.radio.writes.isEmpty && !f.owned && !f.manager.lastError.isEmpty,
                  "Unknown radio state must not be treated as off")
            f.radio.failReads = false
            f.time += 30; f.input(); await settle()
            check(!f.radio.powered && f.owned, "Recover from transient read errors")
        }
        do {
            let f = Fixture(); defer { f.clean() }
            f.input(); await settle()
            f.input(enabled: false); await settle()
            check(f.radio.powered && !f.owned, "Disabling automation restores owned Wi-Fi")
            let reads = f.radio.reads
            f.time += 100; f.input(enabled: false); await settle()
            check(f.radio.reads == reads, "Disabled idle feature does not query radio")
        }
        do {
            let f = Fixture(); defer { f.clean() }
            f.radio.powered = false
            f.defaults.set(true, forKey: WiFiAutomationManager.ownershipKey)
            f.input(wired: false); await settle()
            check(f.radio.powered && !f.owned, "Restart restores persisted ownership")
        }
        do {
            let f = Fixture(); defer { f.clean() }
            f.radio.pauseWrite = true
            f.input(); await settle()
            check(f.radio.pendingWrite != nil, "Power-off request must be in flight")
            f.input(wired: false)
            f.radio.pendingWrite?.resume(); f.radio.pendingWrite = nil
            await settle()
            check(f.radio.writes == [false, true] && f.radio.powered && !f.owned,
                  "Unplug during power-off restores after operation completes")
        }
        do {
            let f = Fixture(); defer { f.clean() }
            f.radio.pauseRead = true
            f.input(); await settle()
            f.input(enabled: false)
            f.radio.pendingRead?.resume(); f.radio.pendingRead = nil
            await settle()
            check(f.radio.writes.isEmpty && f.radio.powered, "Stale read must not switch radio after disabling")
        }
        do {
            let f = Fixture(); defer { f.clean() }
            f.input(); await settle()
            f.radio.powered = true
            f.manager.tick(isEnabled: true, hasActiveWiredInterface: false)
            f.input(); await settle()
            check(!f.radio.powered && f.radio.writes.count == 2,
                  "Recover after one-sample cable bounce")
        }
        do {
            let f = Fixture(); defer { f.clean() }
            f.input(); await settle()
            f.manager.restoreBeforeTermination()
            f.manager.restoreBeforeTermination()
            check(f.radio.writes == [false, true] && !f.owned, "Termination recovery is idempotent")
        }
        check(try SystemWiFiPowerController.parsePowerOutput("Wi-Fi Power (en0): On\n", device: "en0"),
              "Parse explicit On")
        check(try !SystemWiFiPowerController.parsePowerOutput("Wi-Fi Power (en0): Off\n", device: "en0"),
              "Parse explicit Off")
        for output in ["AuthorizationCreate() failed", "", "Wi-Fi Power (en1): Off", "Wi-Fi is disconnected"] {
            do {
                _ = try SystemWiFiPowerController.parsePowerOutput(output, device: "en0")
                preconditionFailure("Ambiguous output must be rejected")
            } catch { }
        }
        print("PASS: 10 Wi-Fi lifecycle scenarios and 6 power-state parser cases")
    }
}
