import SwiftSyntax
import SwiftSyntaxMacros

/// Marcadores propios de JadeAPI que `@Repository` consume (`@Interceptors`, `@Unwrap`,
/// `@Transform`, `@ErrorTransform`). No generan código; aquí solo se valida el contexto.
public struct RepositoryAttributeMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let name = Attributes.simpleName(node) ?? "attribute"
        if let proto = declaration.as(ProtocolDeclSyntax.self) {
            if Attributes.find("Repository", in: proto.attributes) == nil {
                context.error(node, id: "noRepository", "@\(name) has no effect: add @Repository to '\(proto.name.text)'")
            }
            return []
        }
        let enclosing = context.lexicalContext.first { $0.asProtocol(DeclGroupSyntax.self) != nil }
        guard let proto = enclosing?.as(ProtocolDeclSyntax.self) else {
            context.error(node, id: "notInRepository", "@\(name) can only be used on a @Repository protocol or its requirements")
            return []
        }
        if Attributes.find("Repository", in: proto.attributes) == nil {
            context.error(node, id: "noRepository", "@\(name) has no effect: add @Repository to '\(proto.name.text)'")
        }
        return []
    }
}
