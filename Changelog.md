# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.10.0] - 2026-10-22
### Added
- Guardián de sesión: `@Authenticated` (sobre el protocolo o un endpoint) marca el endpoint con
  `requiresAuth`, y `AuthInterceptor` corta con `HTTPError.unauthenticated` antes de tocar la red si no
  hay token. `@Public` exime a un endpoint del guardián del protocolo. Nuevo `RequestOptions.requiresAuth`.
- `Examples/Guide`: el catálogo es `@Authenticated`; sin sesión, cargarlo corta sin red.

## [0.9.0] - 2026-10-22
### Added
- Objetos de petición: `@ApiRequest` sobre un `struct` lo convierte en el único parámetro de un `@Api`,
  con sus campos desplegados. `@Parameter` (o un campo pelón) infiere query/body por el verbo; `Path<T>`,
  `Query<T>`, `Header<T>` y `Body<T>` colocan el campo explícitamente. Nuevo protocolo `ApiRequest` y
  `ApiRequestInputs`. Un parámetro suelto de un tipo no primitivo se trata como objeto de petición.
- `Examples/Guide`: el catálogo gana un buscador que usa `ProductQuery` (`@ApiRequest`) contra
  `/products/search` de dummyjson.

## [0.8.0] - 2026-10-22
### Added
- `Socket.reconnect()`: cierra la conexión actual y deja que la política abra otra (volver de segundo plano,
  cambio de red). `QueueProgress.init` público y `QueueProgress.empty`.
- `Examples/Guide` sustituye a `Examples/Login`: una pestaña por pieza contra APIs públicas reales
  (dummyjson, Wikimedia SSE, picsum, echo.websocket.org) o un servidor falso; entornos `live` y `mock`
  con cinco servicios; `MetricsLog` con `MetricsInterceptor`; 17 pruebas sin red y 4 opt-in contra las
  APIs reales (`JADE_LIVE=1`).

## [0.7.0] - 2026-10-22
### Added
- Métricas de transporte: `TransportMetrics` en `Response.metrics` (de `URLSessionTaskMetrics`; sintéticas
  en `MockClient`), `Response.attempts`, `StreamingResponse.metrics` (`MetricsFuture`, resuelve al terminar),
  `MetricsInterceptor` con `MetricsReport` redactado, y duración/primer byte/protocolo en `RequestLogger`.
- Reconexión de sockets: `@Socket(path, reconnect:, maxReconnects:, keepAlive:)` → `SocketPolicy` en
  `RequestOptions.socket`; `Socket.events` (`SocketEvent`), `isConnected`, `SocketDisconnected` al enviar
  sin conexión; cada reconexión repite el handshake por los adaptadores; `Socket.shouldReconnect(after:)`
  documenta qué códigos reconectan. Un handshake rechazado con status llega como `HTTPError.status`.
- `LocalWebSocketServer.dropConnections()` y `acceptedConnections` para probar caídas.
- `RetryPolicy.Backoff.delay(forAttempt:)` público.

## [0.6.0] - 2026-10-22
### Added
- `@Headers([:])` sobre el protocolo (todos los endpoints) o sobre un requisito; prioridad endpoint →
  repositorio → cliente. Avisa en Debug si fija una credencial.
- `@BaseURL("/v2")` como prefijo sobre la base del cliente o del servicio, o una URL completa que la sustituye.
- `@KeyMapping(.snakeCase, dates: .iso8601)` por repositorio: copia los codificadores del cliente con la
  estrategia nueva. `KeyMapping`, `DateMapping` y `AppClient.with(base:)`, `with(headers:)`, `with(keys:dates:)`.
- Catálogo DocC con Quick Start, niveles y temas por capa (`swift package generate-documentation`).

### Changed
- `docs/ROADMAP.md` dice lo que hay: lo que cada iteración prometió y no se construyó está en una lista de
  deuda, y el estado de cada bloque refleja el código.
- README: dependencia por versión (`from: "0.5.0"`), sin referencias a `@Cached`/`@Authenticated`.

