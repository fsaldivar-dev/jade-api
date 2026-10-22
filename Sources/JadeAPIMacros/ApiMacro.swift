import SwiftSyntax
import SwiftSyntaxMacros

/// `@Api`: no genera código. `@Repository` lo lee. Aquí solo se valida dónde está.
public struct ApiMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Los argumentos los valida @Repository, que es quien los lee; aquí solo el contexto.
        let enclosing = context.lexicalContext.first { $0.asProtocol(DeclGroupSyntax.self) != nil }
        guard let proto = enclosing?.as(ProtocolDeclSyntax.self) else {
            context.error(node, id: "notInProtocol", "@Api can only be applied to requirements of a @Repository protocol")
            return []
        }
        if Attributes.find("Repository", in: proto.attributes) == nil {
            context.error(node, id: "noRepository", "@Api has no effect: add @Repository to '\(proto.name.text)'")
        }
        if !declaration.is(FunctionDeclSyntax.self) {
            context.error(node, id: "notFunction", "@Api can only be applied to functions")
        }
        return []
    }
}
