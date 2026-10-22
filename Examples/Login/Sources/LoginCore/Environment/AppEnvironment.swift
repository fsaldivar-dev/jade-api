import JadeAPI
import JadeTesting

/// Construye el `Environment` de JadeAPI para un ``Stage``: interceptores de la capa de entorno
/// (auth y log), overrides de desarrollo solo en Debug, y en `mock` los dos servicios al servidor falso.
public enum AppEnvironment {

    /// - Parameter mock: servidor falso para `mock`; `nil` usa ``Fixtures`` con su latencia de demo.
    public static func make(stage: Stage, tokens: SessionTokens, mock: MockClient? = nil) throws -> Environment {
        var environment = try Environment(plist: stage.configuration)
        environment.interceptors = [
            AuthInterceptor(tokens: tokens),
            RequestLogger(.line, sink: { CallLog.current.append($0) }),
        ]
        #if DEBUG
        environment = environment.applyingLaunchOverrides()   // --service.catalog=http://localhost:8080
        #endif
        if stage == .mock {
            environment = environment.mockingAll(with: mock ?? Fixtures.makeClient())
        }
        return environment
    }
}
