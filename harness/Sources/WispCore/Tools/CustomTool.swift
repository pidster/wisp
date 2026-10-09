import Foundation
import FoundationModels

/// A tool the user defines in `~/.wisp/config.json` (`tools.custom`): a name, a description, typed
/// arguments, and a command line with `{argument}` placeholders. The model sees an ordinary tool whose
/// schema is built from the definition at run time; a call substitutes the values (strings
/// single-quoted for `/bin/sh`) and runs the line through `run_command`'s runner, so the policy, sandbox,
/// classifier, approval, output bound, and audit apply exactly as they do to a command the model writes
/// itself ([ADR 0036](../../../../docs/decisions/0036-custom-tools.md)). Only the user's own config can
/// define one; a project cannot.
public struct CustomTool: WispTool {
    /// One argument's declaration.
    public struct Argument: Codable, Equatable, Sendable {
        /// `string`, `integer`, `number`, or `boolean`.
        public var type: String
        /// What the model is told about it.
        public var description: String?
        /// For a string, the only values allowed.
        public var `enum`: [String]?
        /// The value used when the model gives none; an argument with a default is optional.
        public var `default`: JSONValue?

        /// Creates a declaration.
        public init(type: String, description: String? = nil, enum: [String]? = nil, default: JSONValue? = nil) {
            self.type = type
            self.description = description
            self.enum = `enum`
            self.default = `default`
        }
    }

    /// One tool's declaration, as written in the config.
    public struct Definition: Codable, Equatable, Sendable {
        /// The name the model calls it by: `snake_case`, not a built-in's.
        public var name: String
        /// What the model is told it does.
        public var description: String
        /// Its arguments by name; every one must appear in `command` as `{name}`.
        public var arguments: [String: Argument]?
        /// The command line, run with `/bin/sh -c`.
        public var command: String
        /// Where it runs; `~` expands. Default: where wisp runs.
        public var workingDirectory: String?
        /// Seconds before it is killed. Default: `commandTimeoutSeconds`.
        public var timeoutSeconds: Int?

        /// Creates a declaration.
        public init(
            name: String, description: String, arguments: [String: Argument]? = nil, command: String,
            workingDirectory: String? = nil, timeoutSeconds: Int? = nil
        ) {
            self.name = name
            self.description = description
            self.arguments = arguments
            self.command = command
            self.workingDirectory = workingDirectory
            self.timeoutSeconds = timeoutSeconds
        }

        /// The argument names in a stable order.
        var argumentNames: [String] { (arguments ?? [:]).keys.sorted() }
    }

