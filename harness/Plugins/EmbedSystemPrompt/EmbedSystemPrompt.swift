import Foundation
import PackagePlugin

/// Embeds text resources into `WispCore` as Swift string constants at build time, so each is a plain
/// file in the source tree and the product stays one binary with nothing to ship beside it:
/// `Resources/system-prompt.md` as `SystemPromptText.text`, `Resources/measurements.json` as
/// `MeasurementsText.text`, `Resources/multiplexers.txt` as `MultiplexersText.text`, and
/// `Resources/risk-examples.tsv` as `RiskExamplesText.text`, and `Resources/risk-default.json` (the shipped
/// risk classifier, its model in base64) as `RiskDefaultText.text`, and `Resources/personal-default.json` (the
/// personal-data classifier, likewise) as `PersonalDefaultText.text`, and `Resources/subject-kinds.json` (the default
/// subject kinds of facts) as `SubjectKindsText.text`. The text goes into a raw multi-line literal, so it needs no escaping; the
/// one sequence that would end the literal early is refused.
@main
struct EmbedSystemPrompt: BuildToolPlugin {
    /// The shell that turns a text file into Swift; `$1` is the input, `$2` the output, `$3` the type.
    static let script = """
        set -eu
        if grep -q '\"\"\"#' "$1"; then echo "$1 must not contain \\"\\"\\"#" >&2; exit 1; fi
        {
            printf '// Generated from %s by the EmbedSystemPrompt plugin. Do not edit.\\n' "$(basename "$1")"
            printf 'enum %s {\\n    static let text = #\"\"\"\\n' "$3"
            cat "$1"
            printf '\"\"\"#\\n}\\n'
        } > "$2"
        """

    /// The resources embedded, as file name and Swift type.
    static let resources = [
        ("system-prompt.md", "SystemPromptText"), ("measurements.json", "MeasurementsText"),
        ("multiplexers.txt", "MultiplexersText"), ("risk-examples.tsv", "RiskExamplesText"),
        ("risk-default.json", "RiskDefaultText"), ("personal-default.json", "PersonalDefaultText"),
        ("subject-kinds.json", "SubjectKindsText"),
    ]

    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        return Self.resources.map { file, type in
            let input = target.directoryURL.appending(path: "Resources/\(file)")
            let output = context.pluginWorkDirectoryURL.appending(path: "\(type).swift")
            return .buildCommand(
                displayName: "Embed \(file)",
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", Self.script, "embed-resource", input.path(), output.path(), type],
                inputFiles: [input],
                outputFiles: [output]
            )
        }
    }
}
