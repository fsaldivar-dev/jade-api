import Testing
@testable import LoginCore

@Suite("Entorno")
struct EnvironmentTests {

    @Test("Stage.resolve: argumento, variable de entorno y fallback, en ese orden", arguments: [
        (["--stage=prod"], ["JADE_STAGE": "dev"], Stage.prod),
        ([], ["JADE_STAGE": "dev"], Stage.dev),
        (["--stage=nope"], [:], Stage.mock),
        ([], [:], Stage.mock),
    ])
    func resolve(arguments: [String], environment: [String: String], expected: Stage) {
        #expect(Stage.resolve(arguments: arguments, environment: environment, fallback: .mock) == expected)
    }

    @Test("cada entorno declara los dos servicios")
    func services() {
        for stage in Stage.allCases {
            #expect(stage.servicesSummary.contains("auth →"))
            #expect(stage.servicesSummary.contains("catalog →"))
        }
    }

    @MainActor
    @Test("el contenedor se construye para todos los entornos sin tocar la red")
    func containerBuilds() throws {
        for stage in Stage.allCases {
            let app = try AppContainer(stage: stage)
            #expect(app.stage == stage)
        }
    }

    @MainActor
    @Test("cambiar de entorno reconstruye el contenedor y limpia el log")
    func shellRebuildsOnStageChange() {
        let log = CallLog()
        log.append("basura")
        let shell = AppShell(stage: .mock, log: log)
        shell.stage = .dev

        #expect(shell.container?.stage == .dev)
        #expect(log.entries.isEmpty)
    }
}
