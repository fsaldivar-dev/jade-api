//
//  Plugin.swift
//  JadeAPIMacros
//
//  Iteración 0: el plugin existe y compila. @Repository y @Api llegan en la iteración 1.
//

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct JadeAPIPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = []
}
