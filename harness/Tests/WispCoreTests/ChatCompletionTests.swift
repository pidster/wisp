import Foundation
import Synchronization
import Testing

@testable import WispCore

/// Tab completion's candidates, and the protocol that asks for them (ADR 0040).
@Suite struct ChatCompletionTests {
    private func complete(_ text: String, cursor: Int? = nil) -> ChatCompletion.Result {
        ChatCompletion.complete(text, cursor: cursor) { setting in
            setting.path == "model" ? ["system", "ollama:granite4.1:8b", "ollama:qwen3.8:27b"] : []
        }
    }

    @Test func commandsSettingsAndValuesComplete() {
        #expect(complete("/con") == .init(from: 0, candidates: ["/config", "/context"]))
        #expect(complete("/m").candidates == ["/model", "/models"])
        #expect(complete("/config s") == .init(from: 8, candidates: ["set", "show"]))
        #expect(
            complete("/config set approval.c").candidates == [
                "approval.classifier", "approval.coremlMinimumConfidence", "approval.coremlModel",
            ])
        #expect(complete("/config unset rout").candidates == ["routing.ladder", "routing.tasks.secrets"])
        #expect(complete("/config set approval.classifier ").candidates == ["coreml", "rules", "system-model"])
        #expect(complete("/config set audit.enabled t").candidates == ["true"])
        #expect(complete("/config set tools.disabled no").candidates == ["notify"])
        #expect(complete("/config set model ollama:g").candidates == ["ollama:granite4.1:8b"])
        #expect(complete("/model ollama:q") == .init(from: 7, candidates: ["ollama:qwen3.8:27b"]))
        #expect(complete("/inspect ap").candidates == ["approvals"])
        #expect(complete("/config g").candidates == ["get"])
        #expect(complete("/config get audit.").candidates == ["audit.enabled"])
        #expect(complete("/app").candidates == ["/approvals"] && complete("/au").candidates == ["/audit"])
        #expect(!ChatCompletion.commands.contains("/inspect"), "the alias is not offered")
        #expect(complete("/approvals r").candidates == ["revoke"])
        #expect(
            ChatCompletion.complete("/approvals revoke a", approvalIDs: ["ab12", "cd34", "a9"]).candidates
                == ["a9", "ab12"])
    }

    @Test func nothingCompletesOutsideASlashCommandOrPastItsWords() {
        #expect(complete("hello wor").candidates.isEmpty)
        #expect(complete("/config set nosuch ").candidates.isEmpty)
        #expect(complete("/config set approval.classifier rules extra").candidates.isEmpty)
        #expect(complete("/save x").candidates.isEmpty)
        // The cursor decides the word: completing the middle of a line uses what is before it.
        #expect(complete("/config set approval.cl rest", cursor: 23).candidates == ["approval.classifier"])
    }

    @Test func completionRequestsAreHandedOffTheLoop() {
        let router = LineRouter()
        let asked = Mutex<[String]>([])
        router.onComplete { id, text, cursor in asked.withLock { $0.append("\(id) \(text) \(cursor ?? -1)") } }
        router.receive(#"{"type":"complete","id":"k1","text":"/con","cursor":4}"#)
        router.receive(#"{"type":"complete","id":"k2","text":"/m"}"#)
        #expect(asked.withLock { $0 } == ["k1 /con 4", "k2 /m -1"])
        let fields = ChatProtocol.completions(id: "k1", .init(from: 0, candidates: ["/config"]))
        #expect(fields == ["id": "k1", "from": 0, "candidates": ["/config"]])
    }
}
