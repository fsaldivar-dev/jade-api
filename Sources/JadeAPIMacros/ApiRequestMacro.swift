import SwiftSyntax
import SwiftSyntaxMacros

/// `@ApiRequest`: genera la conformidad a `ApiRequest` leyendo los campos del `struct` y su tipo.
/// `Path<T>`/`Query<T>`/`Header<T>`/`Body<T>` colocan el valor explícitamente; cualquier otro campo
/// (pelón o con `@Parameter`) infiere por el verbo del endpoint.
public struct ApiRequestMacro: ExtensionMacro {
    enum Kind { case path, query, header, body, parameter }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.error(node, id: "notStruct", "@ApiRequest can only be applied to a struct")
            return []
        }
        let access = structDecl.modifiers.contains { $0.name.tokenKind == .keyword(.public) } ? "public " : ""

        var fields: [(label: String, kind: Kind, value: String)] = []
        for member in structDecl.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            if variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) { continue }
            // Tipo de la declaración: el de la última ligadura que lo tenga (cubre `var a, b, c: Int`).
            let declType = variable.bindings.reversed().compactMap { $0.typeAnnotation?.type }.first
            for binding in variable.bindings {
                if binding.accessorBlock != nil { continue }   // propiedad calculada: no se envía
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                guard let fieldType = binding.typeAnnotation?.type ?? declType else {
                    context.error(binding, id: "needsType", "every @ApiRequest field needs a type annotation")
                    continue
                }
                let (kind, wrapped) = classify(fieldType)
                let value = wrapped ? "self.\(name).wrappedValue" : "self.\(name)"
                fields.append((name, kind, value))
            }
        }

        if fields.contains(where: { $0.kind == .body }), fields.contains(where: { $0.kind == .parameter }) {
            context.error(node, id: "bodyAndParameters", "with a Body<…> field, the rest must be Path/Query/Header, not plain @Parameter fields")
            return []
        }

        var lines: [String] = ["var __i = JadeAPI.ApiRequestInputs()", "var __body: [(String, any Encodable)] = []"]
        for field in fields {
            switch field.kind {
            case .path:
                lines.append("__i.pathValues[\"\(field.label)\"] = JadeAPI.ParameterValue.text(\(field.value)) ?? \"\"")
            case .query:
                lines.append("__i.query.append((\"\(field.label)\", JadeAPI.ParameterValue.text(\(field.value))))")
            case .header:
                lines.append("if let __v = JadeAPI.ParameterValue.text(\(field.value)) { __i.headers[\"\(field.label)\"] = __v }")
            case .body:
                lines.append("__i.body = .value(\(field.value))")
            case .parameter:
                lines.append("if method.carriesBody { __body.append((\"\(field.label)\", \(field.value))) } else { __i.query.append((\"\(field.label)\", JadeAPI.ParameterValue.text(\(field.value)))) }")
            }
        }
        lines.append("if !__body.isEmpty { __i.body = .fields(__body) }")
        lines.append("return __i")

        let body = lines.joined(separator: "\n        ")
        let name = type.trimmedDescription
        return [try ExtensionDeclSyntax("""
        extension \(raw: name): JadeAPI.ApiRequest {
            \(raw: access)func _inputs(method: JadeAPI.HTTPMethod) -> JadeAPI.ApiRequestInputs {
                \(raw: body)
            }
        }
        """)]
    }

    /// Clasifica un campo por su tipo. `Path/Query/Header/Body<T>` son explícitos; el resto, parámetro.
    static func classify(_ type: TypeSyntax) -> (Kind, wrapped: Bool) {
        var current = type
        while let attributed = current.as(AttributedTypeSyntax.self) { current = attributed.baseType }
        if let identifier = current.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause != nil {
            switch identifier.name.text {
            case "Path": return (.path, true)
            case "Query": return (.query, true)
            case "Header": return (.header, true)
            case "Body": return (.body, true)
            default: break
            }
        }
        return (.parameter, false)
    }
}

/// `@Parameter`: marcador legible sobre un campo de `@ApiRequest`. No genera nada; un campo pelón se
/// trata igual. `@ApiRequest` decide el destino por el tipo del campo.
public struct ParameterMarkerMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}
