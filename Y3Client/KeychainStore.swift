import Foundation
import Security

enum KeychainStoreError: LocalizedError {
    case status(OSStatus)
    case invalidData
    case invalidStaffCredentials

    var errorDescription: String? {
        switch self {
        case .status(let code):
            return "安全な保存領域を利用できませんでした（コード \(code)）。iPhoneのロックを解除して再試行してください。"
        case .invalidData:
            return "保存済みの接続設定を読み出せませんでした。接続設定を削除して登録し直してください。"
        case .invalidStaffCredentials:
            return "保存済みのスタッフ情報を利用できませんでした。スタッフ情報を削除して登録し直してください。"
        }
    }
}

// The complete connection URL can contain the store identity. Credentials must
// never be reused solely because another connection shares the same origin.
struct StoredStaffCredentials: Codable, Sendable {
    let connectionURL: String
    let staffID: String
    let password: String
}

// SecItem operations block, so this actor runs them away from the UI actor.
actor KeychainStore {
    static let shared = KeychainStore()
    private init() {}

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Y3Client.connection",
            kSecAttrAccount as String: "loginURL",
            kSecAttrSynchronizable as String: false
        ]
    }

    private var staffQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Y3Client.staffLogin",
            kSecAttrAccount as String: "staffCredentials",
            kSecAttrSynchronizable as String: false
        ]
    }

    func read() throws -> String? {
        guard let data = try readData(matching: query) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidData
        }
        return value
    }

    func save(_ value: String) throws {
        try saveData(Data(value.utf8), matching: query)
    }

    func remove() throws {
        try removeData(matching: query)
    }

    func readStaffCredentials(for connectionURL: String) throws -> StoredStaffCredentials? {
        guard let data = try readData(matching: staffQuery) else { return nil }
        guard let value = try? JSONDecoder().decode(StoredStaffCredentials.self, from: data),
              URLPolicy.loginURL(from: value.connectionURL) != nil,
              !value.staffID.isEmpty, !value.password.isEmpty else {
            throw KeychainStoreError.invalidStaffCredentials
        }
        guard value.connectionURL == connectionURL else { return nil }
        return value
    }

    func saveStaffCredentials(_ value: StoredStaffCredentials) throws {
        guard URLPolicy.loginURL(from: value.connectionURL) != nil,
              !value.staffID.isEmpty, !value.password.isEmpty else {
            throw KeychainStoreError.invalidStaffCredentials
        }
        try saveData(JSONEncoder().encode(value), matching: staffQuery)
    }

    func removeStaffCredentials() throws {
        try removeData(matching: staffQuery)
    }

    private func readData(matching itemQuery: [String: Any]) throws -> Data? {
        var request = itemQuery
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.status(status) }
        guard let data = result as? Data else {
            throw KeychainStoreError.invalidData
        }
        return data
    }

    private func saveData(_ data: Data, matching itemQuery: [String: Any]) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = itemQuery
            for (key, value) in attributes { item[key] = value }
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw KeychainStoreError.status(status) }
    }

    private func removeData(matching itemQuery: [String: Any]) throws {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.status(status)
        }
    }
}