## [0.5.0] - 2026-10-22
### Added
- Login OIDC al estilo FAPI 2.0: `OpenIDDiscovery` (issuer verificado, endpoints https, PKCE S256
  obligatorio), `PKCE`, `AuthorizationFlow` con PAR cuando el servidor lo ofrece, navegador del sistema
  (`WebAuthenticationPresenter` sobre `ASWebAuthenticationSession`, `AuthorizationPresenter` para dobles),
  intercambio del código con prueba DPoP, comprobación de claims del `id_token`, `refresh(_:)`.
- `FormBody`: bodies `application/x-www-form-urlencoded`.

### Changed
- `Examples/Login` reorganizado por capas en un target `LoginCore` (dominio, red, entorno, features, raíz de
  composición) más la app SwiftUI, sin `try!` ni singletons, con pruebas propias (`swift test --package-path
  Examples/Login`) y README.
- `MockClient` elige la ruta más específica (`/catalog/featured` gana a `/catalog/:id` sin importar el orden
  de registro); entre igual de específicas, la última registrada.

### Fixed
- `AuthInterceptor` ya no intenta refrescar el token tras un 401 cuando la petición salió sin token: un
  login con credenciales malas devuelve su `HTTPError.status(401, …)` en vez del error del refresh.
- Tests con reloj robustos en runners lentos (la CI estaba en rojo desde la iteración 2 por un límite
  de 450 ms en el test de timeout).

## [0.4.0] - 2026-10-21
Nivel 3: seguridad bancaria.

### Added
- `KeychainStore` (`SecItemKeychainStore` con `ThisDeviceOnly` y `biometryCurrentSet`; `InMemoryKeychainStore`),
  `StoredTokens`, `KeychainTokenProvider` (refresca al caducar; se integra con `AuthInterceptor`).
- Pinning: `PublicKeyPin` (SHA-256 del SPKI, RSA 2048/4096 y EC P-256/P-384), `PinningPolicy` con respaldo,
  caducidad y subdominios, `PinnedSessionDelegate`, `URLSessionClient.pinned`, `pins`/`pinsExpire` por
  servicio en el Info.plist y transporte con pinning automático en `Environment.client(for:)`.
- DPoP (RFC 9449): `SigningKey`, `P256SigningKey` (Secure Enclave si existe; `load(from:)` persistente),
  `DPoPProof`, `DPoPInterceptor` con `DPoP-Nonce`.
- Firmas HTTP (RFC 9421 + Content-Digest RFC 9530): `SignedRequestInterceptor`.
- App Attest: `Attestor`, `ChallengeProvider`, `DeviceCheckAttestor`, `AppAttestInterceptor`.
- `SECURITY.md`: modelo de amenaza, mapeo MASVS 2.0, responsabilidades del servidor.

## [0.3.0] - 2026-10-21
Iteración 3: transporte avanzado.

### Added
- Streams con `@Api(kind:)`: `.bytes`, `.lines`, `.ndjson` (elemento `Decodable` por línea) y `.sse`
  (`ServerEvent`); `HTTPClient.stream` con default de una pieza y `URLSession.bytes(for:)`;
  `StreamingResponse`, `StreamParsing`; `MockClient.onStream`.
- Descargas y subidas: `kind: .download` → `Download` (progreso, `file()`, `pause()`/`resume()` por
  `resumeData`, `cancel()`), `kind: .upload` → `Upload` (progreso, `response()`, `value()`),
  `FileUpload` y `Multipart`, `TransferClient` (URLSession con delegado por tarea; `MockClient` simulado),
  `DownloadQueue` con límite y progreso agregado, `TransferStateBox` para transportes propios.
- WebSocket: `@Socket("/ruta")` → `Socket<Saliente, Entrante>` (texto, binario o JSON según los tipos),
  `SocketConnection`/`SocketClient`, `URLSessionWebSocketTask` con espera del handshake, `SocketClosed`;
  `SecurityPolicy` acepta `wss` siempre y `ws` solo en Debug; `LocalWebSocketServer` en `JadeTesting`.
- `HTTPError.unsupported` cuando el transporte no sabe hacer la operación.

## [0.2.0] - 2026-10-21
Iteración 2: el pipeline, los defaults seguros del nivel 1 y los servicios del nivel 2.

