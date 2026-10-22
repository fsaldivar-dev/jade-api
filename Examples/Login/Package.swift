// swift-tools-version: 6.2
import PackageDescription

// Ejemplo: login con entornos (dev, prod, mock) y repositorios declarados con @Repository.
//   swift run --package-path Examples/Login                 (macOS, entorno por defecto: mock)
//   swift run --package-path Examples/Login -- --stage=dev
let package = Package(
    name: "Login",
    platforms: [.macOS(.v14)],
    dependencies: [
        // `name:` fija la identidad: SwiftPM la derivaría del nombre de la carpeta.
        .package(name: "JadeAPI", path: "../.."),
        // Dependencia directa del núcleo para poder activar su plugin de registro.
        // TODO(1.1.0): `from: "1.1.0"` cuando se publique.
        .package(url: "https://github.com/fsaldivar-dev/experimental-annotation-swift.git", branch: "feature/markers-in-protocols"),
    ],
    targets: [
        .executableTarget(
            name: "Login",
            dependencies: [.product(name: "JadeAPI", package: "JadeAPI")],
            // Genera las declaraciones de @Logged y @Retry a partir de los tipos @Annotation.
            plugins: [.plugin(name: "AnnotationRegistry", package: "experimental-annotation-swift")]
        ),
    ]
)
