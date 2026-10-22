# 2 · Cliente y entornos

[← Fundamentos](01-Fundamentos.md) · [Índice](README.md) · Siguiente: [El pipeline →](03-El-pipeline.md)

## AppClient

[Saltar a configurarlo ↓](#configurar--appclient)

**Qué es.** La configuración de un API: base, codificadores, headers comunes, timeout, interceptores,
opciones por defecto, política de seguridad y el transporte. Es lo que recibe el `init(client:)` de cada
repositorio generado.

**Por qué.** Separar *qué pides* (el repositorio) de *cómo se envía* (el cliente): cambiar de entorno o
de transporte no toca ni una línea de tus repositorios.

**Cómo funciona.** `AppClient` es un `struct` de valor. No lo heredas ni lo reemplazas: lo construyes con
lo que quieras y, si hace falta, derivas copias con los `with(...)`. El punto de extensión de *cómo
viajan los bytes* no es el `AppClient`, es su `transport` (ver abajo).

<a id="configurar--appclient"></a>
**Configurar.**

```swift
let client = AppClient(
    baseURL: "https://api.ejemplo.com",
    interceptors: [AuthInterceptor(tokens: tokens), RequestLogger(.curl)],
    decoder: miDecoder,                 // fechas, estrategias de clave
    headers: ["Accept-Language": "es-MX"],
    timeout: 15
)
```

**En la demo.** [`AppContainer.swift`](../Examples/Guide/Sources/GuideCore/App/AppContainer.swift) crea un
cliente por servicio a través del entorno; [`CatalogStore`](../Examples/Guide/Sources/GuideCore/Features/Catalog/CatalogStore.swift)
lo usa para los grupos.

**Desarrollo seguro.** Nunca pongas un secreto fijo en `headers`: un valor en el binario es público.
`SecurityAudit` te avisa en Debug. El token lo pone un interceptor en runtime.

## El transporte (HTTPClient)

[Saltar a configurarlo ↓](#configurar--transporte)

**Qué es.** El objeto que de verdad habla con la red: recibe una `Request` y devuelve una `Response`.
`URLSessionClient` es el de serie.

**Por qué.** Es el hueco por el que cambias *cómo* se envía sin tocar nada más: una `URLSession` tuya
(caché, cookies, proxy), pinning, un servidor falso en pruebas, o un backend propio (Alamofire llegará
por aquí).

**Cómo funciona.** `HTTPClient` es un protocolo de dos métodos:

```swift
public protocol HTTPClient: Sendable {
    func send(_ request: Request) async throws -> Response
    func stream(_ request: Request) async throws -> StreamingResponse   // default: cae a send()
}
```

<a id="configurar--transporte"></a>
**Configurar.**

```swift
AppClient(baseURL: "…", transport: URLSessionClient(session: miSession))  // tu URLSession
AppClient(baseURL: "…", transport: .pinned(policy))                       // pinning, ver tema 5
AppClient(baseURL: "…", transport: MockClient())                          // pruebas, JadeTesting
```

**En la demo.** El entorno `mock` cambia los cinco servicios al `MockClient` con `mockingAll(with:)` sin
tocar ninguna vista ni repositorio: [`AppEnvironment.swift`](../Examples/Guide/Sources/GuideCore/Environment/AppEnvironment.swift).

## Entornos y servicios

[Saltar a configurarlo ↓](#configurar--entornos)

**Qué es.** Cuando la app crece, los repositorios no apuntan a una URL sino a un **servicio** con nombre
(`"auth"`, `"catalog"`), y un `Environment` resuelve la base, los headers, las opciones y el transporte
de cada uno.

**Por qué.** Una app mediana habla con varios hosts, con distinto timeout, auth o pinning cada uno, y
cambia de dev a prod sin recompilar lógica. Los entornos viven donde Xcode ya guarda la configuración:
`.xcconfig` por Build Configuration e Info.plist, no un archivo propio que acabe en git con secretos.

**Cómo funciona.** El repositorio declara su servicio con `@Repository(service: "catalog")` y se resuelve
con `try .live(in: environment)`. Las capas se componen de afuera hacia adentro: **entorno → servicio →
repositorio (`@Interceptors`) → endpoint**.

<a id="configurar--entornos"></a>
**Configurar.** En un proyecto de Xcode, un `.xcconfig` por configuración y un diccionario en el
Info.plist que `Environment(bundle:)` lee:

```xml
<key>JadeAPI</key>
<dict>
    <key>stage</key><string>$(JADE_STAGE)</string>
    <key>services</key>
    <dict>
        <key>auth</key>    <dict><key>baseURL</key><string>$(JADE_AUTH_BASE_URL)</string></dict>
        <key>catalog</key> <dict><key>baseURL</key><string>$(JADE_CATALOG_BASE_URL)</string>
                                 <key>timeout</key><string>10</string><key>retries</key><string>2</string></dict>
    </dict>
</dict>
```

Por servicio: `baseURL`, `headers`, `timeout`, `cache`, `retries`, `pins`. `Environment` valida al
arrancar: servicio ausente, URL inválida, `http://` fuera de Debug, o un header con nombre de credencial
son error. En un paquete sin Info.plist (como la guía), `Environment(plist:)` recibe el mismo diccionario
en código.

**En la demo.** [`Stage.swift`](../Examples/Guide/Sources/GuideCore/Environment/Stage.swift) describe
cinco servicios para `live` y `mock`; `Config/` trae los `.xcconfig` de muestra.

**Desarrollo seguro.** Lo que no está en `Release.xcconfig` no existe en el binario de tienda; eso es lo
que audita PCI DSS 6.5 / OWASP MASTG. Los overrides de desarrollo (`applyingLaunchOverrides`) solo
compilan en Debug. Ver [Dónde viven los secretos](05-Desarrollo-seguro.md#dónde-viven-los-secretos).

## Ajustes del repositorio

**Qué es.** Tres atributos sobre el `protocol` evitan repetir lo mismo en cada endpoint o cliente.

```swift
@Repository(service: "users")
@BaseURL("/v2")                                   // prefijo sobre la base; o una URL completa que la sustituye
@Headers(["X-Client": "ios"])                     // en todos los endpoints
@KeyMapping(.snakeCase, dates: .iso8601)          // full_name ↔ fullName, sin tocar el decoder del cliente
protocol UsersRepository: Sendable { … }
```

Prioridad de headers: endpoint → repositorio → cliente/servicio. `@BaseURL` y `@KeyMapping` solo van sobre
el protocolo (en un requisito es error de compilación). En código, `client.with(base:)`, `with(headers:)`
y `with(keys:dates:)` hacen lo mismo para un `AppClient`.
