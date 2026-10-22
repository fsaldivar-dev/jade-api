# Guía de JadeAPI

> La teoría de cada pieza (qué es, por qué, cómo se configura) está en [`Documentation/`](../../Documentation/README.md). Esta app es esa teoría corriendo.

App macOS con una pestaña por pieza de la librería, contra **APIs públicas reales** (entorno `live`) o un
servidor falso en memoria (entorno `mock`). Es una guía de implementación: cada pantalla es un archivo de
vista y un store pequeño, sin genéricos ni abstracciones, y el comentario de arriba de cada archivo dice qué
enseña y qué declaración lo hace funcionar.

```bash
swift run  --package-path Examples/Guide                   # mock (por defecto)
swift run  --package-path Examples/Guide -- --stage=live   # APIs reales; o JADE_STAGE=live
swift test --package-path Examples/Guide                   # 17 pruebas sin red contra los fixtures
JADE_LIVE=1 swift test --package-path Examples/Guide --filter Live   # 4 pruebas contra las APIs reales
```

## Las pestañas y sus APIs

| Pestaña | API real | Qué enseña | Dónde mirar |
|---|---|---|---|
| Sesión | `dummyjson.com/auth/login`, `/auth/me` (usuarios `emilys/emilyspass`, `michaelw/michaelwpass`) | `@Repository(service:)`, `@Api` con body JSON, `AuthInterceptor` poniendo el Bearer, `@Logged @Retry` | `Network/Repositories/AuthRepository.swift`, `Features/Session/SessionStore.swift` |
| Catálogo | `dummyjson.com/products`, `/products/:id`, `/products/category-list` | `@Headers`, `@Unwrap`, `@Transform`, `@ErrorTransform`, `@Retries` (el mock responde 503 la primera vez), `@CacheFor`, `@SingleFlight`, `timeout:`, `client.all` y `groupSettled` | `CatalogRepository.swift`, `Features/Catalog/CatalogStore.swift` |
| Stream | `stream.wikimedia.org/v2/stream/recentchange` (ediciones de Wikipedia en vivo) | `kind: .sse`, `for try await`, `event.decode`, cancelar la `Task` cierra la conexión | `WikiRepository.swift`, `Features/Stream/WikiStore.swift` |
| Descargas | `picsum.photos/seed/:seed/800/500` | `kind: .download`, `DownloadQueue(maxConcurrent: 2)`, progreso agregado, `settled()` | `PhotosRepository.swift`, `Features/Downloads/DownloadsStore.swift` |
| Socket | `wss://echo.websocket.org` | `@Socket` con `reconnect:` y `keepAlive:`, `messages`, `events`, `reconnect()` forzado, `SocketDisconnected` | `EchoRepository.swift`, `Features/Socket/EchoStore.swift` |
| Métricas | las mismas peticiones | `MetricsInterceptor` en la capa de entorno, `TransportMetrics` (primer byte, protocolo), `Response.attempts` | `Diagnostics/MetricsLog.swift`, `Environment/AppEnvironment.swift` |

El panel de la derecha es el `CallLog`: lo que escriben `@Logged`, `@Retry` y el `RequestLogger` (con duración, primer byte y protocolo).

## Estructura

```
Examples/Guide
├── Config/                         .xcconfig por Build Configuration + fragmento de Info.plist (cómo lo haría un proyecto de Xcode)
├── Sources/GuideCore/              todo lo que no es UI; se prueba solo
│   ├── Domain/                     Token, Profile, Product, WikiChange: tipos de la app, sin JSON ni HTTP
│   ├── Network/
│   │   ├── Repositories/           Auth, Catalog, Wiki, Photos, Echo: un protocolo por servicio
│   │   ├── DTOs/                   lo que devuelve el servidor, internal
│   │   ├── Mappers/                Transformer: DTO → dominio, body de error → CatalogError
│   │   ├── Decorators/             @Logged y @Retry (@Annotation; el plugin JadeRegistry genera sus declaraciones)
│   │   └── Session/                SessionTokens: TokenProvider para AuthInterceptor
│   ├── Environment/                Stage (live/mock, cinco servicios), AppEnvironment (interceptores), Fixtures (servidor falso)
│   ├── Features/                   un store @Observable por pestaña
│   ├── Diagnostics/                CallLog y MetricsLog: lo que escriben decoradores e interceptores
│   └── App/                        AppContainer (raíz de composición) y AppShell (entorno activo, errores de arranque)
├── Sources/Guide/                  la app: GuideApp y una vista por pestaña en Views/
└── Tests/GuideCoreTests/           pruebas contra los fixtures, y LiveSmokeTests opt-in contra las APIs reales
```

Las dependencias van en una dirección: `Views → Features → Network → Domain`. Las vistas solo conocen los
stores; los stores solo conocen los protocolos de los repositorios; los repositorios, los DTOs y los mappers.

## Entornos

`Stage.configuration` es el mismo diccionario que `Environment(bundle:)` leería del Info.plist. `auth` y
`catalog` comparten host: un servicio es un nombre lógico, no una URL. En `mock`, `mockingAll(with:)` manda
los cinco servicios al servidor falso de `Fixtures`; el WebSocket no tiene mock y su pestaña lo dice.

Con la app corriendo en Debug puedes mover un servicio sin recompilar:
`swift run --package-path Examples/Guide -- --stage=live --service.catalog=http://localhost:8080`.

## Llevarlo a un proyecto de Xcode

1. Copia `Config/` y asigna cada `.xcconfig` a su Build Configuration. `Local.xcconfig` queda fuera de git.
2. Pega `Config/Info.plist.fragment.xml` en el Info.plist del target: las URLs llegan por `$(JADE_AUTH_BASE_URL)` y compañía.
3. Sustituye `Stage.configuration` por `Environment(bundle: .main)` en `AppEnvironment.make`. El resto no cambia.
