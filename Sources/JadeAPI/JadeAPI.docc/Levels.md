# Niveles

Qué piezas necesitas según el tamaño de la app.

## Overview

Cada nivel añade conceptos sobre el anterior sin cambiar lo que ya escribiste: un repositorio del
nivel 1 sigue funcionando igual cuando la app crece.

### Nivel 1 · un dominio

- ``Repository(service:)`` y ``Api(_:method:timeout:kind:)``; parámetros con ``Path``, ``Query``, ``Header`` y ``Body``.
- ``AppClient`` con una base; `MockClient` de `JadeTesting` para probar sin red.
- Defaults seguros: solo HTTPS fuera de Debug, logger mudo en release, aviso de secretos fijos (``SecurityAudit``).
- Ajustes por repositorio: ``BaseURL(_:)``, ``Headers(_:)`` y ``KeyMapping(_:dates:)``.

### Nivel 2 · varios servicios

- ``Environment`` leído del Info.plist que alimentan los `.xcconfig` (uno por Build Configuration);
  ``Repository(service:)`` dice a qué servicio pertenece cada repositorio y `live(in:)` resuelve el resto.
- Interceptores (``Interceptor``, ``AuthInterceptor``, ``RequestLogger``) en capas: entorno → servicio → repositorio → endpoint.
- Transformadores: ``Transform(_:)``, ``Unwrap(_:)``, ``ErrorTransform(_:)``.
- Opciones de petición: ``Retries(_:backoff:)``, ``CacheFor(_:)``, ``SingleFlight()``, `timeout:`.
- Grupos: `client.all`, `client.group`, `client.groupSettled`.

### Nivel 3 · big app

- Streams con `kind:` (`.bytes`, `.lines`, `.ndjson`, `.sse`), descargas y subidas con progreso, ``DownloadQueue``.
- WebSocket tipado con ``Socket(_:reconnect:maxReconnects:keepAlive:)``: reconexión con backoff, keep-alive y `events`.
- Métricas de transporte en ``TransportMetrics`` y ``MetricsInterceptor`` para telemetría.
- Seguridad: ``KeychainTokenProvider``, pinning (``PublicKeyPin``, ``PinningPolicy``), DPoP
  (``DPoPInterceptor``), firmas HTTP (``SignedRequestInterceptor``), App Attest (``AppAttestInterceptor``)
  y login OIDC (``AuthorizationFlow``, ``OpenIDDiscovery``). El modelo de amenaza está en `SECURITY.md`.
