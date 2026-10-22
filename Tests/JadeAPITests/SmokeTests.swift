import JadeAPI
import Testing

@Suite("Esqueleto")
struct SmokeTests {
    @Test("El paquete compila y reexporta AnnotationSwift")
    func smoke() {
        #expect(JadeAPI.version == "0.0.1")
        // Si esto compila, AnnotationSwift llega vía @_exported import.
        let property = Property(name: "x", type: "T", file: "f", line: 1)
        #expect(property.description == "T.x")
    }
}
