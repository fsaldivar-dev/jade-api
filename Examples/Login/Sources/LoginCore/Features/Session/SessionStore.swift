import JadeAPI
import Observation

/// Estado de la sesión: login, perfil y logout. Habla con los repositorios por su protocolo.
@MainActor
@Observable
public final class SessionStore {
    public enum Status: Equatable { case signedOut, signingIn, signedIn(Profile) }

    public private(set) var status: Status = .signedOut
    public private(set) var token: Token?
    public private(set) var errorMessage: String?

    private let auth: any AuthRepository
    private let profiles: any ProfileRepository
    private let tokens: SessionTokens

    public init(auth: any AuthRepository, profiles: any ProfileRepository, tokens: SessionTokens) {
        self.auth = auth
        self.profiles = profiles
        self.tokens = tokens
    }

    public var isSignedIn: Bool { if case .signedIn = status { true } else { false } }

    public func signIn(user: String, password: String) async {
        status = .signingIn
        errorMessage = nil
        do {
            let token = try await auth.login(user: user, password: password)
            await tokens.set(token.value)
            let profile = try await profiles.me(token: Header(token.value))
            self.token = token
            status = .signedIn(profile)
        } catch {
            await tokens.set(nil)
            token = nil
            status = .signedOut
            errorMessage = Self.describe(error)
        }
    }

    public func signOut() async {
        if let token {
            try? await auth.logout(token: Header(token.value))   // el logout remoto no bloquea el local
        }
        await tokens.set(nil)
        token = nil
        status = .signedOut
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let http as HTTPError: http.description
        default: "\(error)"
        }
    }
}
