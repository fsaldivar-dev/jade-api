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
/// (`@Retry`, `@Cached`, …) se copian al método generado y se envuelven como siempre, porque
/// el tipo generado es `@Decorable`.
///
/// Reglas: todo requisito lleva `@Api` y es `async throws`. El retorno puede ser `Decodable`,
/// `Data`, `String`, `Void` o ``Response``.
@attached(peer, names: suffixed(Client))
public macro Repository() = #externalMacro(module: "JadeAPIMacros", type: "RepositoryMacro")

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
@attached(peer)
public macro Api(_ path: String = "", method: HTTPMethod? = nil) = #externalMacro(module: "JadeAPIMacros", type: "ApiMacro")
