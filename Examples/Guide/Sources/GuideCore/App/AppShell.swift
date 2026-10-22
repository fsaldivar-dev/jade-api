import Observation

/// Estado raíz de la app: el entorno activo y el contenedor construido para él. Cambiar de entorno
/// reconstruye todo (sesión incluida); si la configuración falla, la UI muestra el error en vez de caerse.
@MainActor
@Observable
public final class AppShell {
    public enum State {
        case ready(AppContainer)
        case failed(String)
    }

    public var stage: Stage { didSet { if stage != oldValue { boot() } } }
    public private(set) var state: State
    /// Lo que muestran las pestañas de log y métricas: donde escriben decoradores e interceptores.
    public let log: CallLog
    public let metrics: MetricsLog

    public init(stage: Stage, log: CallLog = .shared, metrics: MetricsLog = .shared) {
        self.stage = stage
        self.log = log
        self.metrics = metrics
        state = Self.build(stage)
    }

    public var container: AppContainer? {
        if case .ready(let container) = state { container } else { nil }
    }

    private func boot() {
        container?.echo.disconnect()
        container?.wiki.stop()
        log.clear()
        metrics.clear()
        state = Self.build(stage)
    }

    private static func build(_ stage: Stage) -> State {
        do { return .ready(try AppContainer(stage: stage)) }
        catch { return .failed("No se pudo configurar el entorno \(stage.rawValue): \(error)") }
    }
}
