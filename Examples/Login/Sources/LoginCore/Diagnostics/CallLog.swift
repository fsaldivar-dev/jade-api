import Foundation
import Observation

/// Registro de actividad que alimentan los decoradores (`@Logged`) y el `RequestLogger`, y que la UI muestra.
/// Escriben desde cualquier hilo (protegido por un lock); las vistas lo observan como cualquier `@Observable`.
///
/// Los que escriben lo toman de ``current``: en la app es ``shared``; una prueba lo sustituye por el suyo con
/// `CallLog.$current.withValue(log) { … }` sin tocar nada más, porque el valor viaja con la tarea.
@Observable
public final class CallLog: @unchecked Sendable {
    public static let shared = CallLog()

    /// Destino de las escrituras en la tarea actual (y sus hijas). Por defecto, ``shared``.
    @TaskLocal public static var current: CallLog = .shared

    @ObservationIgnored private let lock = NSLock()
    /// Más reciente primero.
    public private(set) var entries: [String] = []

    public init() {}

    public func append(_ line: String) {
        lock.withLock { entries.insert(line, at: 0) }
    }

    public func clear() {
        lock.withLock { entries.removeAll() }
    }

    /// Cuántas líneas contienen `text`. Útil en pruebas: "¿cuántas veces salió /catalog/featured?".
    public func count(containing text: String) -> Int {
        lock.withLock { entries.filter { $0.contains(text) }.count }
    }
}
