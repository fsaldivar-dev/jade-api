/// Marca explícita de un parámetro de ruta. Normalmente no hace falta: `:id` en la ruta se
/// empareja con el parámetro `id` por nombre.
public struct Path<Value: Sendable>: Sendable {
    public var wrappedValue: Value
    public init(_ wrappedValue: Value) { self.wrappedValue = wrappedValue }
}

/// Fuerza un parámetro a la query, aunque el verbo lleve body.
public struct Query<Value: Sendable>: Sendable {
    public var wrappedValue: Value
    public init(_ wrappedValue: Value) { self.wrappedValue = wrappedValue }
}

/// Envía el parámetro como header. El nombre del header es la etiqueta del parámetro.
public struct Header<Value: Sendable>: Sendable {
    public var wrappedValue: Value
    public init(_ wrappedValue: Value) { self.wrappedValue = wrappedValue }
}

/// Envía el parámetro completo como body (JSON por defecto), en lugar de un campo del body.
public struct Body<Value: Encodable & Sendable>: Sendable {
    public var wrappedValue: Value
    public init(_ wrappedValue: Value) { self.wrappedValue = wrappedValue }
}

// Literales, para que en tests y llamadas simples no haga falta envolver.
extension Path: ExpressibleByStringLiteral, ExpressibleByUnicodeScalarLiteral, ExpressibleByExtendedGraphemeClusterLiteral where Value == String {
    public init(stringLiteral value: String) { self.init(value) }
}
extension Path: ExpressibleByIntegerLiteral where Value == Int {
    public init(integerLiteral value: Int) { self.init(value) }
}
extension Query: ExpressibleByStringLiteral, ExpressibleByUnicodeScalarLiteral, ExpressibleByExtendedGraphemeClusterLiteral where Value == String {
    public init(stringLiteral value: String) { self.init(value) }
}
extension Query: ExpressibleByIntegerLiteral where Value == Int {
    public init(integerLiteral value: Int) { self.init(value) }
}
extension Header: ExpressibleByStringLiteral, ExpressibleByUnicodeScalarLiteral, ExpressibleByExtendedGraphemeClusterLiteral where Value == String {
    public init(stringLiteral value: String) { self.init(value) }
}
