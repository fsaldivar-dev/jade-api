import GuideCore
import SwiftUI

/// Lo que recogió `MetricsInterceptor`, resumido por endpoint. Usa las otras pestañas y vuelve aquí.
struct MetricsView: View {
    let metrics: MetricsLog

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MetricsInterceptor { report in MetricsLog.current.record(report) } en la capa de entorno. elapsed incluye reintentos; ttfb y protocolo vienen de URLSessionTaskMetrics.")
                .font(.footnote).foregroundStyle(.secondary)
            Table(metrics.summaries) {
                TableColumn("Endpoint", value: \.endpoint)
                TableColumn("Llamadas") { Text("\($0.calls)") }
                TableColumn("Fallos") { Text("\($0.failures)") }
                TableColumn("Media") { Text(String(format: "%.0f ms", $0.averageMilliseconds)) }
                TableColumn("Primer byte") { Text($0.averageFirstByteMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—") }
                TableColumn("Protocolo") { Text($0.protocolName ?? "—") }
            }
            Button("Limpiar") { metrics.clear() }.disabled(metrics.reports.isEmpty)
        }
        .padding(.top, 8)
    }
}
