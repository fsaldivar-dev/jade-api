//
//  plugin.swift
//  JadeRegistry
//
//  Build-tool plugin de JadeAPI: genera las declaraciones de marcador de los tipos `@Annotation`
//  (tus decoradores) antes de compilar, reutilizando la herramienta `annotation-registry` de
//  AnnotationSwift. Así quien usa JadeAPI solo depende de jade-api:
//
//      .target(name: "App", dependencies: [.product(name: "JadeAPI", package: "jade-api")],
//              plugins: [.plugin(name: "JadeRegistry", package: "jade-api")])
//

import Foundation
import PackagePlugin

@main
struct JadeRegistry: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let target = target as? SwiftSourceModuleTarget else { return [] }
        let inputs = target.sourceFiles(withSuffix: "swift").map(\.url)
        return [try command(tool: context.tool(named: "annotation-registry").url,
                            workDirectory: context.pluginWorkDirectoryURL,
                            targetName: target.name, inputs: inputs)]
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension JadeRegistry: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        let inputs = target.inputFiles.filter { $0.url.pathExtension == "swift" }.map(\.url)
        return [try command(tool: context.tool(named: "annotation-registry").url,
                            workDirectory: context.pluginWorkDirectoryURL,
                            targetName: target.displayName, inputs: inputs)]
    }
}
#endif

private func command(tool: URL, workDirectory: URL, targetName: String, inputs: [URL]) throws -> Command {
    let output = workDirectory.appending(path: "Annotations+Registry.swift")
    return .buildCommand(
        displayName: "JadeAPI: registrar anotaciones de \(targetName)",
        executable: tool,
        arguments: [output.path()] + inputs.map { $0.path() },
        inputFiles: inputs,
        outputFiles: [output]
    )
}
