import LoginCore
import SwiftUI

/// Lo que dejaron los decoradores (`→ login`, `← login ok`) y el `RequestLogger` del entorno.
struct ActivityLogView: View {
    let log: CallLog

    var body: some View {
        List(Array(log.entries.enumerated()), id: \.offset) { _, line in
            Text(line).font(.caption.monospaced())
        }
        .overlay(alignment: .top) {
            Text("Decoradores: @Logged · @Retry(2) · RequestLogger")
                .font(.caption)
                .padding(4)
        }
    }
}
