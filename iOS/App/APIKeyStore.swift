import Foundation
import Security

/// The user's Anthropic API key, in this iPhone's Keychain: this device only (not in backups or iCloud Keychain),
/// readable after the first unlock so listening can go on with the screen locked. The app never shows it again.
enum APIKeyStore {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Call Copilot",
        kSecAttrAccount as String: "anthropic-api-key",
    ]

    static func load() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete() { SecItemDelete(base as CFDictionary) }

    /// Checks a key against Anthropic without spending anything (it lists one model). Nil means it works.
    static func check(_ key: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!, timeoutInterval: 20)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(MessagesSession.apiVersion, forHTTPHeaderField: "anthropic-version")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return nil }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            guard status == 401 else { return message }
            // What was pasted, without revealing the key: real keys start "sk-ant-api03-" and are about 108 characters.
            let shape = "\(key.count) characters, starting “\(key.prefix(12))…”"
            return "Anthropic didn't accept this key (\(shape)). Check the whole key was copied."
        } catch {
            return "Couldn't reach Anthropic (\(error.localizedDescription))."
        }
    }
}
