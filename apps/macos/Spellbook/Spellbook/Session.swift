import Foundation
import Security

struct SpellbookSession: Codable, Equatable {
    var token: String
    var email: String
    var expiresAt: String

    var isExpired: Bool {
        guard let date = ISO8601DateFormatter.spellbook.date(from: expiresAt) else {
            return true
        }

        return date <= Date()
    }
}

final class KeychainSessionStore {
    private let service = "com.raddus.spellbook.session"
    private let account = "spellbook-jwt"

    func load() -> SpellbookSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }

        return try? JSONDecoder.spellbook.decode(SpellbookSession.self, from: data)
    }

    func save(_ session: SpellbookSession) throws {
        let data = try JSONEncoder.spellbook.encode(session)
        clear()

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SpellbookError.message("Could not save the session securely.")
        }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

@MainActor
final class SessionModel: ObservableObject {
    @Published private(set) var session: SpellbookSession?
    @Published var authScreen: AuthScreen = .welcome

    private let keychain = KeychainSessionStore()

    init() {
        restore()
    }

    var signedInEmail: String? {
        session?.email
    }

    func restore() {
        guard let stored = keychain.load(), !stored.isExpired else {
            keychain.clear()
            session = nil
            authScreen = .welcome
            return
        }

        session = stored
    }

    func completeSignIn(_ newSession: SpellbookSession) throws {
        try keychain.save(newSession)
        session = newSession
    }

    func clearExpiredSession() {
        keychain.clear()
        session = nil
        authScreen = .welcome
    }

    func signOut() {
        clearExpiredSession()
    }
}

enum AuthScreen: Equatable {
    case welcome
    case email
    case otp(email: String)
}

enum SpellbookError: LocalizedError {
    case message(String)
    case expiredSession
    case missingPublishedSpell

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        case .expiredSession:
            return "Your session expired. Sign in again."
        case .missingPublishedSpell:
            return "That published spell no longer exists."
        }
    }
}
