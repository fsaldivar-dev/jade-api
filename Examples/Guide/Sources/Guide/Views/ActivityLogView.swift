import GuideCore
import SwiftUI

/// Lo que dejaron los decoradores (`→ login`, `← login ok`) y el `RequestLogger` del entorno.
struct ActivityLogView: View {
    let log: CallLog

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Log: @Logged · @Retry · RequestLogger").font(.caption)
                Spacer()
                Button("Limpiar") { log.clear() }.font(.caption).disabled(log.entries.isEmpty)
            }
            .padding(8)
            List(Array(log.entries.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }
}
