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

> Estado: en diseño. Ver [docs/ROADMAP.md](docs/ROADMAP.md) para los alcances por iteración.

## Tres capas, una regla

| Si tocas… | Usa… | Ejemplo |
| --- | --- | --- |
| la llamada (argumentos, resultado, error de dominio) | **decorador** | `@Retry`, `@Cached`, `@Authenticated` |
| el HTTP crudo (headers, status, bytes) | **interceptor** | `AuthInterceptor` que refresca el token en 401 |
| los datos (DTO ↔ dominio, envelope, claves) | **transformador** | `@Transform(UserMapper.self)`, `@Unwrap("data")` |

Las tres siguen la misma forma: una función y un `next`.

## Por qué un protocolo

El repositorio es un contrato. La app depende de `UsersRepository`, no de `UsersRepositoryClient`,
así que cambiar de URLSession a Alamofire o a un mock no toca una sola vista:

```swift
let users: UsersRepository = UsersRepositoryClient(client: AppClient(stage: .mock, client: MockClient()
    .on(.get, "/users/:id") { _ in .json(#"{"id": 7, "name": "Paco"}"#) }))
```

## Requisitos

Swift 6.2 o superior (Xcode 26.1+). macOS 13, iOS 16, tvOS 16, watchOS 9, visionOS 1.

## Licencia

MIT. Ver [LICENSE.md](LICENSE.md).
