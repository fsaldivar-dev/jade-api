# JadeAPI · Alcances por iteración

Declara tu API con anotaciones; Jade la ejecuta. Construida sobre
[AnnotationSwift](https://github.com/fsaldivar-dev/experimental-annotation-swift): los decoradores
que apilas sobre un endpoint son los mismos que apilas sobre cualquier función.

Este documento dice **lo que hay en el código**, no lo que se planeó. Cada bloque lleva su estado; lo
que una iteración prometió y no se construyó está en [Deuda](#deuda) con el motivo, para decidirlo con
los ojos abiertos en vez de darlo por hecho. Lo que no está en la iteración en curso no se empieza
aunque sea fácil: la superficie de la librería es su mayor costo cognitivo.

Última revisión contra el código: 2026-10-22 (0.5.0 publicada, 0.6.0 en curso).

---

## Iteración 0 · Cimientos — hecho

- AnnotationSwift: un marcador dentro de un `protocol` es inerte (otra macro lo transcribe). Hoy jade-api
  depende de `experimental-annotation-swift` `from: "1.1.0"`.
- `@Annotation` + generador `annotation-registry`; el plugin `JadeRegistry` lo envuelve para los módulos que usan JadeAPI.
- Esqueleto: `Package.swift`, target de macros, CI en Swift 6.2 (Xcode 26.1) y 6.3 (Xcode 26.6).

## Iteración 1 · Declarar y llamar (0.1) — hecho

- `@Repository` genera `<Nombre>Client: <Nombre>, Sendable` (`@Decorable`), con `init(client:)`.
- `@Api` con ruta explícita o inferida del nombre (prefijos get/fetch/find/list/load, post/create/add/send,
  put/replace, patch/update, delete/remove); diagnóstico cuando un parámetro inferido a query podría ser de ruta.
- Parámetros: `:id` en la ruta ↔ argumento; defaults por verbo (query en GET/DELETE, body JSON en POST/PUT/PATCH);
  `Path`, `Query`, `Header`, `Body`.
- Retornos: `Decodable`, `Data`, `String`, `Void`, `Response`. `HTTPError` tipado.
- `AppClient`, `HTTPClient` (URLSession), `StageProtocol` + `resolve`, `MockClient` en `JadeTesting`, cancelación cooperativa.
- Diagnósticos de macro y tests de expansión; ejemplo `Examples/Login`.

**No se hizo:** DocC con Quick Start (llegó en 0.6.0, ver deuda).

## Iteración 2 · El pipeline (0.2) — hecho con cambios

Regla de bolsillo: *interceptor si tocas HTTP, decorador si tocas la llamada, transformador si tocas datos*.

- Interceptores: `Interceptor`, `RequestAdapter`, `ResponseInterceptor`, cadena en `AppClient(interceptors:)`,
  `@Interceptors` por repositorio. Incluidos: `AuthInterceptor` (refresh único con cola; sin refresh si la petición
  salió sin token), `CommonHeaders`, `RequestLogger` (`.line`/`.curl`, redactado).
- Transformadores: `Transformer`, `@Transform`, `@Unwrap("a.b")`, `@ErrorTransform`.
- Opciones de petición (en lugar de "decoradores de red"): `@Retries(n, backoff:)` consciente de idempotencia
  (`@Idempotent` manda `Idempotency-Key`), `@Api(timeout:)`, `@CacheFor`, `@SingleFlight`. Lo aplica el cliente
  porque un `Decorator` genérico no puede cancelar ni compartir un `Out` no `Sendable`.
- Grupos: `client.group(maxConcurrent:)`, `groupSettled`, `all` con parameter packs.

**No se hizo:** `RetryTransport`, `MetricsInterceptor`, `MockInterceptor`, `@Envelope(Type.self)`,
`@KeyMapping` (llegó en 0.6.0), codificador multipart como `ConverterFactory` (hay `Multipart` en
transferencias), `Result<T, HTTPError>` como retorno, `@Authenticated`, progreso agregado de grupos,
políticas `collect`/`tolerate(n)` (hay `failFast` y `groupSettled`), prioridad por elemento,
advertencia por pilas invertidas, ejemplo `Examples/Catalog` (el catálogo vive dentro de `Examples/Login`).

## Niveles

- **Nivel 1 · un dominio** — hecho. Defaults seguros: solo HTTPS fuera de Debug, `@Retries` exige
  `@Idempotent` en POST/PATCH, logger mudo en release, `JadeTesting` aparte, aviso de secretos fijos.
  Ajustes por repositorio (0.6.0): `@BaseURL`, `@Headers`, `@KeyMapping`.
- **Nivel 2 · varios servicios** — hecho. `@Repository(service:)`, `Environment(bundle:)`/`(plist:)` desde
  `.xcconfig` + Info.plist (se descartó un archivo propio), capas entorno → servicio → repositorio → endpoint,
  `applyingLaunchOverrides` solo en Debug, `mocking(_:with:)` por servicio.
- **Nivel 3 · big app** — seguridad hecha; transporte avanzado hecho salvo lo listado abajo.

## Iteración 3 · Transporte avanzado (0.3) — hecho con cambios

- `@Api(kind:)`: `.bytes`, `.lines`, `.ndjson`, `.sse` → `AsyncThrowingStream`; `.download` → `Download`
  (progreso, pausa/reanudación por `Range`); `.upload` → `Upload` (`Multipart`, `FileUpload`, `Data`, JSON).
- `DownloadQueue(maxConcurrent:)` con progreso agregado y `settled`.
- `@Socket("/ws/:room")` → `Socket<Out, In>` sobre `URLSessionWebSocketTask`; `LocalWebSocketServer` en `JadeTesting`.

**No se hizo:** reconexión de sockets con backoff y ping, persistencia de la cola de descargas entre
lanzamientos, background sessions, métricas de transporte (`URLSessionTaskMetrics`), diagnóstico
`kind` ↔ retorno más allá del prefijo del tipo, ejemplo `Examples/Media`, servidor HTTP local para descargas.

## Nivel 3 · Seguridad (0.4, 0.5) — hecho

- `KeychainStore` (`SecItemKeychainStore`, `InMemoryKeychainStore`), `StoredTokens`, `KeychainTokenProvider`.
- Pinning por clave pública (SPKI SHA-256) con respaldo, caducidad y subdominios; pins por servicio en el plist.
- DPoP (RFC 9449) con `P256SigningKey` (Secure Enclave). Firmas HTTP (RFC 9421 + Content-Digest). App Attest.
- Login OIDC al estilo FAPI 2.0: discovery, PAR, PKCE, `ASWebAuthenticationSession`, intercambio con DPoP,
  comprobación del `id_token`, refresh. `SECURITY.md` con el modelo de amenaza y el mapeo MASVS.

**No se hizo:** mTLS, pinning por certificado completo (solo SPKI), rotación de pins remota.

---

## Deuda

Prometido en una iteración marcada como hecha y aún sin construir. Cada entrada dice qué falta y por qué
sigue fuera; si se decide hacerla, se mueve a la iteración en curso.

| Pieza | Falta | Por qué sigue fuera |
| --- | --- | --- |
| `RetryTransport` / `MetricsInterceptor` | interceptores incluidos | los reintentos ya viven en `@Retries`; las métricas dependen de `URLSessionTaskMetrics` (nivel 3) |
| `@Authenticated` | guardián que lanza sin token | `AuthInterceptor` + `TokenProvider` cubren el caso; falta decidir si vale un marcador |
| Progreso agregado de grupos | `AsyncStream<Progress>` en `group` | solo lo pidió `DownloadQueue`, que ya lo tiene |
| `Result<T, HTTPError>` como retorno | adaptador de retorno | nadie lo ha necesitado; `throws` basta |
| `@Envelope(Type.self)` | envelope tipado | `@Unwrap("data")` resuelve el 90 % |
| Reconexión de sockets | backoff, ping, re-suscripción | necesita una política de resiliencia compartida con descargas |
| Métricas de transporte | `Response.metrics` | pendiente de diseño con el logger |
| mTLS | certificado de cliente en `URLSession` | lo piden pocos bancos; va con pinning |
| Ejemplos `Catalog` y `Media` | apps de muestra | `Login` absorbió el catálogo; falta una demo de streams/sockets |
| Pinning por certificado | además de SPKI | SPKI es la recomendación (sobrevive renovaciones) |

Saldado en 0.6.0: `@Headers`, `@BaseURL`, `@KeyMapping`, DocC con Quick Start, este documento.

---

## Iteración 4 · Backends y ergonomía — sin empezar

- Backend Alamofire: adaptador que recibe una `Session` y respeta interceptores, retriers y `ServerTrustManager`.
- `@Mock` genera `<Nombre>Mock: <Nombre>` con closures por endpoint.
- Segunda etiqueta como clave (`func post(id postId: Int)`).
- Integración con Pulse. Generador desde OpenAPI.
- Ejemplo `Examples/Alamofire`.

## Ideas (sin iteración)

Long polling · cola offline con reintento al volver la red · caché HTTP (ETag) · compresión de body ·
cassettes de grabación y reproducción · `@Paginated(cursor:)` → `Pages<Item>` · adaptador Combine ·
batch del servidor con ventana de tiempo · AsyncHTTPClient para Linux · métricas de grupo · GraphQL.

---

## Decisiones de diseño

1. **El núcleo no sabe de HTTP.** JadeAPI consume AnnotationSwift; cualquier cambio allí es genérico.
2. **`@Repository` escribe el cuerpo**, no hace falta soporte de funciones sin cuerpo en el núcleo.
3. **Protocolo como contrato**: mocks e inyección sin tocar vistas; cambiar de backend no toca repositorios.
4. **Mapper como tipo, no closure**: el compilador verifica DTO ↔ dominio ↔ retorno.
5. **Inferencia por nombre existe, pero la ruta explícita es la recomendación.**
6. **La concurrencia es de quien llama**: grupos en runtime, sin `@Parallel`.
7. **Una palabra para la familia de retorno** (`kind:`) en vez de cuatro marcadores.
8. **Las políticas de red son opciones de petición**, no decoradores: cancelación y `Sendable` mandan.
9. **Los entornos viven en `.xcconfig` + Info.plist**, el estándar de Xcode; nada de archivos de configuración propios.
10. **Progressive disclosure**: nadie ve interceptores ni transformadores hasta que los necesita.
11. **Este roadmap se revisa contra el código en cada release.** Lo que no está, se dice.

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
