import JadeAPIMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class ApiRequestMacroTests: XCTestCase {
    func testGeneratesInputs() {
        assertMacroExpansion(
            """
            @ApiRequest
            struct NewUser {
                @Parameter var name: String
                @Parameter var age: Int?
                var trace: Header<String>
            }
            """,
            expandedSource: """
            struct NewUser {
                var name: String
                var age: Int?
                var trace: Header<String>
            }

            extension NewUser: JadeAPI.ApiRequest {
                func _inputs(method: JadeAPI.HTTPMethod) -> JadeAPI.ApiRequestInputs {
                    var __i = JadeAPI.ApiRequestInputs()
                    var __body: [(String, any Encodable)] = []
                    if method.carriesBody {
                        __body.append(("name", self.name))
                    } else {
                        __i.query.append(("name", JadeAPI.ParameterValue.text(self.name)))
                    }
                    if method.carriesBody {
                        __body.append(("age", self.age))
                    } else {
                        __i.query.append(("age", JadeAPI.ParameterValue.text(self.age)))
                    }
                    if let __v = JadeAPI.ParameterValue.text(self.trace.wrappedValue) {
                        __i.headers["trace"] = __v
                    }
                    if !__body.isEmpty {
                        __i.body = .fields(__body)
                    }
                    return __i
                }
            }
            """,
            macros: macros
        )
    }
}
