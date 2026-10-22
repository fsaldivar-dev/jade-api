/// Una edición en Wikipedia, tal como llega en el `data` de cada evento SSE de stream.wikimedia.org.
public struct WikiChange: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let title: String
    public let user: String
    public let wiki: String
    public let type: String
}
