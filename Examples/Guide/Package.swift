// swift-tools-version: 6.2
import PackageDescription

// Guía de JadeAPI: una pestaña por pieza, contra APIs públicas reales (entorno `live`) o contra un
// servidor falso (entorno `mock`). Cada pantalla es un archivo de vista y un store pequeño; el
// comentario de arriba de cada uno dice qué enseña y qué declaración lo hace funcionar.
//
//   swift run  --package-path Examples/Guide                   (macOS; mock por defecto)
//   swift run  --package-path Examples/Guide -- --stage=live   (APIs reales)
//   swift test --package-path Examples/Guide                   (lógica sin UI contra los fixtures)
let package = Package(
    name: "Guide",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GuideCore", targets: ["GuideCore"]),
    ],
    dependencies: [
        // `name:` fija la identidad: SwiftPM la derivaría del nombre de la carpeta.
        .package(name: "JadeAPI", path: "../.."),
    ],
    targets: [
        .target(
            name: "GuideCore",
            dependencies: [
                .product(name: "JadeAPI", package: "JadeAPI"),
                // Solo por los fixtures del entorno `mock`; una app real los dejaría en un target de pruebas o previews.
                .product(name: "JadeTesting", package: "JadeAPI"),
            ],
            // Genera las declaraciones de @Logged y @Retry a partir de los tipos @Annotation.
            plugins: [.plugin(name: "JadeRegistry", package: "JadeAPI")]
        ),
        .executableTarget(name: "Guide", dependencies: ["GuideCore"]),
        .testTarget(name: "GuideCoreTests", dependencies: ["GuideCore"]),
    ]
)
