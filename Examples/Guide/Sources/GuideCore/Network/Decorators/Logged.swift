import JadeAPI

/// Deja rastro de cada llamada en el ``CallLog`` de la tarea actual. La macro construye el decorador
/// sin argumentos (`@Logged`), así que el destino no se inyecta por init: viaja como task-local.
@Annotation
struct Logged: HookDecorator {
    func willCall(_ call: Call) { CallLog.current.append("→ \(call.function)") }
    func didReturn(_ call: Call, result: Any) { CallLog.current.append("← \(call.function) ok") }
    func didThrow(_ call: Call, error: any Error) { CallLog.current.append("✗ \(call.function): \(error)") }
}
