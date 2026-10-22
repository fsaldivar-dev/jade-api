# Seguridad en JadeAPI

Este documento dice qué protege la librería, qué debe hacer tu app, qué debe hacer tu servidor, y
dónde queda cada control respecto a los estándares que piden bancos y auditores: **OWASP MASVS 2.0 /
MASTG**, **OAuth 2.0 para apps nativas (RFC 8252) + PKCE (RFC 7636)**, **FAPI 2.0** (OpenID
Foundation), **DPoP (RFC 9449)**, **HTTP Message Signatures (RFC 9421)**, **Content-Digest (RFC 9530)**,
**PCI DSS 4.0** (requisito 6.5) y **App Attest** de Apple.

## Modelo de amenaza

Partimos de que **todo lo que viaja en el binario es público**: URLs, lógica, cualquier constante. Un
`.ipa` se descomprime y se descompila; en un dispositivo con jailbreak, se instrumenta en caliente.
Por eso la librería no intenta esconder nada: hace que descompilar no sirva para suplantar a la app
ni para abusar del API.

| Amenaza | Control | Dónde |
| --- | --- | --- |
| Robo del token (fuga en logs, memoria, proxy) | Tokens atados al dispositivo con **DPoP**; tokens cortos en Keychain con biometría | `DPoPInterceptor`, `KeychainTokenProvider` |
| Proxy MITM con certificado instalado | **Pinning** de clave pública con respaldo y caducidad | `PinningPolicy`, `URLSessionClient.pinned` |
| Cliente falso que imita a la app | **App Attest** con challenge del servidor | `AppAttestInterceptor` |
| Petición alterada en tránsito o repetida | **Firma RFC 9421** con `Content-Digest`, `created` y `nonce` | `SignedRequestInterceptor` |
| Pago duplicado por reintento | **Idempotency-Key**; `@Retries` no reintenta POST/PATCH sin ella | `@Idempotent`, motor de opciones |
| Tráfico en claro | Solo `https`/`wss` fuera de Debug | `SecurityPolicy` |
| Fuga en logs | Logger mudo en release; redacción de credenciales y datos de tarjeta | `RequestLogger`, `SecurityPolicy.sensitiveKeys` |
| Topología interna expuesta (sandbox, staging) | Entornos por `.xcconfig`: lo que no está en `Release.xcconfig` no existe | `Environment(bundle:)` |
| Redirección del tráfico por configuración externa | Overrides solo compilados en Debug | `applyingLaunchOverrides()` bajo `#if DEBUG` |
| Secretos en el cliente | No hay dónde ponerlos: error en configuración, aviso en headers fijos | `EnvironmentError.secretInConfiguration`, `SecurityAudit` |

## Mapeo MASVS 2.0

| Control MASVS | Qué cubre JadeAPI | Qué queda en la app / servidor |
| --- | --- | --- |
| **STORAGE-1** almacenamiento seguro | `SecItemKeychainStore` (`ThisDeviceOnly`, `biometryCurrentSet`), claves DPoP en Secure Enclave | Qué datos guardar y cuándo borrarlos |
| **STORAGE-2** sin fugas | Logger mudo en release, redacción | Capturas de pantalla, portapapeles, caché de teclado |
| **CRYPTO-1/2** | ES256 con CryptoKit, SHA-256, claves en hardware; sin primitivas propias | No reimplementar criptografía |
| **AUTH-1/2/3** | `AuthInterceptor` con refresh único, `KeychainTokenProvider` con caducidad y biometría, DPoP, `AuthorizationFlow` (discovery, PAR, PKCE, navegador del sistema) | SCA, caducidad de sesión en UI, verificación de firma del `id_token` si no confías solo en el canal del token endpoint |
| **NETWORK-1** canal seguro | Solo TLS; `http` fuera de Debug es error | ATS en Info.plist |
| **NETWORK-2** identidad del servidor | Pinning con validación del sistema primero | Rotación de pins con cada despliegue de certificado |
| **PLATFORM-1/2/3** | — | WebViews, IPC, esquemas de URL |
| **CODE-1/2/3/4** | `Package.resolved`, build en Swift 6 estricto, sin código de pruebas en el binario (`JadeTesting`) | SBOM en CI, validación de entrada en la app |
| **RESILIENCE-1..4** | App Attest demuestra integridad ante el servidor | Anti-tampering, anti-debug, ofuscación: capa de app, no de red |
| **PRIVACY-1..4** | Redacción de datos personales en logs | Minimización, consentimiento, borrado |

## Qué debe hacer tu servidor

La seguridad se gana del lado del servidor; la app solo le da las herramientas:

- Verificar la prueba DPoP en cada petición (`htm`, `htu`, `iat`, `jti` único, `ath`) y emitir `DPoP-Nonce`.
- Verificar la atestación contra Apple una vez, guardar la clave pública y validar cada aserción con un challenge de un solo uso.
- Verificar la firma RFC 9421 con la clave registrada; rechazar `created` viejos y `nonce` repetidos.
- Honrar `Idempotency-Key`: la misma clave devuelve la misma respuesta, nunca ejecuta dos veces.
- Autorizar cada llamada por usuario y por objeto (OWASP API Top 10), aplicar cuotas por usuario y por dispositivo.

## Qué no promete JadeAPI

- No oculta las URLs de producción: no son secreto.
- No detecta jailbreak ni ofusca: dan sensación de seguridad, no seguridad. Si tu auditor las exige por MASVS-RESILIENCE, son capa de app.
- No sustituye la revisión de un experto para cumplir PCI DSS o la regulación local (CNBV, PSD2): la facilita.

## Reportar una vulnerabilidad

Escribe a fsaldivar.dev@gmail.com con los detalles. No abras un issue público hasta que haya un arreglo.
