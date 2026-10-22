# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - Unreleased
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

## [0.1.0] - Unreleased
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
