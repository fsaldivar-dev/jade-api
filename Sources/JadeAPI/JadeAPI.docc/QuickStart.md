# Quick Start

La primera petición en cuatro pasos.

## Overview

JadeAPI necesita Swift 6.2 y un repositorio declarado como `protocol`. Todo lo demás lo genera la macro.

### 1. Dependencia

```swift
// Package.swift
.package(url: "https://github.com/fsaldivar-dev/jade-api.git", from: "0.9.0")
// en el target:
.product(name: "JadeAPI", package: "jade-api")
```

Si tu módulo define decoradores propios con `@Annotation`, añade también el plugin `JadeRegistry` al
target: genera las declaraciones de `@Logged`, `@Retry`, etc. a partir de los tipos.

### 2. Declara el repositorio

Un `protocol` `Sendable`; cada endpoint es un requisito `async throws` con ``Api(_:method:timeout:kind:)``.
La ruta explícita es la recomendación; los `:parámetros` se rellenan con el argumento del mismo nombre.

```swift
import JadeAPI

struct LoginForm: Decodable { let fields: [String] }
struct Token: Decodable { let value: String }

@Repository
protocol LoginRepository: Sendable {
    @Api("/login")
    func form() async throws -> LoginForm                               // GET /login

    @Api("/auth", method: .post)
    func auth(user: String, password: String) async throws -> Token     // POST /auth, body {user, password}
}
```

### 3. Crea el cliente y la implementación

``Repository(service:)`` generó `LoginRepositoryClient`. ``AppClient`` reúne base, codificadores,
headers comunes, timeout y transporte.

```swift
let client = AppClient(baseURL: "https://api.ejemplo.com")
let login: LoginRepository = LoginRepositoryClient(client: client)
```

### 4. Llama

La llamada *es* la petición. Fuera de 2xx se lanza ``HTTPError/status(_:_:)``; si el body no
decodifica, ``HTTPError/decoding(_:_:)``.

```swift
let form = try await login.form()
let token = try await login.auth(user: "<usuario>", password: "<contraseña>")
```

### Probar sin red

`JadeTesting` es un producto aparte, solo para tests y previews:

```swift
import JadeTesting

let mock = MockClient()
    .on(.post, "/auth") { request in request.body == nil ? .status(400) : .json(#"{"value": "t"}"#) }
let login: LoginRepository = LoginRepositoryClient(client: AppClient(baseURL: "https://mock.local", transport: mock))
#expect(try await login.auth(user: "a", password: "b").value == "t")
```

### Siguiente paso

Cuando aparezca un segundo servicio, un token que refrescar o un DTO que no es tu modelo, sigue en
<doc:Levels>.
