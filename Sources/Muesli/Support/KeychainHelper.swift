import Foundation
import Security

/// Minimal Keychain wrapper. Stores single secrets or JSON-encoded lists of API keys.
enum KeychainHelper {
    private static let service = "app.muesli.Muesli"

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return true }
        var attrs = query
        attrs[kSecValueData as String] = data
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    /// Saves a list of API keys as a JSON array in Keychain.
    @discardableResult
    static func saveKeys(_ keys: [String], account: String) -> Bool {
        let cleaned = cleanKeys(keys)
        if cleaned.isEmpty {
            return save("", account: account)
        }
        guard let data = try? JSONEncoder().encode(cleaned),
              let json = String(data: data, encoding: .utf8)
        else { return false }
        return save(json, account: account)
    }

    /// Loads a list of API keys (supports both JSON array and legacy plain string).
    static func loadKeys(account: String, fallbackSingleAccount: String? = nil) -> [String] {
        if let raw = load(account: account), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let data = raw.data(using: .utf8),
               let arr = try? JSONDecoder().decode([String].self, from: data) {
                return cleanKeys(arr)
            }
            return cleanKeys([raw])
        }
        if let fb = fallbackSingleAccount,
           let legacy = load(account: fb),
           !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cleanKeys([legacy])
        }
        return []
    }

    static func cleanKeys(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in keys {
            let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty && !seen.contains(k) {
                seen.insert(k)
                out.append(k)
            }
        }
        return out
    }

    // MARK: - Consolidated API key bundle

    static let bundleAccount = "api-keys-v1"

    static func encodeKeyBundle(_ bundle: [String: [String]]) -> String? {
        let normalized = bundle.reduce(into: [String: [String]]()) { acc, entry in
            let cleaned = cleanKeys(entry.value)
            if !cleaned.isEmpty {
                acc[entry.key] = cleaned
            }
        }
        guard let data = try? JSONEncoder().encode(normalized) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeKeyBundle(_ json: String) -> [String: [String]]? {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return nil }
        return raw.mapValues { cleanKeys($0) }
    }

    static func loadKeyBundle() -> [String: [String]]? {
        guard let raw = load(account: bundleAccount) else { return nil }
        return decodeKeyBundle(raw)
    }

    @discardableResult
    static func saveKeyBundle(_ bundle: [String: [String]]) -> Bool {
        guard let json = encodeKeyBundle(bundle) else { return false }
        return save(json, account: bundleAccount)
    }
}
