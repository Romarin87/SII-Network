import Combine
import Darwin
import Foundation
import Security

@MainActor
final class SRunCredentialStore: ObservableObject {
    @Published private(set) var configuredUsername = ""
    @Published private(set) var statusText = "未配置"
    @Published private(set) var feedbackText = ""
    @Published private(set) var feedbackIsError = false

    private static let keychainService = "cn.edu.sii.srun-autologin"
    private static let baseURL = "https://auth.sii.edu.cn"
    private static let accessControllerID = "1"
    private static let theme = "pro"

    init() {
        refresh()
    }

    func refresh() {
        switch Self.readConfiguration() {
        case .missing:
            configuredUsername = ""
            statusText = "未配置"
        case .invalid:
            configuredUsername = ""
            statusText = "配置文件不可用"
        case let .configured(username):
            configuredUsername = username
            switch Self.keychainPresence(for: username) {
            case .present:
                statusText = "已配置，可用于自动重连"
            case .missing:
                statusText = "已保存账号，钥匙串中缺少密码"
            case .unavailable:
                statusText = "已保存账号，暂时无法检查钥匙串"
            }
        }
    }

    @discardableResult
    func save(username rawUsername: String, password: String) -> Bool {
        feedbackText = ""
        feedbackIsError = false

        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            showError("请输入校园网账号。")
            return false
        }
        guard !password.isEmpty else {
            showError("请输入校园网密码。")
            return false
        }

        do {
            try Self.storePassword(password, for: username)
        } catch {
            showError("无法写入 macOS 钥匙串，请检查访问权限后重试。")
            refresh()
            return false
        }

        do {
            try Self.writeConfiguration(username: username)
        } catch {
            showError("钥匙串已更新，但配置文件写入失败，请重试。")
            refresh()
            return false
        }

        configuredUsername = username
        statusText = "已配置，可用于自动重连"
        feedbackText = "账号与密码已安全保存。"
        feedbackIsError = false
        return true
    }

    private func showError(_ message: String) {
        feedbackText = message
        feedbackIsError = true
    }
}

private extension SRunCredentialStore {
    struct DiskConfiguration: Codable {
        let username: String
        let baseURL: String
        let accessControllerID: String
        let theme: String

        enum CodingKeys: String, CodingKey {
            case username
            case baseURL = "base_url"
            case accessControllerID = "ac_id"
            case theme
        }
    }

    enum ConfigurationState {
        case missing
        case invalid
        case configured(username: String)
    }

    enum KeychainPresence {
        case present
        case missing
        case unavailable
    }

    enum StorageError: Error {
        case keychain
        case configuration
    }

    static var applicationDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("SII-SRun", isDirectory: true)
    }

    static var configurationURL: URL {
        applicationDirectoryURL.appendingPathComponent("config.json", isDirectory: false)
    }

    static func keychainQuery(for username: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: username
        ]
    }

    static func storePassword(_ password: String, for username: String) throws {
        guard let passwordData = password.data(using: .utf8) else {
            throw StorageError.keychain
        }

        let query = keychainQuery(for: username)
        let attributes = [kSecValueData as String: passwordData]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw StorageError.keychain
        }

        var newItem = query
        newItem[kSecValueData as String] = passwordData
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }

        // Another writer may have inserted the same item after the update check.
        if addStatus == errSecDuplicateItem,
           SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess {
            return
        }
        throw StorageError.keychain
    }

    static func keychainPresence(for username: String) -> KeychainPresence {
        var query = keychainQuery(for: username)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = kCFBooleanTrue

        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            return .present
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable
        }
    }

    static func readConfiguration() -> ConfigurationState {
        let path = configurationURL.path
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            return errno == ENOENT ? .missing : .invalid
        }
        guard metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o077 == 0 else {
            return .invalid
        }

        guard let data = try? Data(contentsOf: configurationURL),
              let configuration = try? JSONDecoder().decode(DiskConfiguration.self, from: data) else {
            return .invalid
        }

        let username = configuration.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty,
              configuration.baseURL == baseURL,
              configuration.accessControllerID == accessControllerID,
              configuration.theme == theme else {
            return .invalid
        }
        return .configured(username: username)
    }

    static func writeConfiguration(username: String) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: applicationDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw StorageError.configuration
        }

        var directoryMetadata = stat()
        guard lstat(applicationDirectoryURL.path, &directoryMetadata) == 0,
              directoryMetadata.st_uid == getuid(),
              directoryMetadata.st_mode & S_IFMT == S_IFDIR,
              chmod(applicationDirectoryURL.path, 0o700) == 0 else {
            throw StorageError.configuration
        }

        let configuration = DiskConfiguration(
            username: username,
            baseURL: baseURL,
            accessControllerID: accessControllerID,
            theme: theme
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(configuration) else {
            throw StorageError.configuration
        }
        data.append(0x0A)

        var template = Array(
            applicationDirectoryURL
                .appendingPathComponent(".config.XXXXXX", isDirectory: false)
                .path
                .utf8CString
        )
        let descriptor = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress!)
        }
        guard descriptor >= 0 else {
            throw StorageError.configuration
        }

        let temporaryPath = String(cString: template)
        var descriptorIsOpen = true
        var removeTemporaryFile = true
        defer {
            if descriptorIsOpen {
                close(descriptor)
            }
            if removeTemporaryFile {
                unlink(temporaryPath)
            }
        }

        guard fchmod(descriptor, 0o600) == 0,
              writeAll(data, to: descriptor),
              fsync(descriptor) == 0 else {
            throw StorageError.configuration
        }

        let closeStatus = close(descriptor)
        descriptorIsOpen = false
        guard closeStatus == 0 else {
            throw StorageError.configuration
        }

        guard rename(temporaryPath, configurationURL.path) == 0 else {
            throw StorageError.configuration
        }
        removeTemporaryFile = false
    }

    static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
