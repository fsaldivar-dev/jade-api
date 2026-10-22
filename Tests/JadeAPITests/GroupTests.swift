import Foundation
import JadeAPI
import Testing

@Suite("Grupos de peticiones")
struct GroupTests {

    let mock = MockClient()
    var client: AppClient { AppClient(baseURL: "https://api.ejemplo.com", transport: mock) }
    var users: UsersRepository { UsersRepositoryClient(client: client) }

    @Test("Homogéneo: resultados en el orden de alta y límite de concurrencia respetado")
    func orderedWithLimit() async throws {
        let meter = ConcurrencyMeter()
        mock.latency = .milliseconds(40)
        mock.on(.get, "/users/:id") { request in
            meter.enter(); defer { meter.exit() }
            let id = request.path.split(separator: "/").last!
            Thread.sleep(forTimeInterval: 0.02)
            return .json(#"{"id": \#(id), "name": "u\#(id)"}"#)
        }
        let repo = users
        let ids = Array(1...8)
        let result = try await client.group(maxConcurrent: 3) { group in
            for id in ids { group.add { try await repo.user(id: id) } }
        }
        #expect(result.map(\.id) == ids)
        #expect(meter.peak <= 3)
        #expect(mock.received.count == 8)
    }

    @Test("Fail-fast: la primera que falla cancela lo pendiente y lanza")
    func failFast() async throws {
        mock.latency = .milliseconds(30)
        mock.on(.get, "/users/:id") { request in
            request.path == "/users/2" ? .status(500) : .json(#"{"id": 1, "name": "x"}"#)
        }
        let repo = users
        await #expect(throws: HTTPError.self) {
            try await self.client.group(maxConcurrent: 2) { group in
                for id in 1...10 { group.add { try await repo.user(id: id) } }
            }
        }
        #expect(mock.received.count < 10)
    }

    @Test("Settled: nunca lanza; un Result por operación, en orden, con progreso")
    func settled() async throws {
        mock.on(.get, "/users/:id") { request in
            request.path == "/users/2" ? .status(404) : .json(#"{"id": 1, "name": "x"}"#)
        }
        let repo = users
        let seen = Counter()
        let results = await client.groupSettled(maxConcurrent: 2, progress: { _ in _ = seen.increment() }) { group in
            for id in 1...3 { group.add { try await repo.user(id: id) } }
        }
        #expect(results.count == 3)
        #expect((try? results[0].get()) != nil)
        #expect((try? results[1].get()) == nil)
        #expect((try? results[2].get()) != nil)
        #expect(seen.increment() == 4)   // 3 avisos de progreso + este
    }

    @Test("Heterogéneo: tupla tipada con all(…)")
    func heterogeneous() async throws {
        mock.on(.get, "/users/:id") { _ in .json(#"{"id": 7, "name": "Paco"}"#) }
        mock.on(.get, "/users/:id/bio") { _ in MockResponse(body: Data("hola".utf8)) }
        mock.on(.get, "/users/:id/avatar") { _ in MockResponse(body: Data([9])) }
        let repo = users
        let (user, bio, avatar) = try await client.all(
            { try await repo.user(id: 7) },
            { try await repo.bio(id: 7) },
            { try await repo.avatar(id: 7) }
        )
        #expect(user.name == "Paco")
        #expect(bio == "hola")
        #expect(avatar == Data([9]))
        #expect(mock.received.count == 3)
    }

    @Test("Heterogéneo: si una falla, las demás se cancelan")
    func heterogeneousFailure() async throws {
        let fast = MockClient()
        fast.on(.get, "/users/:id") { _ in .status(500) }
        let slow = MockClient()
        slow.latency = .milliseconds(400)
        slow.on(.get, "/users/:id/bio") { _ in MockResponse(body: Data("tarde".utf8)) }
        let failing: UsersRepository = UsersRepositoryClient(client: AppClient(baseURL: "https://a.local", transport: fast))
        let lagging: UsersRepository = UsersRepositoryClient(client: AppClient(baseURL: "https://b.local", transport: slow))

        let start = ContinuousClock.now
        await #expect(throws: HTTPError.self) {
            _ = try await self.client.all({ try await failing.user(id: 1) }, { try await lagging.bio(id: 1) })
        }
        #expect(ContinuousClock.now - start < .milliseconds(300))   // no esperó los 400 ms de la lenta
    }

    @Test("Grupo vacío devuelve lista vacía")
    func empty() async throws {
        let result: [User] = try await client.group { _ in }
        #expect(result.isEmpty)
    }
}
