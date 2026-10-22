# JadeAPI

**Declara tu API con anotaciones; Jade la ejecuta.**

```swift
@Repository
protocol UsersRepository {
    @Retry(3)
    @Api("/users/:id")
    func getUser(id: Int) async throws -> User
}

let users: UsersRepository = UsersRepositoryClient(client: AppClient(baseURL: "https://api.ejemplo.com"))
let paco = try await users.getUser(id: 7)        // GET /users/7, con tres reintentos
```

Retrofit para Swift, con una diferencia: la política de cada endpoint (`@Retry`, `@Cached`,
`@Authenticated`, `@Logged`) se apila sobre el mismo método y la escribe quien usa la librería.
Está construida sobre [AnnotationSwift](https://github.com/fsaldivar-dev/experimental-annotation-swift).

> Estado: iteración 1 (declarar y llamar). Ver [docs/ROADMAP.md](docs/ROADMAP.md).

## Quick Start

**1. Dependencia** (Swift 6.2+). Mientras no haya release, por rama:

```swift
.package(url: "https://github.com/fsaldivar-dev/jade-api.git", branch: "main")
// target: .product(name: "JadeAPI", package: "jade-api")
```

**2. Declara el repositorio.** Un `protocol` `Sendable`; cada endpoint es un requisito `async throws` con `@Api`:

```swift
import JadeAPI

struct LoginForm: Decodable { let fields: [String] }
struct Token: Decodable { let value: String }

@Repository
protocol LoginRepository: Sendable {
    @Api func getLogin() async throws -> LoginForm                      // GET /login (inferido)
    @Api("/auth", method: .post)
    func auth(user: String, password: String) async throws -> Token     // POST /auth, body {user, password}
}
```

**3. Crea el cliente y la implementación.** `@Repository` generó `LoginRepositoryClient`:

```swift
let client = AppClient(baseURL: "https://api.ejemplo.com")
let login: LoginRepository = LoginRepositoryClient(client: client)
```

**4. Llama.** La llamada *es* la petición:

```swift
let form = try await login.getLogin()
let token = try await login.auth(user: "paco", password: "secreto")
```

## Declarar

### Verbo y ruta

| Declaración | Petición |
| --- | --- |
| `@Api("/users/:id") func user(id: Int)` | `GET /users/7` |
| `@Api("/auth", method: .post) func auth(user:password:)` | `POST /auth` con body `{"user":…,"password":…}` |
| `@Api func getUser(id: Int)` | `GET /user?id=7` (inferido; avisa que `id` va como query) |
| `@Api func postRefresh(token: String)` | `POST /refresh` con body `{"token":…}` |
| `@Api func deleteSession(id: Int)` | `DELETE /session?id=…` |
| `@Api func getUserProfile()` | `GET /user-profile` |

Prefijos que infieren verbo: `get`, `fetch`, `find`, `list`, `load` → GET · `post`, `create`, `add`, `send` → POST · `put`, `replace` → PUT · `patch`, `update` → PATCH · `delete`, `remove` → DELETE. Sin prefijo, GET. **La ruta explícita es la recomendación**; la inferencia es azúcar para prototipos y el compilador avisa cuando un parámetro podría ser de ruta.

### Parámetros

- `:nombre` en la ruta se rellena con el parámetro del mismo nombre.
- El resto va a la **query** en GET/DELETE y al **body JSON** (un campo por parámetro) en POST/PUT/PATCH.
- `nil` se omite de la query.
- Para forzar: `Path<T>`, `Query<T>`, `Header<T>` (el nombre del header es la etiqueta) y `Body<T>` (el parámetro completo es el body).

```swift
@Api("/users/search")
func search(q: String, page: Int?, limit: Query<Int>) async throws -> [User]   // ?q=…&limit=…

@Api("/me")
func me(token: Header<String>) async throws -> Profile                           // header "token: …"

@Api("/auth/login", method: .post)
func login(credentials: Body<Credentials>) async throws -> Token                 // body = credentials
```

### Retorno

`Decodable` (JSON), `Data`, `String`, `Void` o `Response` (status, headers, body crudos). Cualquier status fuera de 2xx lanza `HTTPError.status(code, response)`.

## Cliente y entornos

```swift
enum Stage: String, StageProtocol {
    case dev, prod, mock
    var baseURL: URL { … }
    var transport: any HTTPClient { self == .mock ? Fixtures.client : URLSessionClient() }
}

let stage = Stage.resolve(fallback: .prod)      // --stage=dev, JADE_STAGE=dev, o el fallback
let client = AppClient(stage: stage)
```

`AppClient` reúne base, `JSONDecoder`/`JSONEncoder`, headers comunes, timeout y transporte. Cambiar de entorno cambia el `AppClient`; los repositorios no se tocan.

## Probar sin red

```swift
let mock = MockClient()
    .on(.get, "/users/:id") { request in .json(#"{"id": 7, "name": "Paco"}"#) }
    .on(.post, "/auth") { request in request.body == nil ? .status(400) : .json(#"{"value": "t"}"#) }

let users: UsersRepository = UsersRepositoryClient(client: AppClient(baseURL: "https://mock.local", transport: mock))
#expect(try await users.user(id: 7).name == "Paco")
#expect(mock.received.first?.path == "/users/7")
```

Como el repositorio es un protocolo, también puedes escribir un mock a mano y no tocar ni la red ni la macro.

## Decoradores sobre endpoints

Cualquier decorador de AnnotationSwift se apila sobre un requisito y se aplica al método generado. Márcalo `@Annotation` y activa el plugin `AnnotationRegistry` en tu target para no declarar nada a mano:

```swift
@Annotation
struct Retry: Decorator { … }

@Repository
protocol UsersRepository {
    @Retry(3)
    @Logged
    @Api("/users/:id/flaky")
    func flaky(id: Int) async throws -> User
}
```

Orden de arriba abajo: `Retry` envuelve a `Logged`, que envuelve la petición. Sin el plugin, declara el marcador (`@attached(peer) macro Retry(_ attempts: Int) = #externalMacro(module: "AnnotationMacros", type: "MarkerMacro")`) o usa `@Decorate(Retry(3), Logged())`. Los decoradores de red incluidos (`@Retry` consciente de idempotencia, `@Timeout`, `@Cached`, `@SingleFlight`) llegan en la iteración 2.

## Concurrencia

Declara los repositorios como `protocol X: Sendable`. El cliente generado es `Sendable` (solo guarda un `AppClient`), y así el existencial `any X` puede vivir en un `@MainActor` y llamarse desde cualquier aislamiento. Las llamadas corren en el aislamiento de quien llama.

## Errores

`HTTPError` es un enum: `invalidURL`, `encoding`, `transport`, `status(Int, Response)`, `decoding(Error, Response)`, `unmocked(Request)`, `cancelled`. Cancelar la `Task` cancela la petición.

## Ejemplo

[`Examples/Login`](Examples/Login): app SwiftUI con selector de entorno (dev, prod, mock), login con repositorios declarados, `@Logged @Retry(2)` registrados con `@Annotation` y el plugin, y panel con lo que hicieron los decoradores.

```bash
swift run --package-path Examples/Login
```

## Cómo funciona

`@Repository` genera `struct <Nombre>Client: <Nombre>, Sendable` marcado `@Decorable`, con `init(client:)` y un método por requisito que arma un `Endpoint` y llama a `AppClient`. Los atributos del requisito, menos `@Api`, se copian al método generado; a partir de ahí AnnotationSwift envuelve la pila como en cualquier función. El cuerpo generado para `@Api("/users/:id") func user(id: Int)`:

```swift
public func user(id: Int) async throws -> User {
    var __headers: [String: String] = [:]
    let __endpoint = JadeAPI.Endpoint(name: "user(id:)", method: .get, path: "/users/:id",
                                      pathParameters: ["id": JadeAPI.ParameterValue.text(id) ?? ""],
                                      query: [], headers: __headers, body: nil)
    return try await client.perform(__endpoint)
}
```

Tres capas, una regla, para lo que viene: **interceptor** si tocas HTTP, **decorador** si tocas la llamada, **transformador** si tocas datos.

## Requisitos

Swift 6.2 o superior (Xcode 26.1+). macOS 13, iOS 16, tvOS 16, watchOS 9, visionOS 1.

## Licencia

MIT. Ver [LICENSE.md](LICENSE.md).
