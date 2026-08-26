import Foundation

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var interfaces: [InterfaceRate] = []
    @Published private(set) var history: [ThroughputPoint] = []
    @Published private(set) var processes: [ProcessNetworkRate] = []
    @Published private(set) var connections: [ConnectionRecord] = []
    @Published private(set) var publicIP = "未查询"
    @Published private(set) var publicIPError = ""
    @Published private(set) var lastUpdated = Date()

    let srun = SRunCoordinator()

    private let interfaceSampler = InterfaceSampler()
    private let processSampler = ProcessNetworkSampler()
    private var fastTimer: Timer?
    private var detailTimer: Timer?
    private var publicIPTimer: Timer?
    private var collectingDetails = false

    var downloadBytesPerSecond: Double {
        interfaces.filter(\.isActive).reduce(0) { $0 + $1.downloadBytesPerSecond }
    }

    var uploadBytesPerSecond: Double {
        interfaces.filter(\.isActive).reduce(0) { $0 + $1.uploadBytesPerSecond }
    }

    init() {
        sampleInterfaces()
        refreshDetails()
        if UserDefaults.standard.bool(forKey: "externalIPAutoRefresh") {
            refreshPublicIP()
        }
        fastTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleInterfaces() }
        }
        detailTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDetails() }
        }
        publicIPTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard UserDefaults.standard.bool(forKey: "externalIPAutoRefresh") else { return }
                self?.refreshPublicIP()
            }
        }
    }

    deinit {
        fastTimer?.invalidate()
        detailTimer?.invalidate()
        publicIPTimer?.invalidate()
    }

    func refreshPublicIP() {
        publicIPError = ""
        Task {
            do {
                publicIP = try await ExternalIPService.fetch()
            } catch {
                publicIP = "不可用"
                publicIPError = error.localizedDescription
            }
        }
    }

    func setExternalIPAutoRefresh(_ enabled: Bool) {
        if enabled { refreshPublicIP() }
    }

    func refreshDetails() {
        guard !collectingDetails else { return }
        collectingDetails = true
        let processSampler = self.processSampler
        Task {
            let result = await Task.detached(priority: .utility) {
                (processSampler.sample(), ConnectionSampler.sample())
            }.value
            processes = result.0
            connections = result.1
            collectingDetails = false
        }
    }

    private func sampleInterfaces() {
        interfaces = interfaceSampler.sample()
        lastUpdated = Date()
        history.append(
            ThroughputPoint(
                date: lastUpdated,
                downloadBytesPerSecond: downloadBytesPerSecond,
                uploadBytesPerSecond: uploadBytesPerSecond
            )
        )
        if history.count > 120 { history.removeFirst(history.count - 120) }
        let wiredActive = interfaces.contains { $0.kind == .ethernet && $0.isActive }
        srun.tick(hasActiveWiredInterface: wiredActive)
    }
}
