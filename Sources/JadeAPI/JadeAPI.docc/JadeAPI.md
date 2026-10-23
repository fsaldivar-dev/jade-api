# ``JadeAPI``

Declara tu API con anotaciones; Jade la ejecuta.

## Overview

Un repositorio es un `protocol`; cada endpoint es un requisito anotado con ``Api(_:method:timeout:kind:)``.
``Repository(service:)`` genera la implementación y los decoradores de AnnotationSwift que apiles sobre
cada endpoint se envuelven como en cualquier función decorable.

```swift
@Repository
protocol UsersRepository: Sendable {
    @Logged
    @Api("/users/:id")
    func user(id: Int) async throws -> User
}

let users: UsersRepository = UsersRepositoryClient(client: AppClient(baseURL: "https://api.ejemplo.com"))
let paco = try await users.user(id: 7)          // GET /users/7
```

La librería se presenta por tamaño de app, con *progressive disclosure*: quien está en un nivel no
necesita los conceptos del siguiente.

- **Nivel 1 · un dominio**: declarar y llamar, probar sin red, defaults seguros.
- **Nivel 2 · varios servicios**: ``Environment`` desde `.xcconfig` + Info.plist, interceptores,
  transformadores, opciones de petición y grupos.
- **Nivel 3 · big app**: streams, transferencias, WebSocket y la seguridad que piden los bancos.

La guía conceptual tema por tema (qué es, por qué, cómo se configura, con diagramas y desarrollo seguro) está en la carpeta `Documentation/` del repositorio.

Empieza por <doc:QuickStart>. Una regla de bolsillo para elegir pieza: *interceptor si tocas HTTP,
decorador si tocas la llamada, transformador si tocas datos*.

## Topics

### Primeros pasos

- <doc:QuickStart>
- <doc:Levels>

### Declarar un API

- ``Repository(service:)``
- ``Api(_:method:timeout:kind:)``
- ``ApiKind``
- ``Path``
- ``Query``
- ``Header``
- ``Body``
- ``Headers(_:)``
- ``BaseURL(_:)``
- ``KeyMapping(_:dates:)``
- ``ApiRequest()``
- ``Parameter()``
- ``ApiRequest``
- ``ApiRequestInputs``

### Cliente y entornos

- ``AppClient``
- ``Environment``
- ``ServiceConfiguration``
- ``HTTPClient``
- ``URLSessionClient``
- ``StageProtocol``

### Petición y respuesta

- ``Endpoint``
- ``Request``
- ``Response``
- ``HTTPMethod``
- ``HTTPError``

### Interceptores

- ``Interceptors(_:)``
- ``Interceptor``
- ``RequestAdapter``
- ``ResponseInterceptor``
- ``AuthInterceptor``
- ``TokenProvider``
- ``Authenticated()``
- ``Public()``
- ``CommonHeaders``
- ``RequestLogger``
- ``MetricsInterceptor``
- ``MetricsReport``
- ``TransportMetrics``

### Transformadores

- ``Transformer``
- ``Transform(_:)``
- ``Unwrap(_:)``
- ``ErrorTransform(_:)``

### Opciones de petición

- ``Retries(_:backoff:)``
- ``CacheFor(_:)``
- ``SingleFlight()``
- ``Idempotent()``
- ``RequestOptions``
- ``RetryPolicy``

### Streams, transferencias y WebSocket

- ``StreamingResponse``
- ``ServerEvent``
- ``Download``
- ``Upload``
- ``DownloadQueue``
- ``Multipart``
- ``FileUpload``
- ``Socket(_:reconnect:maxReconnects:keepAlive:)``
- ``Socket``
- ``SocketPolicy``
- ``SocketEvent``

### Seguridad

- ``SecurityPolicy``
- ``SecurityAudit``
- ``KeychainStore``
- ``KeychainTokenProvider``
- ``PublicKeyPin``
- ``PinningPolicy``
- ``DPoPInterceptor``
- ``SignedRequestInterceptor``
- ``AppAttestInterceptor``
- ``AuthorizationFlow``
- ``OpenIDDiscovery``

### Versión

- ``Jade``
