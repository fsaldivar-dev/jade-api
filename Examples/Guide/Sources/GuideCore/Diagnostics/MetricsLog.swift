import Foundation
import JadeAPI
import Observation

/// Dónde deja sus informes el `MetricsInterceptor` del entorno. En una app real aquí iría Datadog,
/// Firebase Performance o tu panel; en la guía se resume por endpoint para la pestaña Métricas.
@Observable
public final class MetricsLog: @unchecked Sendable {
    public static let shared = MetricsLog()

    /// Igual que `CallLog.current`: la app usa ``shared``, cada prueba el suyo.
    @TaskLocal public static var current: MetricsLog = .shared

    /// Resumen de un endpoint: cuántas veces se llamó, cuánto tardó de media y cuántas fallaron.
    public struct Summary: Identifiable, Sendable, Equatable {
        public var id: String { endpoint }
        public let endpoint: String
        public let calls: Int
        public let failures: Int
        public let averageMilliseconds: Double
        public let averageFirstByteMilliseconds: Double?
        public let protocolName: String?
    }

    @ObservationIgnored private let lock = NSLock()
    public private(set) var reports: [MetricsReport] = []

    public init() {}

    public func record(_ report: MetricsReport) {
        lock.withLock { reports.append(report) }
    }

    public func clear() {
        lock.withLock { reports.removeAll() }
    }

    /// Un renglón por endpoint, ordenado por nombre.
    public var summaries: [Summary] {
        let reports = lock.withLock { self.reports }
        let groups = Dictionary(grouping: reports, by: \.request.endpoint)
        return groups.map { endpoint, reports in
            let firstBytes = reports.compactMap { $0.transport?.timeToFirstByte }
            return Summary(
                endpoint: endpoint,
                calls: reports.count,
                failures: reports.filter { !$0.succeeded }.count,
                averageMilliseconds: reports.map(\.elapsed).averageMilliseconds,
                averageFirstByteMilliseconds: firstBytes.isEmpty ? nil : firstBytes.averageMilliseconds,
                protocolName: reports.compactMap { $0.transport?.protocolName }.last
            )
        }
        .sorted { $0.endpoint < $1.endpoint }
    }
}

extension Array where Element == Duration {
    var averageMilliseconds: Double {
        guard !isEmpty else { return 0 }
        let total = reduce(0.0) { $0 + Double($1.components.seconds) * 1000 + Double($1.components.attoseconds) / 1e15 }
        return total / Double(count)
    }
}
