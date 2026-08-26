import Foundation

private struct SRunHelperResponse: Decodable {
    let state: String
    let message: String
}

@MainActor
final class SRunCoordinator: ObservableObject {
    @Published private(set) var status = "未启用"
    @Published private(set) var lastCheck: Date?

    private var running = false
    private var nextAllowedCheck = Date.distantPast

    func tick(hasActiveWiredInterface: Bool) {
        let enabled = UserDefaults.standard.bool(forKey: "srunAutoReconnect")
        guard enabled else {
            status = "未启用"
            return
        }
        guard hasActiveWiredInterface else {
            status = "等待有线网"
            return
        }
        guard !running, Date() >= nextAllowedCheck else { return }

        running = true
        nextAllowedCheck = Date().addingTimeInterval(15)
        status = "检查认证状态…"
        let helper = helperURL()

        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<String, Error> in
                guard let helper else {
                    return .failure(NSError(
                        domain: "NetWatchSII.SRun",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "找不到 SRun helper"]
                    ))
                }
                do {
                    let output = try CommandRunner.run(
                        "/usr/bin/python3",
                        ["-I", helper.path, "once", "--json"]
                    )
                    let data = Data(output.utf8)
                    let response = try JSONDecoder().decode(SRunHelperResponse.self, from: data)
                    return .success(response.message)
                } catch {
                    return .failure(error)
                }
            }.value

            self.running = false
            self.lastCheck = Date()
            switch result {
            case let .success(message):
                self.status = message.isEmpty ? "认证检查完成" : message
            case let .failure(error):
                self.status = "认证检查失败：\(error.localizedDescription)"
                self.nextAllowedCheck = Date().addingTimeInterval(60)
            }
        }
    }

    private func helperURL() -> URL? {
        return Bundle.main.url(forResource: "sii_srun_autologin", withExtension: "py")
    }
}
