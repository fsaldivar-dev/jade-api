// swift-tools-version: 6.2
import PackageDescription

// Ejemplo de JadeAPI: login con entornos (dev, prod, mock), dos servicios resueltos por `Environment`,
// y un catálogo que usa interceptores, transformadores, opciones de petición y grupos.
//
//   swift run --package-path Examples/Login                  (macOS, entorno por defecto: mock)
//   swift run --package-path Examples/Login -- --stage=dev
//   swift test --package-path Examples/Login                 (lógica sin UI contra los fixtures)
//
// Estructura:
//   LoginCore   dominio, red (repositorios, DTOs, mappers, decoradores), entorno, features y la raíz de composición
//   Login       la app SwiftUI: entrada y vistas
//   LoginCoreTests
let package = Package(
    name: "Login",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LoginCore", targets: ["LoginCore"]),
    ],
    dependencies: [
        // `name:` fija la identidad: SwiftPM la derivaría del nombre de la carpeta.
        .package(name: "JadeAPI", path: "../.."),
    ],
    targets: [
        .target(
            name: "LoginCore",
            dependencies: [
                .product(name: "JadeAPI", package: "JadeAPI"),
                // Solo por los fixtures del entorno `mock`; una app real los dejaría en un target de pruebas o previews.
                .product(name: "JadeTesting", package: "JadeAPI"),
            ],
            // Genera las declaraciones de @Logged y @Retry a partir de los tipos @Annotation.
            plugins: [.plugin(name: "JadeRegistry", package: "JadeAPI")]
        ),
        .executableTarget(name: "Login", dependencies: ["LoginCore"]),
        .testTarget(name: "LoginCoreTests", dependencies: ["LoginCore"]),
    ]
)
