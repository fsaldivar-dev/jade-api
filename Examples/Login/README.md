# Login · ejemplo de JadeAPI

App SwiftUI (macOS) con selector de entorno, login contra un servicio `auth` y un catálogo contra un servicio
`catalog`. Enseña lo que una app mediana usa de JadeAPI: entornos con varios servicios, repositorios declarados,
decoradores propios, interceptores, transformadores, opciones por endpoint y grupos de peticiones.

```bash
swift run  --package-path Examples/Login                 # entorno mock (por defecto)
swift run  --package-path Examples/Login -- --stage=dev  # o JADE_STAGE=dev
swift test --package-path Examples/Login                 # 12 pruebas sin UI
```

En `mock` la contraseña es el mismo usuario (`admin/admin`, `viewer/viewer`). En `dev` y `prod` no hay servidor:
se ve el error de red tipado.

## Estructura

```
Examples/Login
├── Config/                         .xcconfig por Build Configuration + fragmento de Info.plist (cómo lo haría un proyecto de Xcode)
├── Sources/LoginCore/              todo lo que no es UI; se prueba solo
│   ├── Domain/                     Token, Profile, Product, CatalogError: tipos de negocio, sin JSON ni HTTP
│   ├── Network/
│   │   ├── Repositories/           AuthRepository, ProfileRepository, CatalogRepository (@Repository + @Api)
│   │   ├── DTOs/                   lo que devuelve el servidor, internal: nunca sale de esta capa
│   │   ├── Mappers/                Transformer: DTO → dominio, body de error → CatalogError
│   │   ├── Decorators/             @Logged y @Retry (@Annotation; el plugin JadeRegistry genera sus declaraciones)
│   │   └── Session/                SessionTokens: TokenProvider para AuthInterceptor
│   ├── Environment/                Stage (dev/prod/mock), AppEnvironment (Environment + interceptores), Fixtures (servidor falso)
│   ├── Features/                   SessionStore y CatalogStore: estado @Observable por pantalla, hablan con protocolos
│   ├── Diagnostics/                CallLog: lo que escriben decoradores e interceptores y la UI muestra
│   └── App/                        AppContainer (raíz de composición) y AppShell (entorno activo, errores de arranque)
├── Sources/Login/                  la app: LoginApp y Views/
└── Tests/LoginCoreTests/           sesión, catálogo y entorno contra los fixtures
```

Las dependencias van en una dirección: `Views → Features → Network → Domain`. Las vistas solo conocen los stores;
los stores solo conocen los protocolos de los repositorios; los repositorios solo conocen los DTOs y los mappers.

## Qué enseña cada pieza

| Pieza | Dónde | Qué muestra |
|---|---|---|
| Entornos con varios servicios | `Environment/Stage.swift` | el mismo diccionario que leería `Environment(bundle:)` de un Info.plist alimentado por `Config/*.xcconfig` |
| Overrides de desarrollo | `Environment/AppEnvironment.swift` | `applyingLaunchOverrides()` solo en Debug: `--service.catalog=http://localhost:8080` |
| Un servidor falso para toda la app | `Environment/Fixtures.swift` | `mockingAll(with:)`; cambiar la demo es cambiar aquí |
| Repositorios declarados | `Network/Repositories/` | `@Repository(service:)` + `@Api`; `Header<String>` como parámetro |
| Decoradores propios apilados | `Network/Decorators/`, `AuthRepository.swift` | `@Logged @Retry(2) @Api(...)`: el orden es el anidamiento |
| Auth y log en la capa de entorno | `AppEnvironment.swift` | `AuthInterceptor` (refresca una vez ante 401) y `RequestLogger` redactado |
| DTO → dominio y errores tipados | `CatalogRepository.swift`, `Network/Mappers/` | `@Unwrap("data")`, `@Transform`, `@ErrorTransform` a nivel de protocolo y de función |
| Opciones por endpoint | `CatalogRepository.swift` | `@Retries` (la primera carga recibe un 503), `@CacheFor`, `@SingleFlight`, `timeout:` |
| Grupos | `Features/Catalog/CatalogStore.swift` | `client.all` para destacados + categorías; `groupSettled(maxConcurrent:)` para los detalles, el producto 99 falla solo |
| Arranque sin `try!` | `App/AppContainer.swift`, `App/AppShell.swift` | la configuración se valida al construir; si falla, la UI lo muestra |
| Log inyectable | `Diagnostics/CallLog.swift` | `@TaskLocal current`: la app usa `shared`; cada prueba usa el suyo con `CallLog.$current.withValue` |

## Llevarlo a un proyecto de Xcode

1. Copia `Config/` y asigna cada `.xcconfig` a su Build Configuration. `Local.xcconfig` queda fuera de git.
2. Pega `Config/Info.plist.fragment.xml` en el Info.plist del target: las URLs llegan por `$(AUTH_BASE_URL)` y compañía.
3. Sustituye `Stage.configuration` por `Environment(bundle: .main)` en `AppEnvironment.make`. El resto no cambia.
