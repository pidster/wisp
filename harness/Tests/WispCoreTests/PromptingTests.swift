import Foundation
import Testing

@testable import WispCore

@Suite struct PromptingTests {
    @Test func rendersTheLayersInOrderUnderHeadings() {
        let all = Prompting(systemPromptExtension: " Prefer British spelling. ", instructions: "Answer in French.")
        let expected =
            Prompting.systemPrompt(memory: false)
            + "\n\nGuidance for this Mac:\nPrefer British spelling.\n\nInstructions for this conversation:\nAnswer in French."
        #expect(all.rendered == expected)
    }

    @Test func aConversationWithoutToolsIsToldSo() {
        let text = Prompting(instructions: "x").rendered(toolsAvailable: false)
        #expect(text.contains("This conversation has no tools"))
        #expect(text.hasSuffix("Instructions for this conversation:\nx"))
        #expect(!Prompting().rendered.contains("no tools"))
    }

    @Test func emptyLayersAreOmittedAndTheSystemPromptCannotBe() {
        let base = Prompting.systemPrompt(memory: false)
        #expect(Prompting().rendered == base)
        #expect(Prompting(systemPromptExtension: "  \n", instructions: "").rendered == base)
        #expect(Prompting(instructions: "x").rendered == base + "\n\nInstructions for this conversation:\nx")
        #expect(Prompting.systemPrompt.contains("Wisp"))
        #expect(Prompting.systemPrompt.utf8.count < 900, "keep layer 1 small for an 8k window")
    }

    /// The embedded text is the resource file, so editing the file is editing the prompt.
    @Test func systemPromptIsTheResourceFile() throws {
        let file = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/WispCore/Resources/system-prompt.md")
        let onDisk = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Prompting.systemPrompt == onDisk)
    }
}
