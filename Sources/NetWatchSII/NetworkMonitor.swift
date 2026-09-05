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
    let wifiAutomation = WiFiAutomationManager()

    private let interfaceSampler = InterfaceSampler()
    private var processSampler = ProcessNetworkSampler()
    private var fastTimer: Timer?
    private var detailTimer: Timer?
    private var publicIPTimer: Timer?
    private var samplesProcesses = false
    private var samplesConnections = false
    private var collectingProcesses = false
    private var collectingConnections = false
    private var processSamplingGeneration: UInt64 = 0
    private var connectionSamplingGeneration: UInt64 = 0

    var downloadBytesPerSecond: Double {
        interfaces.filter(\.isActive).reduce(0) { $0 + $1.downloadBytesPerSecond }
    }

    var uploadBytesPerSecond: Double {
        interfaces.filter(\.isActive).reduce(0) { $0 + $1.uploadBytesPerSecond }
    }

    var hasActiveWiredInterface: Bool {
        interfaces.contains { $0.kind == .ethernet && $0.isActive }
    }

    init() {
        sampleInterfaces()
        if UserDefaults.standard.bool(forKey: "externalIPAutoRefresh") {
            refreshPublicIP()
        }
        fastTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleInterfaces() }
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

    func setWiFiAutomationEnabled(_ enabled: Bool) {
        wifiAutomation.applyPreference(
            isEnabled: enabled,
            hasActiveWiredInterface: hasActiveWiredInterface
        )
    }

    func retryWiFiAutomation() {
        wifiAutomation.retry(
            isEnabled: UserDefaults.standard.bool(forKey: "disableWiFiWhenWired"),
            hasActiveWiredInterface: hasActiveWiredInterface
        )
    }

    func prepareForTermination() {
        wifiAutomation.restoreBeforeTermination()
    }

    func setDetailSampling(processes: Bool, connections: Bool) {
        let shouldStartProcesses = processes && !samplesProcesses
        let shouldStartConnections = connections && !samplesConnections

        if processes != samplesProcesses {
            samplesProcesses = processes
            processSamplingGeneration &+= 1
            if processes {
                // Start with a fresh baseline after a pause so the first non-zero
                // rate does not average traffic across the entire paused period.
                processSampler = ProcessNetworkSampler()
            } else {
                self.processes = []
            }
        }
        if connections != samplesConnections {
            samplesConnections = connections
            connectionSamplingGeneration &+= 1
            if !connections { self.connections = [] }
        }

        updateDetailTimer()

        if shouldStartProcesses { sampleProcesses() }
        if shouldStartConnections { sampleConnections() }
    }

    private func updateDetailTimer() {
        guard samplesProcesses || samplesConnections else {
            detailTimer?.invalidate()
            detailTimer = nil
            return
        }

        guard detailTimer == nil else { return }
        detailTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRequestedDetails() }
        }
    }

    private func refreshRequestedDetails() {
        if samplesProcesses { sampleProcesses() }
        if samplesConnections { sampleConnections() }
    }

    private func sampleProcesses() {
        guard samplesProcesses, !collectingProcesses else { return }
        collectingProcesses = true
        let generation = processSamplingGeneration
        let processSampler = self.processSampler

        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                processSampler.sample()
            }.value
            guard let self else { return }
            self.collectingProcesses = false

            guard self.samplesProcesses,
                  self.processSamplingGeneration == generation else {
                if self.samplesProcesses { self.sampleProcesses() }
                return
            }
            self.processes = result
        }
    }

    private func sampleConnections() {
        guard samplesConnections, !collectingConnections else { return }
        collectingConnections = true
        let generation = connectionSamplingGeneration

        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                ConnectionSampler.sample()
            }.value
            guard let self else { return }
            self.collectingConnections = false

            guard self.samplesConnections,
                  self.connectionSamplingGeneration == generation else {
                if self.samplesConnections { self.sampleConnections() }
                return
            }
            self.connections = result
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
        let wiredActive = hasActiveWiredInterface
        srun.tick(hasActiveWiredInterface: wiredActive)
        wifiAutomation.tick(
            isEnabled: UserDefaults.standard.bool(forKey: "disableWiFiWhenWired"),
            hasActiveWiredInterface: wiredActive
        )
    }
}
