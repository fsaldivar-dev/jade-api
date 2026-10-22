import Testing
@testable import GuideCore

@Suite("Entorno y métricas")
struct EnvironmentTests {

    @Test("Stage.resolve: argumento, variable de entorno y fallback, en ese orden", arguments: [
        (["--stage=live"], ["JADE_STAGE": "mock"], Stage.live),
        ([], ["JADE_STAGE": "live"], Stage.live),
        (["--stage=nope"], [:], Stage.mock),
        ([], [:], Stage.mock),
    ])
    func resolve(arguments: [String], environment: [String: String], expected: Stage) {
        #expect(Stage.resolve(arguments: arguments, environment: environment, fallback: .mock) == expected)
    }

    @Test("cada entorno declara los cinco servicios")
    func services() {
        for stage in Stage.allCases {
            for service in ["auth", "catalog", "wiki", "photos", "echo"] {
                #expect(stage.servicesSummary.contains("\(service) →"))
            }
        }
    }

    @MainActor
    @Test("el contenedor se construye para los dos entornos sin tocar la red")
    func containerBuilds() throws {
        for stage in Stage.allCases {
            #expect(try AppContainer(stage: stage).stage == stage)
        }
    }

    @MainActor
    @Test("cambiar de entorno reconstruye el contenedor y limpia los logs")
    func shellRebuildsOnStageChange() {
        let log = CallLog(); log.append("basura")
        let metrics = MetricsLog()
        let shell = AppShell(stage: .mock, log: log, metrics: metrics)
        shell.stage = .live
        #expect(shell.container?.stage == .live)
        #expect(log.entries.isEmpty)
    }

    @MainActor
    @Test("MetricsLog resume por endpoint: llamadas, fallos y media")
    func metricsSummary() async throws {
        let app = try TestApp()
        await app.run {
            await app.session.signIn(username: "emilys", password: "mala")
            await app.session.signIn(username: "emilys", password: Fixtures.users["emilys"]!)
        }
        let login = try #require(app.metrics.summaries.first { $0.endpoint == "login(username:password:expiresInMins:)" })
        #expect(login.calls == 2)
        #expect(login.failures == 1)
        #expect(login.protocolName == "mock")
        #expect(app.metrics.summaries.contains { $0.endpoint == "me()" })
    }
}
