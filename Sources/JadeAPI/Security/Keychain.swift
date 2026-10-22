import Foundation
import Security

/// Almacén clave-valor seguro. La implementación real es el Keychain del sistema; en pruebas, memoria.
public protocol KeychainStore: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ key: String, _ data: Data) throws
    func delete(_ key: String) throws
}

public enum KeychainError: Error, Equatable, CustomStringConvertible {
    case status(OSStatus)
    case userCancelled
    public var description: String {
        switch self {
        case .status(let code): "Keychain: \(SecCopyErrorMessageString(code, nil) as String? ?? "error \(code)")"
        case .userCancelled: "Keychain: el usuario canceló la autenticación"
        }
    }
}

/// Keychain del sistema. Los elementos quedan atados a este dispositivo
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) y, si se pide, a la biometría actual
/// (`.biometryCurrentSet`: si cambia la huella o la cara, el token deja de leerse).
public struct SecItemKeychainStore: KeychainStore {
    public enum Protection: Sendable {
        /// Disponible tras el primer desbloqueo, solo en este dispositivo. Para tokens de sesión.
        case afterFirstUnlock
        /// Exige biometría o código del dispositivo cada vez que se lee. Para refresh tokens de larga vida.
        case biometryCurrentSet
    }

    public let service: String
    public let accessGroup: String?
    public let protection: Protection

    public init(service: String, accessGroup: String? = nil, protection: Protection = .afterFirstUnlock) {
        self.service = service
        self.accessGroup = accessGroup
        self.protection = protection
    }

    private func query(_ key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func read(_ key: String) throws -> Data? {
        var query = self.query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        case errSecUserCanceled, errSecAuthFailed: throw KeychainError.userCancelled
        default: throw KeychainError.status(status)
        }
    }

    public func write(_ key: String, _ data: Data) throws {
        try delete(key)
        var attributes = query(key)
        attributes[kSecValueData as String] = data
        switch protection {
        case .afterFirstUnlock:
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .biometryCurrentSet:
            var error: Unmanaged<CFError>?
            guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, &error) else {
                throw KeychainError.status(OSStatus((error?.takeRetainedValue() as Error?).map { ($0 as NSError).code } ?? -1))
            }
            attributes[kSecAttrAccessControl as String] = control
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}

/// Almacén en memoria para pruebas y previews. Nunca para producción.
public final class InMemoryKeychainStore: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    public init() {}
    public func read(_ key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return items[key] }
    public func write(_ key: String, _ data: Data) throws { lock.lock(); items[key] = data; lock.unlock() }
    public func delete(_ key: String) throws { lock.lock(); items[key] = nil; lock.unlock() }
    public var keys: [String] { lock.lock(); defer { lock.unlock() }; return Array(items.keys) }
}

// MARK: - Tokens en el Keychain

/// Sesión guardada: access token, refresh token y caducidad.
public struct StoredTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public func isExpired(at date: Date = .now, leeway: TimeInterval = 30) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(date) <= leeway
    }
}

/// ``TokenProvider`` sobre un ``KeychainStore``: entrega el access token mientras no caduque y
/// refresca con el refresh token cuando caduca o el servidor responde 401. El refresh es único aunque
/// haya N peticiones en vuelo (lo coordina ``AuthInterceptor``).
///
/// ```swift
/// let tokens = KeychainTokenProvider(store: SecItemKeychainStore(service: "mx.banco.app")) { refreshToken in
///     try await auth.refresh(token: refreshToken)      // devuelve StoredTokens nuevos
/// }
/// let client = AppClient(stage: .prod, interceptors: [AuthInterceptor(tokens: tokens)])
/// ```
public actor KeychainTokenProvider: TokenProvider {
    public typealias Refresh = @Sendable (_ refreshToken: String) async throws -> StoredTokens

    private let store: any KeychainStore
    private let key: String
    private let refresh: Refresh
    private var cached: StoredTokens?

    public init(store: any KeychainStore, key: String = "jade.session", refresh: @escaping Refresh) {
        self.store = store
        self.key = key
        self.refresh = refresh
    }

    /// Guarda la sesión tras el login.
    public func store(_ tokens: StoredTokens) throws {
        try store.write(key, try JSONEncoder().encode(tokens))
        cached = tokens
    }

    /// Borra la sesión (logout).
    public func clear() throws {
        try store.delete(key)
        cached = nil
    }

    public func current() throws -> StoredTokens? {
        if let cached { return cached }
        guard let data = try store.read(key) else { return nil }
        let tokens = try JSONDecoder().decode(StoredTokens.self, from: data)
        cached = tokens
        return tokens
    }

    // MARK: TokenProvider

    public func currentToken() async throws -> String? {
        guard let tokens = try current() else { return nil }
        if tokens.isExpired() { return try await refreshToken() }
        return tokens.accessToken
    }

    public func refreshToken() async throws -> String {
        guard let tokens = try current(), let refreshToken = tokens.refreshToken else {
            throw HTTPError.status(401, Response(status: 401, request: Request(method: .get, url: URL(string: "https://jade.local/session")!, path: "/session")))
        }
        let fresh = try await refresh(refreshToken)
        try store(fresh)
        return fresh.accessToken
    }
}
