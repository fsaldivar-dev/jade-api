//
//  Plugin.swift
//  JadeAPIMacros
//
//  @Repository genera el cliente de un protocolo; @Api es un marcador que @Repository lee.
//

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct JadeAPIPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [RepositoryMacro.self, ApiMacro.self]
}
