//
//  Macros.swift
//  JadeAPI
//

/// Genera la implementación de un repositorio declarado como `protocol`.
///
/// ```swift
/// @Repository
/// protocol UsersRepository {
///     @Api func getUser(id: Int) async throws -> User          // GET /user?id=…
///     @Api("/users/:id") func user(id: Int) async throws -> User // GET /users/7
/// }
/// let users: UsersRepository = UsersRepositoryClient(client: AppClient(baseURL: …))
/// ```
///
/// Por cada requisito genera un método en `<Nombre>Client` que arma un ``Endpoint`` y lo
/// ejecuta con ``AppClient``. Los decoradores de AnnotationSwift que apiles sobre un requisito
/// (`@Retry`, `@Logged`, …) se copian al método generado y se envuelven como siempre, porque
/// el tipo generado es `@Decorable`.
///
/// Reglas: todo requisito lleva `@Api` y es `async throws`. El retorno puede ser `Decodable`,
/// `Data`, `String`, `Void` o ``Response``.
///
/// **Nivel 2.** Con `service:` el repositorio declara a qué servicio del ``Environment`` pertenece y
/// gana una fábrica que resuelve base, headers, interceptores y opciones de ese servicio:
///
/// ```swift
/// @Repository(service: "payments")
/// protocol PaymentsRepository: Sendable { … }
///
/// let environment = try Environment(bundle: .main)
/// let payments: PaymentsRepository = try .live(in: environment)      // o PaymentsRepositoryClient.live(in:)
/// ```
///
/// Sin `service:` se usa ``Environment/defaultService`` y todo funciona como en el nivel 1.
@attached(peer, names: suffixed(Client))
@attached(extension, names: named(live))
public macro Repository(service: String? = nil) = #externalMacro(module: "JadeAPIMacros", type: "RepositoryMacro")

/// Describe el endpoint de un requisito.
///
/// Sin argumentos, infiere verbo y ruta del nombre: el prefijo da el verbo (`get`, `fetch`,
/// `find`, `list` → GET; `post`, `create`, `add`, `send` → POST; `put`, `replace` → PUT;
/// `patch`, `update` → PATCH; `delete`, `remove` → DELETE) y el resto, en kebab-case, la ruta:
/// `getUserProfile()` → `GET /user-profile`. Sin prefijo conocido, GET con el nombre completo.
///
/// Con ruta explícita, los `:parámetros` se rellenan con el argumento del mismo nombre. El resto
/// de argumentos va a la query en GET/DELETE y al body JSON en POST/PUT/PATCH, salvo que se
/// marquen con ``Path``, ``Query``, ``Header`` o ``Body``.
///
/// La ruta explícita es la recomendación; la inferencia es azúcar para prototipos.
///
/// `kind:` elige la familia de retorno (``ApiKind``): `.bytes`, `.lines`, `.ndjson` y `.sse` devuelven
/// un `AsyncThrowingStream` que empieza al hacer `await` del requisito y valida el status antes;
/// `.download` y `.upload` devuelven un manejador con progreso.
@attached(peer)
public macro Api(_ path: String = "", method: HTTPMethod? = nil, timeout: Duration? = nil, kind: ApiKind = .request) = #externalMacro(module: "JadeAPIMacros", type: "ApiMacro")

/// Interceptores para todos los endpoints de un repositorio, por dentro de los del cliente.
///
/// ```swift
/// @Repository
/// @Interceptors(SignRequest(), RequestLogger(.curl))
/// protocol PaymentsRepository: Sendable { … }
/// ```
///
/// El cliente generado hace `client.with(interceptors: [SignRequest(), RequestLogger(.curl)])` en su `init`.
@attached(peer)
public macro Interceptors(_ interceptors: any Interceptor...) = #externalMacro(module: "JadeAPIMacros", type: "RepositoryAttributeMacro")

