import Foundation
import JadeAPI
import Testing
@testable import GuideCore

/// Contra las APIs reales. Apagadas por defecto (red, CI): `JADE_LIVE=1 swift test --package-path Examples/Guide --filter Live`.
@MainActor
@Suite("Live: APIs reales", .enabled(if: ProcessInfo.processInfo.environment["JADE_LIVE"] == "1"), .serialized)
struct LiveSmokeTests {

    @Test("dummyjson: login, perfil y catálogo")
    func sessionAndCatalog() async throws {
        let app = try AppContainer(stage: .live)
        await app.session.signIn(username: "emilys", password: "emilyspass")
        guard case .signedIn(let profile) = app.session.status else { Issue.record(Comment(rawValue: app.session.errorMessage ?? "sin sesión")); return }
        #expect(profile.username == "emilys")

        await app.catalog.load()
        #expect(app.catalog.errorMessage == nil)
        #expect(app.catalog.featured.count == 6)
        #expect(!app.catalog.categories.isEmpty)
        guard case .failure(let error)? = app.catalog.details[9999] else { Issue.record("el 9999 debía fallar"); return }
        #expect((error as? CatalogError)?.description.contains("9999") == true)

        await app.catalog.search("phone")                 // @ApiRequest contra /products/search real
        #expect(!app.catalog.searchResults.isEmpty)
    }

    @Test("wikimedia: llegan ediciones por SSE y parar cierra")
    func wiki() async throws {
        let app = try AppContainer(stage: .live)
        app.wiki.start()
        let deadline = ContinuousClock.now + .seconds(20)
        while app.wiki.received < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        app.wiki.stop()
        #expect(app.wiki.received >= 3, Comment(rawValue: app.wiki.errorMessage ?? ""))
        #expect(app.wiki.changes.first?.title.isEmpty == false)
    }

    @Test("picsum: cinco fotos reales en cola")
    func downloads() async throws {
        let app = try AppContainer(stage: .live)
        await app.downloads.start()
        #expect(app.downloads.items.allSatisfy { $0.file != nil }, Comment(rawValue: app.downloads.items.compactMap(\.error).joined(separator: "; ")))
        #expect(app.downloads.progress.completed == 5)
        let sizes = try app.downloads.items.compactMap(\.file).map { try Data(contentsOf: $0).count }
        #expect(sizes.allSatisfy { $0 > 10_000 })
        app.downloads.clear()
    }

    @Test("echo.websocket.org: eco, reconexión forzada y cierre")
    func echo() async throws {
        let app = try AppContainer(stage: .live)
        await app.echo.connect()
        #expect(app.echo.isConnected, Comment(rawValue: app.echo.errorMessage ?? ""))
        await app.echo.send("hola jade")
        try await waitUntil(.seconds(10)) { app.echo.received.contains("hola jade") }
        #expect(app.echo.received.contains("hola jade"))

        app.echo.forceReconnect()
        try await waitUntil(.seconds(15)) { app.echo.status.hasPrefix("reconectado") }
        #expect(app.echo.status.hasPrefix("reconectado"), Comment(rawValue: app.echo.events.joined(separator: " | ")))
        await app.echo.send("otra vez")
        try await waitUntil(.seconds(10)) { app.echo.received.contains("otra vez") }
        #expect(app.echo.received.contains("otra vez"))
        app.echo.disconnect()
        #expect(!app.echo.isConnected)
    }

    private func waitUntil(_ timeout: Duration, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
    }
}
