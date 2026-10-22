import GuideCore
import SwiftUI

/// Eco por WebSocket con reconexión: escribe, vuelve. "Forzar reconexión" muestra los eventos de la política.
struct SocketView: View {
    let echo: EchoStore
    @State private var text = "hola"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if echo.isConnected {
                    Button("Desconectar") { echo.disconnect() }
                    Button("Forzar reconexión") { echo.forceReconnect() }
                } else {
                    Button("Conectar") { Task { await echo.connect() } }.buttonStyle(.borderedProminent)
                }
                Text(echo.status).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text("@Socket(\"/\", reconnect: .exponential(.seconds(1), max: .seconds(15)), keepAlive: .seconds(20)). En live es echo.websocket.org; en mock no hay WebSocket.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                TextField("Mensaje", text: $text).onSubmit { Task { await echo.send(text) } }
                Button("Enviar") { Task { await echo.send(text) } }.disabled(!echo.isConnected)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Text("Recibido").font(.caption).foregroundStyle(.secondary)
                    List(Array(echo.received.enumerated()), id: \.offset) { _, line in Text(line).font(.caption) }
                }
                VStack(alignment: .leading) {
                    Text("Eventos de la conexión").font(.caption).foregroundStyle(.secondary)
                    List(Array(echo.events.enumerated()), id: \.offset) { _, line in Text(line).font(.caption.monospaced()) }
                }
            }
            if let error = echo.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(.top, 8)
    }
}
