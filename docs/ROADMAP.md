# JadeAPI · Alcances por iteración

Declara tu API con anotaciones; Jade la ejecuta. Construida sobre
[AnnotationSwift](https://github.com/fsaldivar-dev/experimental-annotation-swift): los decoradores
que apilas sobre un endpoint son los mismos que apilas sobre cualquier función.

Cada iteración termina en un release etiquetado, con tests, documentación y un ejemplo que la use.
Lo que no está en la iteración no se empieza aunque sea fácil: la superficie de la librería es su
mayor costo cognitivo (ver [Decisiones](#decisiones-de-diseño)).

---

## Iteración 0 · Cimientos — hecho

**Objetivo:** que un marcador pueda vivir dentro de un `protocol` y que el repo compile contra el núcleo.

| Entregable | Dónde |
| --- | --- |
| AnnotationSwift `1.0.2`: un marcador dentro de un `protocol` es inerte (otra macro lo transcribe) en vez de error | experimental-annotation-swift |
| Spike: una macro que genera un `struct` con `@Decorable` y marcadores, y éstos se expanden a su vez | scratch |
| Esqueleto de `jade-api`: `Package.swift` sobre `1.0.2`, target de macros, CI, DocC vacía | este repo |

**Hecho cuando:** `swift test` pasa aquí y en el núcleo; el spike demuestra la expansión anidada.

---

## Iteración 1 · Declarar y llamar (v0.1, MVP) — hecho

**Objetivo:** la primera petición en cuatro pasos y veinte líneas. Sin interceptores ni transformadores visibles.

```swift
@Repository
protocol LoginRepository {
    @Api func getLogin() async throws -> LoginForm                    // GET /login
    @Api("/auth", method: .post)
    func auth(user: String, password: String) async throws -> Token   // POST /auth, body JSON
}

let login: LoginRepository = LoginRepositoryClient(client: AppClient(baseURL: "https://api.ejemplo.com"))
let token = try await login.auth(user: "paco", password: "secreto")
```

### Declaración
- `@Repository` sobre un `protocol` genera `<Nombre>Client: <Nombre>` con `init(client:)`, marcado `@Decorable`.
- Los decoradores del usuario sobre un requisito se copian al método generado; AnnotationSwift los envuelve.
- `@Api` infiere verbo y ruta del nombre (`getLogin` → `GET /login`, `postUser` → `POST /user`, `deleteSession(id:)` → `DELETE /session/:id`). Prefijos: get, post, put, patch, delete, fetch, create, update, remove.
- `@Api("/ruta", method: .post)`: el string manda. Documentación recomienda explícito; la inferencia es azúcar.
- Diagnóstico cuando la inferencia pone un parámetro en query y podría ser path.

### Parámetros
- Path: `:id` en la ruta ↔ parámetro `id`. Falta uno → error de compilación.
- Defaults por verbo: query en GET/DELETE, body JSON en POST/PUT/PATCH.
- Tipos explícitos: `Path<T>`, `Query<T>`, `Header<T>`, `Body<T>`.

### Respuesta
- Retorno `Decodable`, `Data`, `String`, `Void`, `Response` (status, headers, body).
- 2xx ok; el resto lanza `HTTPError.status(code, body, request)`.
- `HTTPError` tipado: `transport`, `status`, `decoding`, `cancelled`, `invalidURL`.

### Cliente y entornos
- `HTTPClient`: `func send(_ request: Request) async throws -> Response`. Backend URLSession.
- `AppClient(baseURL:decoder:encoder:headers:timeout:)`.
- `Stage` enum del usuario conformando `StageProtocol` (`baseURL`, `client`), con `.mock`.
- Selección de `Stage` por argumento de lanzamiento, variable de entorno o código.
- Headers comunes (`Accept`, `Content-Type`, `User-Agent`).

### Testing
- `MockClient`: `.on(.get, "/users/:id") { request in .json(...) }`, status y headers configurables, registro de peticiones recibidas.
- Cancelación cooperativa: cancelar la `Task` cancela la petición.

### Calidad
- Diagnósticos: `@Api` fuera de `@Repository`; requisito no `async throws`; retorno no soportado; `:id` sin argumento.
- Tests de expansión de macros y end-to-end contra `MockClient`.
- Ejemplo `Examples/Login`: pantalla de login con `Stage` y mock.
- CI Swift 6.2 y 6.3; DocC con Quick Start.

**Fuera de alcance:** interceptores, transformadores, decoradores de red, grupos, streams, Alamofire.

---

## Iteración 2 · El pipeline (v0.2) — hecho

**Objetivo:** las tres capas con una regla de bolsillo: *interceptor si tocas HTTP, decorador si tocas la llamada, transformador si tocas datos*.

**Cómo quedó:** los "decoradores de red" (`@Retry`, `@Timeout`, `@Cached`, `@SingleFlight`) se
implementaron como **opciones de petición** (`@Retries`, `@Api(timeout:)`, `@CacheFor`, `@SingleFlight`)
que aplica el cliente, no como `Decorator` genéricos: un decorador no puede cancelar ni compartir
un `Out` no `Sendable`, y esas políticas pertenecen al HTTP. `@Intercept` por endpoint quedó fuera,
como estaba previsto. `@KeyMapping` se resuelve con el `JSONDecoder` del cliente. Nombres con prefijo
distinto (`@Retries`, `@CacheFor`) para no chocar con decoradores del usuario llamados `Retry` o `Cached`.

### Interceptores
- `Interceptor`: `intercept(_ request: Request, next: (Request) async throws -> Response) async throws -> Response`.
- Atajos `RequestAdapter` (antes) y `ResponseInterceptor` (después).
- Cadena en `AppClient(interceptors:)`; orden documentado y probado: cliente → repositorio → endpoint → red.
- `@Interceptors(Auth.self)` a nivel de protocolo.
- Incluidos: `AuthInterceptor` (`TokenProvider`, refresh único en 401 con cola, reintento), `CommonHeaders`, `Logger(.curl, redacting:)`, `RetryTransport` (errores de red y 5xx idempotentes, backoff, `Retry-After`), `MetricsInterceptor`, `MockInterceptor`.
- Streams y sockets: solo fase de petición.

### Transformadores
- `Transformer`: `associatedtype Input: Decodable`, `Output`; `transform(Input) throws -> Output`.
- `@Transform(UserMapper.self)` por endpoint; verificado en compilación contra el retorno.
- `@Unwrap("data")` y `@Envelope(APIEnvelope.self)` por repositorio o endpoint.
- `@KeyMapping(.snakeCase)` y estrategia de fechas por cliente y por repositorio.
- `@ErrorTransform(APIErrorMapper.self)`: body de error → error de dominio.
- Codificadores: URL-form y multipart (`Body<FileUpload>`), `ConverterFactory` por `Content-Type`.
- Orden de encadenado: de afuera hacia adentro, como los decoradores.
- Adaptador de retorno `Result<T, HTTPError>`.

### Decoradores de red incluidos
- `@Retry(n, backoff:)` consciente de idempotencia y de 4xx vs red.
- `@Timeout(.seconds(n))`.
- `@Cached(ttl:)` en memoria por ruta y parámetros.
- `@SingleFlight`: llamadas idénticas en vuelo comparten una petición.
- `@Authenticated`: guardián de sesión (lanza si no hay token).

### Grupos de peticiones
- `client.group(maxConcurrent:onFailure:) { group in group.add { … } }` → `[T]` en orden; políticas `failFast` (default), `collect`, `tolerate(n)`.
- Forma heterogénea con parameter packs: `group(maxConcurrent:, { a }, { b }, { c })` → `(A, B, C)`.
- Progreso agregado (`AsyncStream<Progress>`), cancelación estructurada, prioridad por elemento.
- Documentado: para dos o tres distintas sin límite, `async let`.

### Calidad
- Ejemplo `Examples/Catalog`: pantalla que carga tres endpoints en grupo, con auth, cache y mapper.
- Advertencia de compilación para pilas invertidas evidentes (`@Retry` dentro de `@Timeout`).

**Fuera de alcance:** `@Intercept` por endpoint (se confunde con decorador), streams, sockets, Alamofire.

---

## Niveles (acordado tras la iteración 2)

La librería se presenta por tamaño de app, con *progressive disclosure*: quien está en un nivel no ve
los conceptos del siguiente.

- **Nivel 1 · un dominio** — hecho. `@Repository`, `@Api`, `AppClient`, `MockClient` y defaults seguros:
  solo HTTPS fuera de Debug, `@Retries` exige `@Idempotent` en POST/PATCH, logger mudo en release,
  `JadeTesting` aparte, aviso de secretos fijos.
- **Nivel 2 · varios dominios** — hecho. `@Repository(service:)`, `Environment` desde `.xcconfig` +
  Info.plist (el estándar de Xcode; se descartó un archivo de configuración propio), capas
  entorno → servicio → repositorio → endpoint, overrides solo en Debug, mocks por servicio.
- **Nivel 3 · big app** — seguridad hecha: `KeychainTokenProvider`, pinning con respaldo y caducidad,
  DPoP, firmas RFC 9421, App Attest, login OIDC (discovery, PAR, PKCE, DPoP) y `SECURITY.md` con el
  mapeo MASVS. Pendientes: mTLS, métricas de transporte, reconexión de sockets, y el generador desde OpenAPI.

La iteración 3 de transporte se construye después del nivel 2 y antes del nivel 3.

## Iteración 3 · Transporte avanzado (v0.3) — hecho salvo pinning y métricas

**Objetivo:** cuatro familias de retorno: valor, stream, transferencia, conexión. Una sola palabra para elegirla.

**Cómo quedó:** `@Api(kind:)` con `.bytes/.lines/.ndjson/.sse/.download/.upload` y `@Socket` para la
conexión. Sin reconexión automática de sockets ni long polling (pendientes de una política de
resiliencia). Pinning y métricas pasan al nivel 3, junto al resto de seguridad bancaria. Las pruebas
de WebSocket corren contra `LocalWebSocketServer` (Network.framework) en `JadeTesting`; no hay servidor
HTTP local para descargas: se prueban con el transporte simulado de `MockClient`.

- `@Api(..., kind: .stream)` → `AsyncThrowingStream<Data, Error>`; `.stream(.lines)`, `.stream(.ndjson(Chunk.self))`, `.sse` → `AsyncThrowingStream<ServerEvent, Error>`.
- `@Api(..., kind: .download)` → `Download` (progreso, `url` final, reanudable por `Range`, background session).
- `@Api(..., kind: .upload)` → `Upload` (multipart y archivo con progreso, background).
- `@Socket("/ws/chat/:room")` → `Socket<Outgoing, Incoming>`: `send`, `messages` como `AsyncStream`, ping, reconexión con backoff.
- `DownloadQueue(maxConcurrent:)`: cola de descargas con pausa, reanudación y persistencia entre lanzamientos.
- Semántica de decoradores sobre streams y sockets documentada: `@Retry` reintenta la conexión, `@Timeout` es tiempo de conexión.
- SSL pinning por certificado y clave pública, lista por host, por `Stage`; URLSession vía delegate.
- Métricas de transporte (`URLSessionTaskMetrics`) en `Response.metrics` y accesibles desde `Call`.
- Diagnóstico cuando el `kind` no cuadra con el tipo de retorno.
- Ejemplo `Examples/Media`: descargas en cola con progreso y un chat por WebSocket contra un servidor local de prueba.

**Fuera de alcance:** long polling, cola offline, HTTP cache por ETag, GraphQL.

---

## Iteración 4 · Backends y ergonomía (v0.4)

- Backend Alamofire: adaptador que recibe una `Session` y respeta sus interceptores, retriers, `ServerTrustManager` y descargas con progreso. Sin WebSocket (no lo soporta).
- Traducción opcional de nuestros interceptores a `RequestAdapter`/`RequestRetrier` nativos.
- `@Mock` genera `<Nombre>Mock: <Nombre>` con closures por endpoint.
- Segunda etiqueta como clave (`func post(id postId: Int)`), `@Headers` estáticos, `@BaseURL("/v2")` por protocolo.
- Pinning con rotación y expiración.
- Integración con Pulse para inspección de tráfico.
- Ejemplo `Examples/Alamofire`: misma app de catálogo con `Session` configurada por el usuario.

---

## Ideas (sin iteración)

Long polling · cola offline con reintento al volver la red · caché HTTP (ETag) · compresión de body ·
cassettes de grabación y reproducción · `@Paginated(cursor:)` → `Pages<Item>` · adaptador Combine ·
batch del servidor con ventana de tiempo · AsyncHTTPClient para Linux · métricas de grupo · GraphQL.

---

## Decisiones de diseño

1. **El núcleo no sabe de HTTP.** JadeAPI consume AnnotationSwift; cualquier cambio allí es genérico (1.0.2: marcadores inertes en protocolos).
2. **`@Repository` escribe el cuerpo**, no hace falta soporte de funciones sin cuerpo en el núcleo.
3. **Protocolo como contrato**: mocks e inyección sin tocar vistas; cambiar de backend no toca repositorios.
4. **Mapper como tipo, no closure**: el compilador verifica DTO ↔ dominio ↔ retorno.
5. **Inferencia por nombre existe, pero la ruta explícita es la recomendación.** La magia no debe ser la única forma.
6. **La concurrencia es de quien llama**, no de quien declara: grupos en runtime, sin `@Parallel`.
7. **Una palabra para la familia de retorno** (`kind:`) en vez de cuatro marcadores.
8. **Progressive disclosure en la documentación**: nadie ve interceptores ni transformadores hasta que los necesita.
9. **Delegar al backend** lo que ya resuelve: multipart, pinning, caché HTTP.

## Complejidad cognitiva (referencia)

| Tarea | 1–5 |
| --- | --- |
| Primera petición GET | 1 |
| POST con body y auth global | 2 |
| Entornos y mocks | 2 |
| Mapper DTO → dominio | 2 |
| Elegir entre decorador, interceptor y transformador | 4 |
| Orden de apilado correcto | 3 |
| Streams y sockets | 3 |
| Escribir un backend | 4 |
