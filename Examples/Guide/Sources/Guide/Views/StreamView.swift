import GuideCore
import SwiftUI

/// Ediciones de Wikipedia en vivo. Iniciar abre el stream SSE; detener cancela la Task y cierra la conexión.
struct StreamView: View {
    let wiki: WikiStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if wiki.isRunning {
                    Button("Detener") { wiki.stop() }
                } else {
                    Button("Iniciar stream") { wiki.start() }.buttonStyle(.borderedProminent)
                }
                Text("\(wiki.received) eventos recibidos").font(.caption).foregroundStyle(.secondary)
            }
            Text("kind: .sse → for try await event in wiki.recentChanges(). En live es stream.wikimedia.org; en mock, cuatro ediciones.")
                .font(.footnote).foregroundStyle(.secondary)
            List(wiki.changes) { change in
                HStack {
                    Text(change.type).font(.caption.monospaced()).frame(width: 70, alignment: .leading)
                    Text(change.title).lineLimit(1)
                    Spacer()
                    Text("\(change.user) · \(change.wiki)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = wiki.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(.top, 8)
        .onDisappear { wiki.stop() }
    }
}
