// swift-tools-version: 6.2
import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "JadeAPI",
    platforms: [
        .macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1),
    ],
    products: [
        .library(name: "JadeAPI", targets: ["JadeAPI"]),
        /// Dobles de prueba (`MockClient`). Solo para targets de test y previews: la app no lo enlaza.
        .library(name: "JadeTesting", targets: ["JadeTesting"]),
        /// Build-tool plugin: registra tus decoradores `@Annotation` para poder usar `@Logged` directo.
        .plugin(name: "JadeRegistry", targets: ["JadeRegistry"]),
    ],
    dependencies: [
        // Anotaciones apilables: @Decorable, Decorator, GuardDecorator, HookDecorator, MarkerMacro.
        // TODO(1.0.2): volver a `from: "1.0.2"` cuando se publique el release del núcleo.
        .package(url: "https://github.com/fsaldivar-dev/experimental-annotation-swift.git", branch: "feature/markers-in-protocols"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"605.0.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
    ],
    targets: [
        // Plugin del compilador: @Repository (genera el cliente) y los marcadores propios de Jade.
        .macro(
            name: "JadeAPIMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            ]
        ),
        // Runtime público: cliente, Request/Response, Stage, MockClient, errores.
        .target(
            name: "JadeAPI",
            dependencies: [
                "JadeAPIMacros",
                .product(name: "AnnotationSwift", package: "experimental-annotation-swift"),
            ]
        ),
        // Plugin de registro de anotaciones, sobre la herramienta del núcleo.
        .plugin(
            name: "JadeRegistry",
            capability: .buildTool(),
            dependencies: [.product(name: "annotation-registry", package: "experimental-annotation-swift")]
        ),

        .target(name: "JadeTesting", dependencies: ["JadeAPI"]),

        .testTarget(
            name: "JadeAPITests",
            dependencies: ["JadeAPI", "JadeTesting"],
            plugins: ["JadeRegistry"]
        ),
        .testTarget(
            name: "JadeAPIMacrosTests",
            dependencies: [
                "JadeAPIMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
