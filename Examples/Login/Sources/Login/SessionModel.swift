import Foundation
import JadeAPI
import Observation

/// Estado de la pantalla. Habla con los repositorios por su protocolo: cambiar de entorno
/// solo cambia el `AppClient` que reciben.
@MainActor
@Observable
final class SessionModel {
    var stage: Stage { didSet { rebuild() } }
    var user = "admin"
    var password = "admin"
    var token: Token?
    var profile: Profile?
    var error: String?
    var busy = false
    var log: [String] = []

    private var auth: AuthRepository
    private var profiles: ProfileRepository

    init(stage: Stage) {
        self.stage = stage
        let client = AppClient(stage: stage)
        auth = AuthRepositoryClient(client: client)
        profiles = ProfileRepositoryClient(client: client)
    }

    private func rebuild() {
        let client = AppClient(stage: stage)
        auth = AuthRepositoryClient(client: client)
        profiles = ProfileRepositoryClient(client: client)
        token = nil; profile = nil; error = nil
    }

    func login() async {
        busy = true; defer { busy = false; log = Log.all }
        do {
            let token = try await auth.login(user: user, password: password)
            self.token = token
            self.profile = try await profiles.me(token: Header(token.value))
            error = nil
        } catch let failure as HTTPError {
            error = failure.description
        } catch {
            self.error = "\(error)"
        }
    }

    func logout() async {
        guard let token else { return }
        busy = true; defer { busy = false; log = Log.all }
        try? await auth.logout(token: Header(token.value))
        self.token = nil; profile = nil
    }
}