/// Headers fijos para todos los endpoints del repositorio (sobre el protocolo) o para uno solo
/// (sobre el requisito). Los del endpoint ganan sobre los del repositorio, y estos sobre los del cliente.
///
/// ```swift
/// @Repository
/// @Headers(["X-Client": "ios", "Accept-Language": "es-MX"])
/// protocol UsersRepository: Sendable {
///     @Headers(["X-Trace": "users"])
///     @Api("/users/:id") func user(id: Int) async throws -> User
/// }
/// ```
///
/// Un header con nombre de credencial (`Authorization`, `X-Api-Key`, …) y valor fijo dispara el aviso de
/// ``SecurityAudit`` en Debug: los secretos no van en el código; usa un `TokenProvider` o un interceptor.
@attached(peer)
public macro Headers(_ headers: [String: String]) = #externalMacro(module: "JadeAPIMacros", type: "RepositoryAttributeMacro")

/// Base del repositorio. Un prefijo de ruta (`"/v2"`) se añade a la base del cliente o del servicio;
/// una URL completa (`"https://legacy.ejemplo.com/api"`) la sustituye. Solo sobre el protocolo.
///
/// ```swift
/// @Repository(service: "users")
/// @BaseURL("/v2")
/// protocol UsersRepository: Sendable { … }      // https://users.ejemplo.com + /v2 + /users/7
/// ```
@attached(peer)
public macro BaseURL(_ base: String) = #externalMacro(module: "JadeAPIMacros", type: "RepositoryAttributeMacro")

/// Traducción de claves (y opcionalmente de fechas) para todo el repositorio, sin tocar el
/// `JSONDecoder` del cliente: `@KeyMapping(.snakeCase)`, `@KeyMapping(.snakeCase, dates: .iso8601)`.
/// Solo sobre el protocolo. Ver ``KeyMapping`` y ``DateMapping``.
@attached(peer)
public macro KeyMapping(_ keys: KeyMapping, dates: DateMapping? = nil) = #externalMacro(module: "JadeAPIMacros", type: "RepositoryAttributeMacro")

/// Convierte lo decodificado (DTO) en el tipo de retorno del requisito, con un ``Transformer``.
/// `Mapper.Input` es lo que se decodifica; `Mapper.Output` debe ser el retorno.
@attached(peer)
public macro Transform<Mapper: Transformer>(_ mapper: Mapper.Type) = #externalMacro(module: "JadeAPIMacros", type: "RepositoryAttributeMacro")

/// Decodifica solo el sub-árbol de esa ruta de claves: `@Unwrap("data")`, `@Unwrap("data.user")`.
/// Sobre el protocolo aplica a todos los endpoints; sobre un requisito, solo a ese (y gana).
@attached(peer)
public macro Unwrap(_ keyPath: String) = #externalMacro(module: "JadeAPIMacros", type: "RepositoryAttributeMacro")

/// Convierte el body de un error HTTP (status fuera de 2xx) en un error de dominio con un
/// ``Transformer`` cuyo `Output` es `Error`. Si el body no decodifica como `Input`, se lanza el
/// ``HTTPError`` original. Sobre el protocolo aplica a todos los endpoints.
@attached(peer)
public macro ErrorTransform<Mapper: Transformer>(_ mapper: Mapper.Type) = #externalMacro(module: "JadeAPIMacros", type: "RepositoryAttributeMacro") where Mapper.Output: Error

/// Reintenta a nivel HTTP: errores de transporte, 5xx, 408 y 429; nunca 4xx de negocio.
/// Respeta `Retry-After`. Sobre el protocolo aplica a todos los endpoints.
@attached(peer)
public macro Retries(_ attempts: Int, backoff: RetryPolicy.Backoff = .none) = #externalMacro(module: "JadeAPIMacros", type: "RepositoryAttributeMacro")

/// Guarda en memoria las respuestas 2xx de este endpoint (por verbo + URL + body) durante `ttl`.
@attached(peer)
public macro CacheFor(_ ttl: Duration) = #externalMacro(module: "JadeAPIMacros", type: "RepositoryAttributeMacro")

/// Peticiones idénticas en vuelo comparten una sola respuesta (deduplicación).
@attached(peer)
public macro SingleFlight() = #externalMacro(module: "JadeAPIMacros", type: "RepositoryAttributeMacro")

