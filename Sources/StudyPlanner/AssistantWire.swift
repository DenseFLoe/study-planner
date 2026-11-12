import Foundation

/// Non-streaming OpenAI-compatible Chat Completions and Anthropic Messages.
/// Only canonical messages and whitelisted string arguments enter the tool loop.
enum AssistantWire {
    struct Call: Sendable {
        let id: String
        let name: String
        let input: [String: String]
    }
    struct Reply {
        let text: String
        let calls: [Call]
        let message: [String: Any]
    }
    static func reasoning(_ configuration: AssistantConfiguration) -> Bool {
        configuration.provider != .anthropic && configuration.model.lowercased().range(
            of: #"^(?:o[1-9](?:-.*)?|gpt-(?:[5-9]|[1-9][0-9])(?:[.-].*)?)$"#,
            options: .regularExpression) != nil
    }
    static func messages(_ messages: [AssistantWireMessage], configuration: AssistantConfiguration,
                         instructions: String) -> [[String: Any]] {
        let prefix: [[String: Any]] = configuration.provider == .anthropic ? [] : [
            ["role": reasoning(configuration) ? "developer" : "system", "content": instructions]
        ]
        return prefix + messages.map { ["role": $0.role, "content": $0.content] }
    }
    static func request(configuration: AssistantConfiguration, messages: [[String: Any]], instructions: String) throws -> AssistantRequest {
        let anthropic = configuration.provider == .anthropic
        let tools: [[String: Any]] = (AssistantTools.definitions + AssistantActions.allDefinitions).map { definition in
            let properties = definition.fields.mapValues { ["type": "string", "maxLength": 128, "description": $0] as [String: Any] }
            let schema: [String: Any] = ["type": "object", "properties": properties,
                                        "required": definition.fields.keys.sorted(), "additionalProperties": false]
            if anthropic { return ["name": definition.name, "description": definition.description, "input_schema": schema] }
            return ["type": "function", "function": ["name": definition.name, "description": definition.description, "parameters": schema]]
        }
        var root: [String: Any] = ["model": configuration.model, "messages": messages, "tools": tools, "stream": false,
                                  reasoning(configuration) ? "max_completion_tokens" : "max_tokens": 4096]
        if anthropic {
            root["system"] = instructions
        } else { root["tool_choice"] = "auto" }
        return .init(id: UUID().uuidString, configuration: configuration, url: try configuration.endpoint().absoluteString,
                     body: try encode(root))
    }
    static func encode(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    private static func object(_ text: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw AssistantError.protocolError
        }
        return value
    }
    private static func call(id: String?, name: String?, arguments: [String: Any]?) throws -> Call {
        guard let id, !id.isEmpty, id.utf8.count <= 128, !id.contains(where: { $0.isWhitespace }),
              let name, let definition = (AssistantTools.definitions + AssistantActions.allDefinitions).first(where: { $0.name == name }),
              let arguments, Set(arguments.keys) == Set(definition.fields.keys) else { throw AssistantError.protocolError }
        var input: [String: String] = [:]
        for (field, value) in arguments {
            guard let value = value as? String, value.utf16.count <= 128 else { throw AssistantError.protocolError }
            input[field] = value
        }
        return .init(id: id, name: name, input: input)
    }
    static func reply(_ text: String, configuration: AssistantConfiguration) throws -> Reply {
        let root = try object(text)
        var answer = "", calls: [Call] = [], message: [String: Any]
        if configuration.provider == .anthropic {
            guard let content = root["content"] as? [[String: Any]], let reason = root["stop_reason"] as? String else {
                throw AssistantError.protocolError
            }
            var retained: [[String: Any]] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    guard let value = block["text"] as? String else { throw AssistantError.protocolError }
                    answer += value; retained.append(["type": "text", "text": value])
                case "tool_use":
                    let call = try call(id: block["id"] as? String, name: block["name"] as? String,
                                        arguments: block["input"] as? [String: Any])
                    calls.append(call)
                    retained.append(["type": "tool_use", "id": call.id, "name": call.name, "input": call.input])
                default: throw AssistantError.protocolError
                }
            }
            guard reason == (calls.isEmpty ? "end_turn" : "tool_use") else { throw AssistantError.protocolError }
            message = ["role": "assistant", "content": retained]
        } else {
            guard let choices = root["choices"] as? [[String: Any]], choices.count == 1,
                  let value = choices[0]["message"] as? [String: Any],
                  let reason = choices[0]["finish_reason"] as? String else { throw AssistantError.protocolError }
            if let content = value["content"], !(content is NSNull) {
                guard let content = content as? String else { throw AssistantError.protocolError }; answer = content
            }
            var retained: [[String: Any]] = []
            if let raw = value["tool_calls"], !(raw is NSNull) {
                guard let raw = raw as? [[String: Any]] else { throw AssistantError.protocolError }
                for item in raw {
                    guard item["type"] as? String == "function", let function = item["function"] as? [String: Any],
                          let arguments = function["arguments"] as? String, arguments.utf8.count <= 16_000 else {
                        throw AssistantError.protocolError
                    }
                    let call = try call(id: item["id"] as? String, name: function["name"] as? String, arguments: object(arguments))
                    calls.append(call)
                    retained.append(["id": call.id, "type": "function", "function": ["name": call.name, "arguments": try encode(call.input)]])
                }
            }
            guard reason == (calls.isEmpty ? "stop" : "tool_calls") else { throw AssistantError.protocolError }
            message = ["role": "assistant", "content": answer.isEmpty ? NSNull() : answer as Any]
            if !calls.isEmpty {
                message["tool_calls"] = retained
                // DeepSeek reasoner requires the preceding reasoning alongside tool calls.
                if let reasoning = value["reasoning_content"] as? String { message["reasoning_content"] = reasoning }
            }
        }
        guard calls.count <= 24, answer.utf8.count <= 64_000,
              !calls.isEmpty || !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantError.protocolError
        }
        return .init(text: answer, calls: calls, message: message)
    }
}