### Added
- Nivel 2: `Environment` (servicios, capas entorno → servicio, `client(for:)`, `validate()`),
  `ServiceConfiguration`, `Environment(bundle:)`/`Environment(plist:)` desde el Info.plist alimentado
  por `.xcconfig`, overrides `applyingLaunchOverrides()` solo en Debug, `EnvironmentError`.
- `@Repository(service:)`, `init(environment:)` y la fábrica `live(in:)` (también como
  `let repo: X = try .live(in:)` gracias al rol `extension` de la macro).
- `JadeTesting`: `environment.mocking(service, with:)` y `mockingAll(with:)`.
- `SecurityPolicy` en `AppClient.security`: solo HTTPS fuera de Debug (`HTTPError.insecureURL`),
  claves sensibles para redacción. `SecurityAudit` avisa en Debug de headers de credencial con valor fijo.
- `@Idempotent`: `Idempotency-Key` única por llamada, repetida en los reintentos. `@Retries` sobre
  POST/PATCH sin `@Idempotent` es error de compilación; el motor tampoco reintenta en runtime.
- `RequestLogger` mudo en release salvo `enabledInRelease: true`; redacta headers, query y body.
- Producto `JadeTesting` con `MockClient`, `MockResponse` y `MockError.unmocked`.
- Interceptores: `Interceptor` (`intercept(request, next:)`), atajos `RequestAdapter` y
  `ResponseInterceptor`, cadena en `AppClient(interceptors:)`, `@Interceptors(...)` por repositorio.
  Incluidos: `CommonHeaders`, `RequestLogger` (línea o cURL, con redacción) y `AuthInterceptor`
  (`TokenProvider`, refresh único ante 401 compartido entre peticiones en vuelo).
- Transformadores: `Transformer` (DTO → dominio verificado por tipos), `@Transform(Mapper.self)`,
  `@Unwrap("data.items")` por repositorio o endpoint, `@ErrorTransform(Mapper.self)`.
- Opciones de petición aplicadas por el cliente: `@Retries(n, backoff:)` (transporte, 5xx, 408, 429,
  `Retry-After`), `@CacheFor(ttl)`, `@SingleFlight`, `@Api(timeout:)` con `HTTPError.timeout`;
  `AppClient.options` como base; `Request.options` visible para interceptores.
- Grupos: `client.group(maxConcurrent:)` en orden y fail-fast, `groupSettled` con `Result` y progreso,
  `client.all(...)` heterogéneo con parameter packs y cancelación conjunta.
- `JadeRegistry`: plugin de JadeAPI para registrar decoradores `@Annotation` sin depender del núcleo.
- Ejemplo Login ampliado con el catálogo (toda la fase 2 en una pantalla).

### Changed
- Las peticiones del `MockClient` se registran al recibirse, antes de la latencia.
- `MockClient` se mueve de `JadeAPI` a `JadeTesting`; `HTTPError.unmocked` pasa a `MockError.unmocked`.

## [0.1.0] - 2026-10-21
Iteración 1: declarar y llamar.

### Added
- `@Repository` sobre un `protocol` genera `<Nombre>Client` (`@Decorable`, `init(client:)`) con un
  método por requisito; copia los decoradores apilados en cada requisito.
- `@Api` con ruta y verbo explícitos, o inferidos del nombre (`getUser` → `GET /user`).
- Parámetros: `:id` en la ruta, query en GET/DELETE, body JSON en POST/PUT/PATCH; `Path<T>`,
  `Query<T>`, `Header<T>`, `Body<T>` para forzar.
- Retornos `Decodable`, `Data`, `String`, `Void`, `Response`.
- `AppClient`, `HTTPClient`, `URLSessionClient`, `StageProtocol` con `resolve(arguments:environment:fallback:)`.
- `MockClient` por verbo y plantilla de ruta, con registro de peticiones y latencia configurable.
- `HTTPError` tipado; cancelación cooperativa.
- Diagnósticos: requisito sin `@Api`, no `async throws`, genérico, path con interpolación, método mal
  escrito, `Body<T>` mezclado con campos, `@Api` fuera de `@Repository`, aviso de query inferida.
- Ejemplo `Examples/Login`.

## [0.0.1] - 2026-10-21
### Added
- Iteración 0: esqueleto del paquete (`JadeAPI`, `JadeAPIMacros`), CI, DocC y roadmap por iteraciones.