/// Marca una operación de escritura como idempotente: cada llamada manda un header
/// `Idempotency-Key` único (UUID) que el servidor usa para no duplicar efectos. Es la única forma
/// en que `@Retries` acepta reintentar un POST o PATCH.
@attached(peer)
public macro Idempotent() = #externalMacro(module: "JadeAPIMacros", type: "RepositoryAttributeMacro")

/// Declara un WebSocket en lugar de `@Api`. El requisito devuelve `Socket<Saliente, Entrante>`:
///
/// ```swift
/// @Socket("/ws/chat/:room")
/// func chat(room: String) async throws -> Socket<Outgoing, Incoming>
/// ```
///
/// Los parámetros de ruta se rellenan igual que en `@Api`; el resto va a la query. Los interceptores
/// de petición (headers, auth) se aplican al handshake, también en cada reconexión.
///
/// Resiliencia (ver ``SocketPolicy``): `reconnect:` es la espera entre intentos tras una caída
/// (`.constant`, `.exponential`); sin ella, `messages` termina con error. `maxReconnects:` limita los
/// intentos seguidos; `keepAlive:` manda un ping periódico y trata un ping fallido como caída.
///
/// ```swift
/// @Socket("/ws/chat/:room", reconnect: .exponential(.seconds(1), max: .seconds(30)), keepAlive: .seconds(30))
/// func chat(room: String) async throws -> Socket<Outgoing, Incoming>
/// ```
@attached(peer)
public macro Socket(_ path: String, reconnect: RetryPolicy.Backoff? = nil, maxReconnects: Int? = nil, keepAlive: Duration? = nil) = #externalMacro(module: "JadeAPIMacros", type: "RepositoryAttributeMacro")

/// Convierte un `struct` en un objeto de petición: sus campos se despliegan en la petición en vez de ir
/// como parámetros sueltos de la firma. Útil cuando un endpoint tiene muchos parámetros o la forma se
/// reutiliza. Se usa como el único parámetro de un `@Api`:
///
/// ```swift
/// @ApiRequest
/// struct CreateOrder {
///     @Parameter var items: [LineItem]     // body (es POST)
///     @Parameter var coupon: String?       // body; nil se omite
///     var idempotencyKey: Header<String>   // explícito: va al header
/// }
///
/// @Api("/orders", method: .post)
/// func create(_ order: CreateOrder) async throws -> Order
/// ```
///
/// Cada campo decide su destino por el tipo: ``Path``, ``Query``, ``Header`` y ``Body`` son explícitos;
/// un campo pelón o con `@Parameter` infiere por el verbo (query en GET/DELETE, body en POST/PUT/PATCH).
/// Para mandar un objeto como body crudo sin desplegarlo, usa `Body<T>` en la firma, no `@ApiRequest`.
@attached(extension, conformances: ApiRequest, names: named(_inputs))
public macro ApiRequest() = #externalMacro(module: "JadeAPIMacros", type: "ApiRequestMacro")

/// Marca un campo de un `@ApiRequest` como parámetro (query o body según el verbo). Es opcional y
/// legible: un campo pelón se trata igual. El destino lo decide el tipo del campo en `@ApiRequest`.
@attached(peer)
public macro Parameter() = #externalMacro(module: "JadeAPIMacros", type: "ParameterMarkerMacro")

/// Guardián de sesión: el endpoint exige un token. Sin sesión, `AuthInterceptor` corta con
/// `HTTPError.unauthenticated` **antes de tocar la red**. Sobre el protocolo aplica a todos los
/// endpoints; sobre un requisito, solo a ese. El marcador lo hace cumplir el interceptor: sin
/// `AuthInterceptor` en la cadena es inerte.
///
/// ```swift
/// @Repository(service: "catalog")
/// @Authenticated
/// protocol CatalogRepository: Sendable {
///     @Api("/products") func featured() async throws -> [Product]
///     @Public @Api("/status") func status() async throws -> Status   // excepción
/// }
/// ```
@attached(peer)
public macro Authenticated() = #externalMacro(module: "JadeAPIMacros", type: "RepositoryAttributeMacro")

/// Exime a un endpoint del `@Authenticated` del protocolo: no requiere sesión (login, health check).
@attached(peer)
public macro Public() = #externalMacro(module: "JadeAPIMacros", type: "RepositoryAttributeMacro")
