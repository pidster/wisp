import Foundation

/// Read-only views of wisp's own state, rendered the same way for the model's `inspect` tool, the
/// MCP `wisp://` resources, and the CLI ([ADR 0018](../../../../docs/decisions/0018-introspection.md)).
///
/// Everything here is local state the operator already owns: the effective configuration, this
/// conversation's status, the standing approvals, and the audit log. Nothing is written.
public struct Introspection: Sendable {
    /// Where the audit files and config live.
    public let home: Home
    /// The effective configuration.
    public let config: Config.Resolved
    /// Standing approvals; nil outside a session.
    public let store: ApprovalStore?
    /// This conversation's live facts, supplied by whoever set it up.
    public let status: @Sendable () -> [String: JSONValue]

    /// Creates views over `home` and `config`.
    public init(
        home: Home, config: Config.Resolved, store: ApprovalStore? = nil,
        status: @escaping @Sendable () -> [String: JSONValue] = { [:] }
    ) {
        self.home = home
        self.config = config
        self.store = store
        self.status = status
    }

    /// The effective configuration with every default applied, plus where it came from.
    public var configuration: JSONValue {
        let policy = config.runner.policy
        return .object([
            "version": .string(WispVersion.current),
            "home": .object([
                "root": .string(home.root.path),
                "configFile": .string(home.configFile.path),
                "configFileExists": .bool(FileManager.default.fileExists(atPath: home.configFile.path)),
                "auditFile": .string(home.auditFile.path), "approvalsFile": .string(home.approvalsFile.path),
                "transcripts": .string(home.transcripts.path),
            ]),
            "model": .string(config.model.description),
            "systemPromptExtension": config.systemPromptExtension.map { .string($0) } ?? .null,
            "runCommand": .object([
                "timeoutSeconds": .int(Int(config.runner.timeout.components.seconds)),
                "maxOutputBytes": .int(config.runner.maxOutputBytes),
                "writableRoot": .string(config.runner.writableRoot),
                "policy": .object([
                    "deny": .array(policy.deny.map { .string($0) }), "allow": .array(policy.allow.map { .string($0) }),
                    "sandbox": .object([
                        "enabled": .bool(policy.sandbox.enabled), "allowNetwork": .bool(policy.sandbox.allowNetwork),
                        "writablePaths": .array(policy.sandbox.writablePaths.map { .string($0) }),
                    ]),
                ]),
            ]),
            "approval": .object([
                "threshold": .string(config.approvalThreshold.rawValue),
                "classifier": .string(config.approvalClassifier.rawValue),
                "coremlModel": config.coremlModel.map { .string($0) } ?? .null,
                "coremlMinimumConfidence": .double(config.coremlMinimumConfidence),
                "timeoutSeconds": config.approvalTimeout.map { .int(Int($0.components.seconds)) } ?? .int(0),
                "persistDays": .int(Int(config.approvalLifetime.components.seconds / 86400)),
            ]),
            "audit": .object([
                "enabled": .bool(config.auditEnabled), "maxFileBytes": .int(config.auditLimits.maxFileBytes),
                "keepFiles": .int(config.auditLimits.keepFiles),
            ]),
            "maxThreads": .int(config.maxThreads),
            "notifications": .object([
                "enabled": .bool(config.notificationsEnabled), "perMinute": .int(config.notificationsPerMinute),
            ]),
            "tools": .object([
                "disabled": .array(config.disabledTools.sorted().map { .string($0) }),
                "custom": .array(
                    config.customTools.map { tool in
                        .object([
                            "name": .string(tool.name), "command": .string(tool.command),
                            "arguments": .array(tool.argumentNames.map { .string($0) }),
                        ])
                    }),
            ]),
            "routing": .object([
                "ladder": .array(config.routingLadder.map { .string($0.description) }),
                "tasks": .object(config.taskModels.mapValues { .string($0.description) }),
            ]),
            "backends": .object(
                Dictionary(
                    uniqueKeysWithValues: ModelBackends.all.map { ($0.scheme, $0.settings(in: config, home: home)) })),
        ])
    }

    /// The standing approvals in force, newest first.
    public func approvals() async -> JSONValue {
        guard let store else { return .array([]) }
        return .array(
            await store.all.map { entry in
                .object([
                    "id": .string(entry.id), "pattern": .string(entry.pattern),
                    "workingDirectory": entry.workingDirectory.map { .string($0) } ?? .null,
                    "scope": .string(entry.scope.rawValue), "level": .string(entry.level.rawValue),
                    "grantedAt": .string(entry.grantedAt.ISO8601Format()),
                    "expiresAt": .string(entry.expiresAt.ISO8601Format()), "source": .string(entry.source),
                ])
            })
    }

    /// Audit events matching `query`, oldest first, read from the current and rotated files.
    ///
    /// - Throws: File-system errors other than a missing file.
    public func audit(_ query: AuditQuery) throws -> [AuditEvent] {
        var files = Array(
            FileAuditSink.rotatedFiles(for: home.auditFile, keep: config.auditLimits.keepFiles).reversed())
        files.append(home.auditFile)
        var events: [AuditEvent] = []
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            events += AuditQuery.events(in: try Data(contentsOf: file))
        }
        return query.filter(events)
    }

    /// Pretty JSON for a value.
    public static func render(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
