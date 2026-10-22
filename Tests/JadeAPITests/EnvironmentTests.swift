import Foundation
import JadeAPI
import JadeTesting
import Testing

@Suite("Nivel 2: Environment y servicios")
struct EnvironmentTests {

    @Test("Se construye desde el diccionario del Info.plist con servicios, headers y opciones")
    func fromPlist() throws {
        let environment = try Environment(plist: FixturePlist.twoServices)
        #expect(environment.name == "staging")
        #expect(Set(environment.services.keys) == ["users", "payments"])
        let payments = try #require(environment.configuration(for: "payments"))
        #expect(payments.baseURL.absoluteString == "https://payments.staging.ejemplo.com/v3")
        #expect(payments.headers == ["X-Service": "payments"])
        #expect(payments.options.timeout == .seconds(10))
        #expect(payments.options.cache == .seconds(30))
        #expect(payments.options.retry?.attempts == 1)        // 0 se normaliza a 1 intento
        #expect(environment.configuration(for: "users")?.options == RequestOptions.none)
    }

    @Test("Nivel 1 dentro del nivel 2: baseURL suelta = servicio por defecto")
    func singleBaseURL() throws {
        let environment = try Environment(plist: ["baseURL": "https://api.ejemplo.com"])
        #expect(environment.configuration(for: Environment.defaultService)?.baseURL.host == "api.ejemplo.com")
        let ping: PingRepository = try .live(in: environment)
        #expect(type(of: ping) == PingRepositoryClient.self)
    }

    @Test("Errores de configuración: servicio ausente, URL inválida, http fuera de Debug, secreto en headers")
    func validation() throws {
        let environment = try Environment(plist: FixturePlist.twoServices)
        #expect(throws: EnvironmentError.missingService("catalog")) { try environment.client(for: "catalog") }
        #expect(throws: EnvironmentError.invalidURL(service: "x", value: "no es url")) {
            try Environment(plist: ["services": ["x": ["baseURL": "no es url"]]])
        }
        #expect(throws: EnvironmentError.insecureURL(service: "x", url: "http://localhost:8080")) {
            try Environment(plist: ["services": ["x": ["baseURL": "http://localhost:8080"]]], security: SecurityPolicy(allowsInsecureHTTP: false))
        }
        _ = try Environment(plist: ["services": ["x": ["baseURL": "http://localhost:8080"]]])   // en Debug se permite
        #expect(throws: EnvironmentError.secretInConfiguration(service: "x", key: "X-Api-Key")) {
            try Environment(plist: ["services": ["x": ["baseURL": "https://a.b", "headers": ["X-Api-Key": "sk"]]]])
        }
        #expect(throws: EnvironmentError.missingConfiguration(key: "JadeAPI")) { try Environment(bundle: .main) }
    }

    @Test("client(for:) compone las capas: headers entorno < servicio, interceptores entorno → servicio, opciones del servicio")
    func composition() async throws {
        let log = TraceLog()
        let mock = MockClient()
        mock.on(.get, "/wallet") { _ in .noContent }
        var environment = try Environment(plist: FixturePlist.twoServices)
        environment.interceptors = [Trace(name: "env", log: log)]
        environment = environment.overriding(service: "payments", with: ServiceConfiguration(
            baseURL: URL(string: "https://payments.staging.ejemplo.com/v3")!,
            headers: ["X-Service": "payments", "Accept": "application/vnd.pay+json"],
            options: RequestOptions(timeout: .seconds(10)),
            interceptors: [Trace(name: "service", log: log)],
            transport: mock))

        let wallet: WalletRepository = try .live(in: environment)
        _ = try await wallet.wallet()
        let request = try #require(mock.received.first)
        #expect(request.url.absoluteString == "https://payments.staging.ejemplo.com/v3/wallet")
        #expect(request.headers["Accept"] == "application/vnd.pay+json")   // el servicio gana al entorno
        #expect(request.headers["X-App"] == "jade")                        // el del entorno se conserva
        #expect(request.headers["X-Service"] == "payments")
        #expect(request.headers["X-Trace"] == "env,service")
        #expect(request.options.timeout == .seconds(10))
        #expect(log.all == ["env →", "service →", "service ←", "env ←"])
    }

    @Test("Dos repositorios, dos servicios, dos mocks; el resto del entorno no se toca")
    func mockingOneService() async throws {
        let payments = MockClient().on(.get, "/wallet") { _ in MockResponse(body: Data("pay".utf8)) }
        let users = MockClient().on(.get, "/account") { _ in MockResponse(body: Data("acc".utf8)) }
        let environment = try Environment(plist: FixturePlist.twoServices)
            .mocking("payments", with: payments)
            .mocking("users", with: users)

        let wallet = try WalletRepositoryClient.live(in: environment)
        let account: AccountRepository = try .live(in: environment)
        #expect(try await wallet.wallet().text == "pay")
        #expect(try await account.account().text == "acc")
        #expect(payments.received.count == 1 && users.received.count == 1)
        #expect(WalletRepositoryClient.service == "payments")
        #expect(PingRepositoryClient.service == Environment.defaultService)
    }

    @Test("Overrides de desarrollo: argumento y variable redirigen un servicio (solo compila en Debug)")
    func launchOverrides() throws {
        let environment = try Environment(plist: FixturePlist.twoServices)
            .applyingLaunchOverrides(arguments: ["app", "--service.payments=http://localhost:8080"],
                                     environment: ["JADE_SERVICE_USERS": "http://localhost:9090"])
        #expect(environment.configuration(for: "payments")?.baseURL.absoluteString == "http://localhost:8080")
        #expect(environment.configuration(for: "users")?.baseURL.absoluteString == "http://localhost:9090")
    }
}
