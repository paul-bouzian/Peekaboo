import Foundation
import Security

struct AgentAccessTokenStore {
    typealias ReadToken = (_ service: String, _ account: String) -> String?
    typealias StoreToken = (
        _ service: String,
        _ account: String,
        _ token: String
    ) -> Bool

    static let service = "com.paulbouzian.Peekaboo.agent-access"
    static let legacyServices = ["com.emanueledipietro.Peekaboo.agent-access"]
    static let account = "mcp-bearer-token"

    private let readToken: ReadToken
    private let storeToken: StoreToken

    init(
        readToken: @escaping ReadToken = Self.readTokenFromKeychain,
        storeToken: @escaping StoreToken = Self.storeTokenInKeychain
    ) {
        self.readToken = readToken
        self.storeToken = storeToken
    }

    func loadOrCreate() -> String {
        if let existing = readToken(Self.service, Self.account) {
            return existing
        }
        for legacyService in Self.legacyServices {
            guard let legacyToken = readToken(legacyService, Self.account) else {
                continue
            }
            _ = storeToken(Self.service, Self.account, legacyToken)
            return readToken(Self.service, Self.account) ?? legacyToken
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let generated: String
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            generated = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        } else {
            generated = UUID().uuidString + UUID().uuidString
        }

        guard storeToken(Self.service, Self.account, generated) else {
            // The listener remains protected for this launch even if Keychain
            // persistence is temporarily unavailable.
            return generated
        }
        return readToken(Self.service, Self.account) ?? generated
    }

    private static func storeTokenInKeychain(
        service: String,
        account: String,
        token: String
    ) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    private static func readTokenFromKeychain(
        service: String,
        account: String
    ) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
