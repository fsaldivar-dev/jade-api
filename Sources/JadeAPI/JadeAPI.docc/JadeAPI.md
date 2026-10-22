# ``JadeAPI``

Declara tu API con anotaciones; Jade la ejecuta.

## Overview

JadeAPI está construida sobre AnnotationSwift. Un repositorio es un `protocol`; cada endpoint es un
requisito anotado; `@Repository` genera la implementación y los decoradores que apiles sobre cada
endpoint se envuelven como en cualquier función decorable.

```swift
@Repository
protocol UsersRepository {
    @Retry(3)
    @Api("/users/:id")
    func getUser(id: Int) async throws -> User
}
```

> Estado: iteración 1 (declarar y llamar).

## Topics

### Declarar un API

- ``Repository()``
- ``Api(_:method:)``
- ``Path``
- ``Query``
- ``Header``
- ``Body``

### Cliente y entornos

- ``AppClient``
- ``HTTPClient``
- ``URLSessionClient``
- ``StageProtocol``

### Petición y respuesta

- ``Endpoint``
- ``Request``
- ``Response``
- ``HTTPMethod``
- ``HTTPError``

### Pruebas

- ``MockClient``
- ``MockResponse``

### Versión

- ``Jade``
