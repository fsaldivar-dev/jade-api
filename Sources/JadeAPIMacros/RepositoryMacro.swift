import SwiftSyntax
import SwiftSyntaxMacros

/// `@Repository`: genera `<Nombre>Client: <Nombre>` con un método por requisito.
public struct RepositoryMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let proto = declaration.as(ProtocolDeclSyntax.self) else {
            context.error(node, id: "notProtocol", "@Repository can only be applied to a protocol")
            return []
        }
        let access = proto.modifiers.contains { $0.name.tokenKind == .keyword(.public) } ? "public " : ""
        var methods: [String] = []

        let protocolUnwrap = Self.stringArgument(of: Attributes.find("Unwrap", in: proto.attributes), in: context)
        let protocolErrorMapper = Self.typeArgument(of: Attributes.find("ErrorTransform", in: proto.attributes))

        for member in proto.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else {
                if let attributed = member.decl.asProtocol(WithAttributesSyntax.self),
                   let api = Attributes.find("Api", in: attributed.attributes) {
                    context.error(api, id: "notFunction", "@Api can only be applied to functions")
                }
                continue
            }
            if let generated = generate(function, access: access, protocolUnwrap: protocolUnwrap, protocolErrorMapper: protocolErrorMapper, in: context) {
                methods.append(generated)
            }
        }

        let name = proto.name.text
        let body = methods.isEmpty ? "" : "\n\n" + methods.joined(separator: "\n\n")
        // @Interceptors(A(), B()) a nivel de protocolo → se añaden al cliente en el init.
        var assignment = "self.client = client"
        if let interceptors = Attributes.find("Interceptors", in: proto.attributes),
           case .argumentList(let arguments)? = interceptors.arguments, !arguments.isEmpty {
            let list = arguments.map { $0.expression.trimmedDescription }.joined(separator: ", ")
            assignment = "self.client = client.with(interceptors: [\(list)])"
        }
        return [DeclSyntax(stringLiteral: """
        @AnnotationSwift.Decorable
        \(access)struct \(name)Client: \(name), Sendable {
            \(access)let client: JadeAPI.AppClient

            \(access)init(client: JadeAPI.AppClient) {
                \(assignment)
            }\(body)
        }
        """)]
    }

    /// Atributos que @Repository consume y no copia al método generado.
    static let consumedAttributes: Set<String> = ["Api", "Transform", "Unwrap", "ErrorTransform", "Interceptors"]

    // MARK: - Un método por requisito

    private static func generate(_ function: FunctionDeclSyntax, access: String, protocolUnwrap: String?, protocolErrorMapper: String?, in context: some MacroExpansionContext) -> String? {
        guard let api = Attributes.find("Api", in: function.attributes) else {
            context.error(function.name, id: "missingApi", "every requirement of a @Repository needs @Api")
            return nil
        }
        let effects = function.signature.effectSpecifiers
        guard effects?.asyncSpecifier != nil, effects?.throwsClause != nil else {
            context.error(function.signature, id: "effects", "a @Repository requirement must be declared 'async throws'")
            return nil
        }
        if function.genericParameterClause != nil {
            context.error(function.name, id: "generic", "generic requirements are not supported in a @Repository")
            return nil
        }

        // Verbo y ruta: explícitos o inferidos.
        let arguments = ApiArguments(api, in: context)
        let inferred = Inference.infer(from: function.name.text)
        let method = arguments.method ?? inferred.method ?? "get"
        let path = arguments.path.flatMap { $0.isEmpty ? nil : $0 } ?? inferred.path
        let pathWasInferred = arguments.path == nil || arguments.path?.isEmpty == true

        let parameters = ParameterInfo.analyze(function.signature.parameterClause.parameters, method: method, path: path)
        if pathWasInferred, parameters.contains(where: { $0.kind == .query && !$0.wrapped }) {
            let names = parameters.filter { $0.kind == .query && !$0.wrapped }.map(\.label).joined(separator: ", ")
            context.warning(api, id: "inferredQuery",
                            "'\(function.name.text)': parameters (\(names)) will be sent as query; if any is a path parameter, declare the route, e.g. @Api(\"\(path)/:\(parameters.first!.label)\")")
        }
        let bodies = parameters.filter { $0.kind == .body }
        if bodies.count > 1 || (bodies.count == 1 && parameters.contains { $0.kind == .field }) {
            context.error(function.signature, id: "body", "use a single Body<T> parameter or plain parameters as body fields, not both")
            return nil
        }

        // Construcción del Endpoint.
        let signature = function.name.text + "(" + function.signature.parameterClause.parameters.map { "\($0.firstName.text):" }.joined() + ")"
        var statements: [String] = []
        let headerParameters = parameters.filter { $0.kind == .header }
        statements.append("\(headerParameters.isEmpty ? "let" : "var") __headers: [String: String] = [:]")
        for parameter in headerParameters {
            statements.append("if let __value = JadeAPI.ParameterValue.text(\(parameter.valueExpression)) { __headers[\"\(parameter.label)\"] = __value }")
        }
        let pathParameters = parameters.filter { $0.kind == .path }
            .map { "\"\($0.label)\": JadeAPI.ParameterValue.text(\($0.valueExpression)) ?? \"\"" }
        let query = parameters.filter { $0.kind == .query }
            .map { "(\"\($0.label)\", JadeAPI.ParameterValue.text(\($0.valueExpression)))" }
        let body: String
        if let single = bodies.first {
            body = ".value(\(single.valueExpression))"
        } else {
            let fields = parameters.filter { $0.kind == .field }.map { "(\"\($0.label)\", \($0.valueExpression))" }
            body = fields.isEmpty ? "nil" : ".fields([\(fields.joined(separator: ", "))])"
        }
        statements.append("""
        let __endpoint = JadeAPI.Endpoint(name: "\(signature)", method: .\(method), path: "\(path)", pathParameters: [\(pathParameters.isEmpty ? ":" : pathParameters.joined(separator: ", "))], query: [\(query.joined(separator: ", "))], headers: __headers, body: \(body))
        """)
        // Transformadores: @Unwrap, @Transform, @ErrorTransform (requisito gana sobre protocolo).
        let ownUnwrap = stringArgument(of: Attributes.find("Unwrap", in: function.attributes), in: context)
        let mapper = typeArgument(of: Attributes.find("Transform", in: function.attributes))
        let errorMapper = typeArgument(of: Attributes.find("ErrorTransform", in: function.attributes)) ?? protocolErrorMapper
        let perform = performCall(for: function)
        if perform != "perform", ownUnwrap != nil || mapper != nil {
            let which = mapper != nil ? "@Transform" : "@Unwrap"
            context.error(function.signature, id: "transformReturn", "\(which) requires a Decodable return type; '\(function.signature.returnClause?.type.trimmedDescription ?? "Void")' is handled raw")
            return nil
        }
        // El @Unwrap del protocolo solo aplica a retornos decodificados; los crudos (Data, String, Void, Response) lo ignoran.
        let unwrap = ownUnwrap ?? (perform == "perform" ? protocolUnwrap : nil)
        let unwrapArgument = unwrap.map { ", unwrapping: \"\($0)\"" } ?? ""
        var fetch: String
        if let mapper {
            fetch = """
            let __input: \(mapper).Input = try await client.perform(__endpoint\(unwrapArgument))
                    return try \(mapper)().transform(__input)
            """
        } else {
            fetch = "return try await client.\(perform)(__endpoint\(unwrapArgument))"
        }
        if let errorMapper {
            fetch = """
            do {
                        \(fetch.split(separator: "\n", omittingEmptySubsequences: false).joined(separator: "\n    "))
                    } catch {
                        throw client.mapError(error, with: \(errorMapper).self\(unwrapArgument))
                    }
            """
        }
        statements.append(fetch)

        let copiedAttributes = Attributes.copying(function.attributes, excluding: Self.consumedAttributes)
        let attributes = copiedAttributes.isEmpty ? "" : copiedAttributes.joined(separator: "\n    ") + "\n    "
        let signatureText = function.signature.trimmedDescription
        return """
            \(attributes)\(access)func \(function.name.text)\(signatureText) {
                \(statements.joined(separator: "\n        "))
            }
        """
    }

    /// `@Unwrap("data")` → `"data"`. Rechaza interpolaciones.
    static func stringArgument(of attribute: AttributeSyntax?, in context: some MacroExpansionContext) -> String? {
        guard let attribute, case .argumentList(let list)? = attribute.arguments, let first = list.first else { return nil }
        guard let literal = first.expression.as(StringLiteralExprSyntax.self),
              !literal.segments.contains(where: { $0.is(ExpressionSegmentSyntax.self) }) else {
            context.error(first.expression, id: "literal", "expected a plain string literal")
            return nil
        }
        return literal.segments.map { $0.trimmedDescription }.joined()
    }

    /// `@Transform(UserMapper.self)` → `"UserMapper"`.
    static func typeArgument(of attribute: AttributeSyntax?) -> String? {
        guard let attribute, case .argumentList(let list)? = attribute.arguments, let first = list.first else { return nil }
        if let member = first.expression.as(MemberAccessExprSyntax.self), member.declName.baseName.tokenKind == .keyword(.self),
           let base = member.base {
            return base.trimmedDescription
        }
        return first.expression.trimmedDescription
    }

    /// Variante de `perform` según el tipo de retorno; la macro lo sabe en compilación.
    private static func performCall(for function: FunctionDeclSyntax) -> String {
        guard let type = function.signature.returnClause?.type else { return "performVoid" }
        var text = type.trimmedDescription
        if text.hasPrefix("JadeAPI.") { text = String(text.dropFirst("JadeAPI.".count)) }
        switch text {
        case "Void", "()": return "performVoid"
        case "Data", "Foundation.Data": return "performData"
        case "String", "Swift.String": return "performString"
        case "Response": return "performResponse"
        default: return "perform"
        }
    }
}
