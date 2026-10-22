import JadeAPI
import JadeTesting

/// Construye el `Environment` de JadeAPI para un ``Stage``. Aquí viven los interceptores de la capa de
/// entorno, los que aplican a todos los servicios:
///
/// - `MetricsInterceptor` el más externo, para que `elapsed` incluya reintentos y refresh.
/// - `AuthInterceptor` pone `Authorization: Bearer …` cuando hay sesión.
/// - `RequestLogger` escribe una línea por petición, redactando credenciales.
public enum AppEnvironment {

    /// - Parameter mock: servidor falso para `mock`; `nil` usa ``Fixtures`` con su latencia de demo.
    public static func make(stage: Stage, tokens: SessionTokens, mock: MockClient? = nil) throws -> Environment {
        var environment = try Environment(plist: stage.configuration)
        environment.interceptors = [
            MetricsInterceptor { MetricsLog.current.record($0) },
            AuthInterceptor(tokens: tokens),
            RequestLogger(.line, sink: { CallLog.current.append($0) }),
        ]
        #if DEBUG
        environment = environment.applyingLaunchOverrides()   // --service.catalog=http://localhost:8080
        #endif
        if stage == .mock {
            // Todos los servicios al mismo servidor falso. El WebSocket no tiene mock: su pestaña lo dice.
            environment = environment.mockingAll(with: mock ?? Fixtures.makeClient())
        }
        return environment
    }
}
