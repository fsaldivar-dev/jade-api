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
        let service = Self.serviceArgument(of: node, in: context)
        var methods: [String] = []

        let protocolOptions = Self.optionsExpression(from: proto.attributes, apiTimeout: nil)
        let protocolRetries = Attributes.find("Retries", in: proto.attributes)
        let protocolUnwrap = Self.stringArgument(of: Attributes.find("Unwrap", in: proto.attributes), in: context)
        let protocolAuthenticated = Attributes.find("Authenticated", in: proto.attributes) != nil
        let protocolErrorMapper = Self.typeArgument(of: Attributes.find("ErrorTransform", in: proto.attributes))

        for member in proto.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else {
                if let attributed = member.decl.asProtocol(WithAttributesSyntax.self),
                   let api = Attributes.find("Api", in: attributed.attributes) {
                    context.error(api, id: "notFunction", "@Api can only be applied to functions")
                }
                continue
            }
            if let generated = generate(function, access: access, protocolOptions: protocolOptions, protocolRetries: protocolRetries, protocolUnwrap: protocolUnwrap, protocolErrorMapper: protocolErrorMapper, protocolAuthenticated: protocolAuthenticated, in: context) {
                methods.append(generated)
            }
        }

        let name = proto.name.text
        let body = methods.isEmpty ? "" : "\n\n" + methods.joined(separator: "\n\n")
        let assignment = "self.client = " + Self.clientChain(for: proto, in: context)
        let serviceLiteral = service.map { "\"\($0)\"" } ?? "JadeAPI.Environment.defaultService"
        return [DeclSyntax(stringLiteral: """
        @AnnotationSwift.Decorable
        \(access)struct \(name)Client: \(name), Sendable {
            /// Servicio del ``Environment`` al que pertenece este repositorio.
            \(access)static let service: String = \(serviceLiteral)

            \(access)let client: JadeAPI.AppClient

            \(access)init(client: JadeAPI.AppClient) {
                \(assignment)
            }

            /// Cliente del servicio `\(service ?? "default")` resuelto por el entorno.
            \(access)init(environment: JadeAPI.Environment) throws {
                self.init(client: try environment.client(for: Self.service))
            }

            /// Fábrica: `\(name)Client.live(in: environment)`.
            \(access)static func live(in environment: JadeAPI.Environment) throws -> \(name)Client {
                try \(name)Client(environment: environment)
            }\(body)
        }
        """)]
    }

    /// `@Repository(service: "payments")` → `"payments"`.
    static func serviceArgument(of node: AttributeSyntax, in context: some MacroExpansionContext) -> String? {
        guard case .argumentList(let list)? = node.arguments,
              let argument = list.first(where: { $0.label?.text == "service" }) else { return nil }
        guard let literal = argument.expression.as(StringLiteralExprSyntax.self),
              !literal.segments.contains(where: { $0.is(ExpressionSegmentSyntax.self) }) else {
            context.error(argument.expression, id: "service", "@Repository(service:) must be a plain string literal")
            return nil
        }
        let value = literal.segments.map { $0.trimmedDescription }.joined()
        return value.isEmpty ? nil : value
    }

    /// Atributos que @Repository consume y no copia al método generado.
    static let consumedAttributes: Set<String> = ["Api", "Socket", "Transform", "Unwrap", "ErrorTransform", "Interceptors", "Retries", "CacheFor", "SingleFlight", "Idempotent", "Headers", "BaseURL", "KeyMapping", "Authenticated", "Public"]

    /// Lo que el `init(client:)` generado hace con el cliente recibido, de afuera hacia adentro:
    /// `@BaseURL` → `@Headers` → `@KeyMapping` → `@Interceptors`. Sin atributos, el cliente tal cual.
    static func clientChain(for proto: ProtocolDeclSyntax, in context: some MacroExpansionContext) -> String {
        var chain = "client"
        if let base = Attributes.find("BaseURL", in: proto.attributes), let literal = stringArgument(of: base, in: context) {
            if literal.hasPrefix("/") || literal.hasPrefix("https://") || literal.hasPrefix("http://") {
                chain += ".with(base: \"\(literal)\")"
            } else {
                context.error(base, id: "baseURL", "@BaseURL expects a path prefix (\"/v2\") or a full URL (\"https://…\")")
            }
        }
        if let headers = Attributes.find("Headers", in: proto.attributes), let expression = firstArgument(of: headers) {
            chain += ".with(headers: \(expression))"
        }
        if let mapping = Attributes.find("KeyMapping", in: proto.attributes), case .argumentList(let arguments)? = mapping.arguments, !arguments.isEmpty {
            let list = arguments.map { argument in
                argument.label == nil ? "keys: \(argument.expression.trimmedDescription)" : argument.trimmedDescription.trimmingTrailingComma()
            }.joined(separator: ", ")
            chain += ".with(\(list))"
        }
        if let interceptors = Attributes.find("Interceptors", in: proto.attributes),
           case .argumentList(let arguments)? = interceptors.arguments, !arguments.isEmpty {
            let list = arguments.map { $0.expression.trimmedDescription }.joined(separator: ", ")
            chain += ".with(interceptors: [\(list)])"
        }
        return chain
    }

    /// Primer argumento de un atributo, como texto.
    static func firstArgument(of attribute: AttributeSyntax) -> String? {
        guard case .argumentList(let list)? = attribute.arguments, let first = list.first else { return nil }
        return first.expression.trimmedDescription
    }

    // MARK: - Un método por requisito

    private static func generate(_ function: FunctionDeclSyntax, access: String, protocolOptions: String?, protocolRetries: AttributeSyntax?, protocolUnwrap: String?, protocolErrorMapper: String?, protocolAuthenticated: Bool, in context: some MacroExpansionContext) -> String? {
        let socket = Attributes.find("Socket", in: function.attributes)
        guard let api = Attributes.find("Api", in: function.attributes) ?? socket else {
            context.error(function.name, id: "missingApi", "every requirement of a @Repository needs @Api or @Socket")
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

        // Verbo y ruta: explícitos o inferidos. Un @Socket es un GET con kind "socket".
        var arguments = ApiArguments(api, in: context)
        if socket != nil {
            arguments.kind = "socket"
            arguments.method = "get"
            if arguments.path == nil {
                context.error(api, id: "socketPath", "@Socket needs a path, e.g. @Socket(\"/ws/chat/:room\")")
                return nil
            }
        }
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

        // Seguridad: un POST/PATCH solo se reintenta con @Idempotent.
        let isIdempotentMethod = ["get", "head", "options", "put", "delete"].contains(method)
        let hasIdempotent = Attributes.find("Idempotent", in: function.attributes) != nil
        let ownRetries = Attributes.find("Retries", in: function.attributes)
        if !isIdempotentMethod, !hasIdempotent, let retries = ownRetries ?? protocolRetries, !Self.isSingleAttempt(retries) {
            context.error(ownRetries ?? api, id: "unsafeRetry",
                          "'\(function.name.text)' is a \(method.uppercased()) and could be executed twice: add @Idempotent (sends an Idempotency-Key) or @Retries(1) to opt out")
            return nil
        }

        for name in ["BaseURL", "KeyMapping"] {
            if let misplaced = Attributes.find(name, in: function.attributes) {
                context.error(misplaced, id: "protocolOnly", "@\(name) applies to the whole repository: move it onto the protocol")
                return nil
            }
        }

        // Construcción del Endpoint.
        let signature = function.name.text + "(" + function.signature.parameterClause.parameters.map { "\($0.firstName.text):" }.joined() + ")"
        let staticHeaders = Attributes.find("Headers", in: function.attributes).flatMap(Self.firstArgument) ?? "[:]"
        let requiresAuth = (protocolAuthenticated || Attributes.find("Authenticated", in: function.attributes) != nil)
            && Attributes.find("Public", in: function.attributes) == nil
        let endpointOptions = optionsExpression(from: function.attributes, apiTimeout: arguments.timeout, socketPolicy: socket.flatMap(Self.socketPolicyExpression), requiresAuth: requiresAuth)
        let optionsArgument: String
        switch (endpointOptions, protocolOptions) {
        case (nil, nil): optionsArgument = ""
        case (let own?, nil): optionsArgument = ", options: \(own)"
        case (nil, let base?): optionsArgument = ", options: \(base)"
        case (let own?, let base?): optionsArgument = ", options: \(own).merging(over: \(base))"
        }
        var statements: [String] = []

        let requestParams = parameters.filter { $0.kind == .request }
        if let request = requestParams.first {
            // Objeto de petición: debe ser el único parámetro; sus campos arman el endpoint.
            if parameters.count > 1 {
                context.error(function.signature, id: "requestAlone",
                              "an @ApiRequest value must be the only parameter of '\(function.name.text)'; move the other fields inside it")
                return nil
            }
            statements.append("let __inputs = \(request.valueExpression)._inputs(method: .\(method))")
            statements.append("var __headers: [String: String] = \(staticHeaders)")
            statements.append("for (__name, __value) in __inputs.headers { __headers[__name] = __value }")
            if hasIdempotent {
                statements.append("__headers[\"Idempotency-Key\"] = Foundation.UUID().uuidString")
            }
            statements.append("""
            let __endpoint = JadeAPI.Endpoint(name: "\(signature)", method: .\(method), path: "\(path)", pathParameters: __inputs.pathValues, query: __inputs.query, headers: __headers, body: __inputs.body\(optionsArgument))
            """)
        } else {
            let headerParameters = parameters.filter { $0.kind == .header }
            statements.append("\(headerParameters.isEmpty && !hasIdempotent ? "let" : "var") __headers: [String: String] = \(staticHeaders)")
            if hasIdempotent {
                statements.append("__headers[\"Idempotency-Key\"] = Foundation.UUID().uuidString")
            }
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
            let __endpoint = JadeAPI.Endpoint(name: "\(signature)", method: .\(method), path: "\(path)", pathParameters: [\(pathParameters.isEmpty ? ":" : pathParameters.joined(separator: ", "))], query: [\(query.joined(separator: ", "))], headers: __headers, body: \(body)\(optionsArgument))
            """)
        }
        // Transformadores: @Unwrap, @Transform, @ErrorTransform (requisito gana sobre protocolo).
        let ownUnwrap = stringArgument(of: Attributes.find("Unwrap", in: function.attributes), in: context)
        let mapper = typeArgument(of: Attributes.find("Transform", in: function.attributes))
        let errorMapper = typeArgument(of: Attributes.find("ErrorTransform", in: function.attributes)) ?? protocolErrorMapper
        let perform = performCall(for: function, kind: arguments.kind)
        if arguments.kind != "request", ownUnwrap != nil || mapper != nil || errorMapper != nil {
            context.error(api, id: "streamTransform", "@Unwrap, @Transform and @ErrorTransform only apply to kind: .request")
            return nil
        }
        if arguments.kind != "request", let expected = Self.expectedReturn(for: arguments.kind),
           !(function.signature.returnClause?.type.trimmedDescription ?? "").hasPrefix(expected) {
            context.error(function.signature, id: "kindReturn", "kind: .\(arguments.kind) must return \(expected)…")
            return nil
        }
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

    /// `@Retries(1)` desactiva reintentos; se usa para no exigir @Idempotent.
    static func isSingleAttempt(_ retries: AttributeSyntax) -> Bool {
        guard case .argumentList(let list)? = retries.arguments, let first = list.first, first.label == nil else { return false }
        return first.expression.trimmedDescription == "1"
    }

    /// `@Retries(3, backoff: .constant(.seconds(1))) @CacheFor(.seconds(60)) @SingleFlight` + `timeout:` de @Api
    /// → `JadeAPI.RequestOptions(timeout: …, cache: …, retry: JadeAPI.RetryPolicy(attempts: 3, backoff: …), singleFlight: true)`.
    static func optionsExpression(from attributes: AttributeListSyntax, apiTimeout: String?, socketPolicy: String? = nil, requiresAuth: Bool = false) -> String? {
        // El orden sigue al de `RequestOptions.init`: timeout, cache, retry, singleFlight, socket, requiresAuth.
        var fields: [String] = []
        if let timeout = apiTimeout { fields.append("timeout: \(timeout)") }
        if let cache = Attributes.find("CacheFor", in: attributes), case .argumentList(let list)? = cache.arguments, let first = list.first {
            fields.append("cache: \(first.expression.trimmedDescription)")
        }
        if let retries = Attributes.find("Retries", in: attributes), case .argumentList(let list)? = retries.arguments {
            let inner = list.map { argument in
                argument.label == nil ? "attempts: \(argument.expression.trimmedDescription)" : argument.trimmedDescription.trimmingTrailingComma()
            }.joined(separator: ", ")
            fields.append("retry: JadeAPI.RetryPolicy(\(inner))")
        }
        if Attributes.find("SingleFlight", in: attributes) != nil { fields.append("singleFlight: true") }
        if let socketPolicy { fields.append("socket: \(socketPolicy)") }
        if requiresAuth { fields.append("requiresAuth: true") }
        return fields.isEmpty ? nil : "JadeAPI.RequestOptions(\(fields.joined(separator: ", ")))"
    }

    /// `@Socket("/ws", reconnect: .constant(.seconds(1)), keepAlive: .seconds(30))`
    /// → `JadeAPI.SocketPolicy(reconnect: .constant(.seconds(1)), keepAlive: .seconds(30))`; `nil` sin argumentos de política.
    static func socketPolicyExpression(of attribute: AttributeSyntax) -> String? {
        guard case .argumentList(let list)? = attribute.arguments else { return nil }
        let fields = list.compactMap { argument -> String? in
            guard let label = argument.label?.text, ["reconnect", "maxReconnects", "keepAlive"].contains(label) else { return nil }
            return "\(label): \(argument.expression.trimmedDescription)"
        }
        return fields.isEmpty ? nil : "JadeAPI.SocketPolicy(\(fields.joined(separator: ", ")))"
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

    /// Tipo de retorno que exige cada `kind` de stream o transferencia.
    static func expectedReturn(for kind: String) -> String? {
        switch kind {
        case "bytes": "AsyncThrowingStream<Data"
        case "lines": "AsyncThrowingStream<String"
        case "ndjson": "AsyncThrowingStream<"
        case "sse": "AsyncThrowingStream<ServerEvent"
        case "download": "Download"
        case "upload": "Upload"
        case "socket": "Socket<"
        default: nil
        }
    }

    /// Variante de `perform` según el tipo de retorno y el `kind`; la macro lo sabe en compilación.
    private static func performCall(for function: FunctionDeclSyntax, kind: String = "request") -> String {
        switch kind {
        case "bytes": return "performBytes"
        case "lines": return "performLines"
        case "ndjson": return "performNDJSON"
        case "sse": return "performServerEvents"
        case "download": return "performDownload"
        case "upload": return "performUpload"
        case "socket": return "openSocket"
        default: break
        }
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


extension String {
    func trimmingTrailingComma() -> String {
        var text = self
        while text.hasSuffix(",") || text.hasSuffix(" ") { text.removeLast() }
        return text
    }
}


// MARK: - Rol extension: `let repo: UsersRepository = try .live(in: environment)`

extension RepositoryMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let proto = declaration.as(ProtocolDeclSyntax.self) else { return [] }
        let access = proto.modifiers.contains { $0.name.tokenKind == .keyword(.public) } ? "public " : ""
        let name = type.trimmedDescription
        return [try ExtensionDeclSyntax("""
        extension \(raw: name) where Self == \(raw: name)Client {
            /// Implementación real resuelta por el entorno: `let repo: \(raw: name) = try .live(in: environment)`.
            \(raw: access)static func live(in environment: JadeAPI.Environment) throws -> Self {
                try \(raw: name)Client(environment: environment)
            }
        }
        """)]
    }
}
