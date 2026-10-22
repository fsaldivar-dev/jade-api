# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
