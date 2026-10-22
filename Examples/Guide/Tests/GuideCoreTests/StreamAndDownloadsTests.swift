import Foundation
import JadeAPI
import Testing
@testable import GuideCore

@MainActor
@Suite("Stream y descargas")
struct StreamAndDownloadsTests {

    @Test("el stream SSE entrega las ediciones decodificadas y parar lo deja detenido")
    func wikiStream() async throws {
        let app = try TestApp()
        let wiki = app.container.wiki
        wiki.start()
        let deadline = ContinuousClock.now + .seconds(3)
        while wiki.received < 4, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        wiki.stop()
        #expect(wiki.received == 4)
        #expect(wiki.changes.first?.title == "Macro")          // la más reciente primero
        #expect(wiki.changes.map(\.user).contains("Paco"))
        #expect(!wiki.isRunning)
        #expect(wiki.errorMessage == nil)
    }

    @Test("la cola descarga las cinco fotos con límite de dos y deja un archivo por semilla")
    func downloads() async throws {
        let app = try TestApp()
        let downloads = app.container.downloads
        await downloads.start()
        #expect(downloads.items.count == 5)
        #expect(downloads.items.allSatisfy { $0.file != nil && $0.error == nil })
        #expect(downloads.progress.completed == 5)
        let sizes = try downloads.items.compactMap(\.file).map { try Data(contentsOf: $0).count }
        #expect(sizes == [30_000, 40_000, 50_000, 60_000, 70_000])
        downloads.clear()
        #expect(downloads.items.isEmpty)
    }

    @Test("en mock no hay WebSocket: la pestaña muestra el error en vez de caerse")
    func socketUnsupported() async throws {
        let app = try TestApp()
        await app.container.echo.connect()
        #expect(app.container.echo.errorMessage?.contains("websocket") == true)
        #expect(!app.container.echo.isConnected)
    }
}
