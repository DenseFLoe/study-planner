import Foundation

/// Scalar request values shared by the native and in-page netdisk transports.
public enum NetdiskJSON: Sendable {
    case string(String), number(Double), bool(Bool)

    public var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        }
    }

    public var javaScriptLiteral: String {
        switch self {
        case .string(let value):
            // A standalone string is a JSON fragment, including the empty passcode.
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            else { return "null" }
            return String(decoding: data, as: UTF8.self)
        case .number(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        }
    }
}