    /// Why a definition cannot be used; reported as a malformed config.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// What is wrong, naming the tool.
        case invalid(tool: String, reason: String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .invalid(let tool, let reason): "custom tool '\(tool)': \(reason)"
            }
        }
    }

    /// Argument types a definition may use.
    static let types: Set<String> = ["string", "integer", "number", "boolean"]
    /// Longest description the model is given, so a custom tool cannot crowd a small window.
    static let descriptionLimit = 300
    /// `{name}` placeholders in a command.
    static let placeholderPattern = #"\{([a-z][a-z0-9_]*)\}"#

    /// Checks every definition against the rules and against `reserved` names and each other.
    ///
    /// - Throws: `Failure.invalid` for the first problem.
    public static func validate(_ definitions: [Definition], reserved: Set<String>) throws {
        var seen = reserved
        for definition in definitions {
            try validate(definition)
            guard seen.insert(definition.name).inserted else {
                throw Failure.invalid(
                    tool: definition.name,
                    reason: reserved.contains(definition.name) ? "is a built-in tool's name" : "is defined twice")
            }
        }
    }

    /// Checks one definition.
    ///
    /// - Throws: `Failure.invalid`.
    static func validate(_ definition: Definition) throws {
        func fail(_ reason: String) -> Failure { .invalid(tool: definition.name, reason: reason) }
        guard definition.name.range(of: #"^[a-z][a-z0-9_]{0,39}$"#, options: .regularExpression) != nil else {
            throw fail("the name must be snake_case: a lowercase letter, then letters, digits, or _, up to 40")
        }
        let description = definition.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, description.count <= descriptionLimit else {
            throw fail("the description must be 1 to \(descriptionLimit) characters")
        }
        guard !definition.command.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw fail("the command is empty")
        }
        let used = Set(placeholders(in: definition.command))
        let declared = Set(definition.argumentNames)
        if let missing = used.subtracting(declared).sorted().first {
            throw fail("the command uses {\(missing)}, which is not a declared argument")
        }
        if let unused = declared.subtracting(used).sorted().first {
            throw fail("the argument '\(unused)' is not used in the command")
        }
        for name in definition.argumentNames {
            guard let argument = definition.arguments?[name] else { continue }
            guard name.range(of: #"^[a-z][a-z0-9_]*$"#, options: .regularExpression) != nil else {
                throw fail("the argument name '\(name)' must be snake_case")
            }
            guard types.contains(argument.type) else {
                throw fail(
                    "the argument '\(name)' has type '\(argument.type)'; use string, integer, number, or boolean")
            }
            if let values = argument.enum, argument.type != "string" || values.isEmpty {
                throw fail("the argument '\(name)' may list enum values only as a non-empty list for a string")
            }
            if let value = argument.default, render(value, as: argument) == nil {
                throw fail("the argument '\(name)' has a default that is not a \(argument.type) it allows")
            }
        }
        if let timeout = definition.timeoutSeconds, timeout < 1 { throw fail("timeoutSeconds must be at least 1") }
    }

    /// The placeholder names in a command, in order.
    static func placeholders(in command: String) -> [String] {
        guard let regex = try? RegexCache.regex(placeholderPattern) else { return [] }
        return regex.matches(in: command, range: NSRange(command.startIndex..., in: command)).compactMap {
            Range($0.range(at: 1), in: command).map { String(command[$0]) }
        }
    }

    /// A value as it goes into the command line, or nil when it does not fit the argument: strings
    /// single-quoted (and within the enum, when there is one), numbers and booleans as written.
    static func render(_ value: JSONValue, as argument: Argument) -> String? {
        switch (argument.type, value) {
        case ("string", .string(let text)):
            if let allowed = argument.enum, !allowed.contains(text) { return nil }
            return "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        case ("integer", .int(let number)): return String(number)
        case ("integer", .double(let number)) where number.rounded() == number && abs(number) < 1e15:
            return String(Int(number))
        case ("number", .int(let number)): return String(number)
        case ("number", .double(let number)) where number.isFinite: return String(number)
        case ("boolean", .bool(let flag)): return flag ? "true" : "false"
        default: return nil
        }
    }

    /// The command line with each placeholder replaced by its rendered value, in one pass over the template:
    /// a value is never searched for placeholders, so a value holding `{b}` cannot splice in `b`'s value
    /// outside its quotes.
    ///
    /// - Throws: `Failure.invalid` when a value is missing or does not fit its argument.
    static func commandLine(_ definition: Definition, values: [String: JSONValue]) throws -> String {
        var rendered: [String: String] = [:]
        for name in definition.argumentNames {
            guard let argument = definition.arguments?[name] else { continue }
            guard let value = values[name] ?? argument.default else {
                throw Failure.invalid(tool: definition.name, reason: "the argument '\(name)' is required")
            }
            guard let text = render(value, as: argument) else {
                let allowed = argument.enum.map { ": one of \($0.joined(separator: ", "))" } ?? ""
                throw Failure.invalid(tool: definition.name, reason: "'\(name)' must be a \(argument.type)\(allowed)")
            }
            rendered[name] = text
        }
        let template = definition.command
        guard let regex = try? RegexCache.regex(placeholderPattern) else { return template }
        var line = ""
        var cursor = template.startIndex
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let whole = Range(match.range, in: template), let name = Range(match.range(at: 1), in: template),
                let value = rendered[String(template[name])]
            else { continue }
            line += template[cursor..<whole.lowerBound] + value
            cursor = whole.upperBound
        }
        return line + template[cursor...]
    }

    /// The schema the model fills in, built from the declared arguments.
    ///
    /// - Throws: The framework's error when the schema cannot be built.
    static func schema(for definition: Definition) throws -> GenerationSchema {
        let properties = definition.argumentNames.compactMap { name -> DynamicGenerationSchema.Property? in
            guard let argument = definition.arguments?[name] else { return nil }
            let schema: DynamicGenerationSchema =
                switch argument.type {
                case "integer": .init(type: Int.self)
                case "number": .init(type: Double.self)
                case "boolean": .init(type: Bool.self)
                default:
                    argument.enum.map { DynamicGenerationSchema(name: "\(definition.name)_\(name)", anyOf: $0) }
                        ?? .init(type: String.self)
                }
            return .init(
                name: name, description: argument.description, schema: schema, isOptional: argument.default != nil)
        }
        return try GenerationSchema(
            root: DynamicGenerationSchema(name: "\(definition.name)_arguments", properties: properties),
            dependencies: [])
    }

    /// The values the model gave, as JSON by argument name.
    static func values(in content: GeneratedContent) -> [String: JSONValue] {
        guard let data = content.jsonString.data(using: .utf8),
            let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
        else { return [:] }
        return object
    }

    /// The model's arguments are generated content shaped by `parameters`.
    public typealias Arguments = GeneratedContent

    /// The declaration.
    public let definition: Definition
    /// The identifier the model uses to request this tool.
    public var name: String { definition.name }
    /// What the model is told this tool does.
    public var description: String { definition.description }
    /// The schema built from the declared arguments.
    public let parameters: GenerationSchema
    /// Runs the command line.
    private let runner: CommandRunner

    /// Bounds, from the runner and the definition.
    public var limits: String {
        "Runs `\(definition.command)` under run_command's policy, sandbox, and approval; output up to "
            + "\(runner.options.maxOutputBytes) bytes per stream, \(Int(runner.options.timeout.components.seconds)) s at most."
    }
    /// How to ask for it.
    public var examplePrompt: String {
        let arguments = definition.argumentNames.map { "\($0) <\(definition.arguments?[$0]?.type ?? "value")>" }
        return "Use \(definition.name)"
            + (arguments.isEmpty ? "." : " with " + arguments.joined(separator: " and ") + ".")
    }

    /// Creates the tool over the conversation's runner.
    ///
    /// - Parameters:
    ///   - definition: A validated declaration.
    ///   - runner: `run_command`'s runner, gate included.
    /// - Throws: `Failure.invalid` for an invalid definition, or the framework's schema error.
    public init(_ definition: Definition, runner: CommandRunner) throws {
        try Self.validate(definition)
        self.definition = definition
        parameters = try Self.schema(for: definition)
        var runner = runner
        if let seconds = definition.timeoutSeconds { runner.options.timeout = .seconds(seconds) }
        self.runner = runner
    }

    /// Substitutes the values and runs the command.
    ///
    /// - Parameter arguments: The model's values.
    /// - Returns: The exit status and bounded output, as `run_command` returns them, or `error: …`.
    public func call(arguments: GeneratedContent) async -> String {
        do {
            let line = try Self.commandLine(definition, values: Self.values(in: arguments))
            let directory = definition.workingDirectory.map { ($0 as NSString).expandingTildeInPath }
            return try await runner.run(line, in: directory).rendered
        } catch {
            return "error: \(error)"
        }
    }
}
