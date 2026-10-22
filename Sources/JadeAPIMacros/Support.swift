import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - Diagnósticos

struct JadeDiagnostic: DiagnosticMessage {
    let message: String
    let id: String
    let severity: DiagnosticSeverity
    var diagnosticID: MessageID { MessageID(domain: "JadeAPI", id: id) }
}

extension MacroExpansionContext {
    func error(_ node: some SyntaxProtocol, id: String, _ message: String) {
        diagnose(Diagnostic(node: Syntax(node), message: JadeDiagnostic(message: message, id: id, severity: .error)))
    }
    func warning(_ node: some SyntaxProtocol, id: String, _ message: String) {
        diagnose(Diagnostic(node: Syntax(node), message: JadeDiagnostic(message: message, id: id, severity: .warning)))
    }
}

// MARK: - Atributos

enum Attributes {
    static func simpleName(_ attribute: AttributeSyntax) -> String? {
        if let id = attribute.attributeName.as(IdentifierTypeSyntax.self) { return id.name.text }
        if let member = attribute.attributeName.as(MemberTypeSyntax.self) { return member.name.text }
        return nil
    }

    static func find(_ name: String, in attributes: AttributeListSyntax) -> AttributeSyntax? {
        attributes.lazy.compactMap { $0.as(AttributeSyntax.self) }.first { simpleName($0) == name }
    }

    /// Todos los atributos menos los indicados, como texto, para copiarlos al tipo generado.
    static func copying(_ attributes: AttributeListSyntax, excluding names: Set<String>) -> [String] {
        attributes.compactMap { element in
            guard let attribute = element.as(AttributeSyntax.self) else { return nil }
            if let name = simpleName(attribute), names.contains(name) { return nil }
            return attribute.trimmedDescription
        }
    }
}

// MARK: - Inferencia por nombre

enum Inference {
    static let verbs: [String: String] = [
        "get": "get", "fetch": "get", "find": "get", "list": "get", "load": "get",
        "post": "post", "create": "post", "add": "post", "send": "post",
        "put": "put", "replace": "put",
        "patch": "patch", "update": "patch",
        "delete": "delete", "remove": "delete",
    ]

    /// Divide camelCase en palabras en minúscula: `getUserProfile` → `["get", "user", "profile"]`.
    static func words(_ identifier: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in identifier {
            if character.isUppercase, !current.isEmpty {
                words.append(current.lowercased()); current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    /// (verbo inferido o nil, ruta inferida)
    static func infer(from functionName: String) -> (method: String?, path: String) {
        var parts = words(functionName)
        var method: String?
        if let first = parts.first, let verb = verbs[first] {
            method = verb
            parts.removeFirst()
        }
        let path = parts.isEmpty ? "/" : "/" + parts.joined(separator: "-")
        return (method, path)
    }
}

// MARK: - Argumentos de @Api

struct ApiArguments {
    var path: String?
    var method: String?
    var timeout: String?

    init(_ attribute: AttributeSyntax, in context: some MacroExpansionContext) {
        guard case .argumentList(let list)? = attribute.arguments else { return }
        for argument in list {
            if argument.label == nil {
                if let literal = argument.expression.as(StringLiteralExprSyntax.self) {
                    if literal.segments.contains(where: { $0.is(ExpressionSegmentSyntax.self) }) {
                        context.error(literal, id: "interpolation", "@Api path must be a plain string literal, without interpolation")
                    } else {
                        path = literal.segments.map { $0.trimmedDescription }.joined()
                    }
                } else {
                    context.error(argument.expression, id: "pathLiteral", "@Api path must be a string literal")
                }
            } else if argument.label?.text == "timeout" {
                timeout = argument.expression.trimmedDescription
            } else if argument.label?.text == "method" {
                if let member = argument.expression.as(MemberAccessExprSyntax.self) {
                    method = member.declName.baseName.text
                } else {
                    context.error(argument.expression, id: "method", "@Api method must be written as .get, .post, …")
                }
            }
        }
    }
}

// MARK: - Parámetros del requisito

struct ParameterInfo {
    enum Kind { case path, query, header, body, field }

    let label: String          // nombre externo (para path, query, header, campo)
    let name: String           // nombre interno (para leer el valor)
    let kind: Kind
    let wrapped: Bool          // viene envuelto en Path/Query/Header/Body

    /// Expresión que lee el valor.
    var valueExpression: String { wrapped ? "\(name).wrappedValue" : name }

    static func analyze(_ parameters: FunctionParameterListSyntax, method: String, path: String) -> [ParameterInfo] {
        let pathNames = Set(path.split(separator: "/").filter { $0.hasPrefix(":") }.map { String($0.dropFirst()) })
        let carriesBody = ["post", "put", "patch"].contains(method)
        return parameters.map { parameter in
            let external = parameter.firstName.text
            let internalName = (parameter.secondName ?? parameter.firstName).text
            let label = external == "_" ? internalName : external
            var type = parameter.type
            while let attributed = type.as(AttributedTypeSyntax.self) { type = attributed.baseType }
            if let identifier = type.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause != nil {
                switch identifier.name.text {
                case "Path": return ParameterInfo(label: label, name: internalName, kind: .path, wrapped: true)
                case "Query": return ParameterInfo(label: label, name: internalName, kind: .query, wrapped: true)
                case "Header": return ParameterInfo(label: label, name: internalName, kind: .header, wrapped: true)
                case "Body": return ParameterInfo(label: label, name: internalName, kind: .body, wrapped: true)
                default: break
                }
            }
            if pathNames.contains(label) { return ParameterInfo(label: label, name: internalName, kind: .path, wrapped: false) }
            return ParameterInfo(label: label, name: internalName, kind: carriesBody ? .field : .query, wrapped: false)
        }
    }
}
