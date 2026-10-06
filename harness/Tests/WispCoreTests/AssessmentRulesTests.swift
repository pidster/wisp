import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// The assessment's pure parts (phase 4d of the layered-context proposal, decision D12): the rules that settle a
/// request without a model call, the tools named by a request's words, follow-ups, the facts chosen by word overlap,
/// the tool catalogue, the model call's prompt and its bounds, and how its answer is applied. `AssessmentTests`
/// drives the agent over a scripted model.
@Suite struct AssessmentRulesTests {
    /// Every built-in tool, in the registry's order.
    static let builtIns = ToolRegistry.builtInNames

    @Test func wordsThatNameADomainChooseThatTool() {
        let allowed = Self.builtIns
        #expect(AssessmentRules.named(in: "What is the date today?", allowed: allowed) == ["current_date"])
        #expect(AssessmentRules.named(in: "Show me docs/overview.md", allowed: allowed) == ["read_file"])
        #expect(AssessmentRules.named(in: "Read the README", allowed: allowed) == ["read_file"])
        #expect(
            AssessmentRules.named(in: "Edit Package.swift to add a target", allowed: allowed) == [
                "read_file", "edit_file",
            ], "edit_file brings read_file, which it needs first")
        #expect(AssessmentRules.named(in: "How much memory is in use?", allowed: allowed) == ["system_info"])
        #expect(AssessmentRules.named(in: "Which ports are listening?", allowed: allowed) == ["system_info"])
        #expect(AssessmentRules.named(in: "Notify me when it is done", allowed: allowed) == ["notify"])
        #expect(AssessmentRules.named(in: "Show wisp's config", allowed: allowed) == ["inspect"])
        #expect(AssessmentRules.named(in: "Run the tests", allowed: allowed).isEmpty)
        // Only allowed tools: an explicit list is never widened.
        #expect(AssessmentRules.named(in: "What is the date today?", allowed: ["run_command"]).isEmpty)
        #expect(AssessmentRules.named(in: "Edit a.md", allowed: ["edit_file", "run_command"]) == ["edit_file"])
        // A custom tool by a word of its name.
        #expect(
            AssessmentRules.named(in: "Deploy the site", allowed: ["run_command", "deploy_site"]) == ["deploy_site"])
    }

    @Test func aFollowUpOpensWithAFollowUpWordOrPointsBackBriefly() {
        #expect(AssessmentRules.isFollowUp("And the next page?"))
        #expect(AssessmentRules.isFollowUp("again"))
        #expect(AssessmentRules.isFollowUp("What does that mean?"))
        #expect(!AssessmentRules.isFollowUp("Add a --dry-run flag to harbour sync"))
        #expect(
            !AssessmentRules.isFollowUp(
                "Please write a long new plan for the release of the project with every step that it needs to take"))
    }

    @Test func theRulesSettleWhatTheyCanAndLeaveTheRestToTheModel() {
        let allowed = ["current_date", "run_command", "read_file", "system_info", "memory"]
        var context = AssessmentRules.Context(allowed: allowed, infersTask: false)
        // A named domain: settled, with the tools always registered.
        var decision = AssessmentRules.decide("What is the date today?", context: context)
        #expect(decision.settled && decision.tools == ["current_date", "run_command", "memory"])
        // Nothing named and not short: the model is asked.
        decision = AssessmentRules.decide("Work out why the harbour build broke last night", context: context)
        #expect(!decision.settled && decision.tools == ["run_command", "memory"])
        // A follow-up to a turn that used a tool keeps that tool.
        context.previous = ["read_file"]
        decision = AssessmentRules.decide("And what does that part of it say about retries?", context: context)
        #expect(decision.settled && decision.tools == ["run_command", "read_file", "memory"])
        // The task's tools come with every request.
        context.previous = []
        context.taskTools = ["system_info"]
        decision = AssessmentRules.decide("Work out why the harbour build broke last night", context: context)
        #expect(decision.tools == ["run_command", "system_info", "memory"])
        // Nothing to choose: settled whatever the words.
        decision = AssessmentRules.decide(
            "Work out why the harbour build broke last night",
            context: .init(allowed: ["run_command", "memory"], infersTask: false))
        #expect(decision.settled && decision.tools == ["run_command", "memory"])
        // No selection: the tools are settled; the task alone can call for the model.
        decision = AssessmentRules.decide(
            "Work out why the harbour build broke last night",
            context: .init(allowed: allowed, infersTask: false, selectsTools: false))
        #expect(decision.settled)
    }

    @Test func theTaskIsSettledWhenItIsNotInferredPinnedOrCarriedOn() {
        let allowed = ["current_date", "run_command", "memory"]
        let request = "What is the date today in Tokyo for the release plan?"
        // In chat with no task, a named tool is not enough: the task is inferred.
        var context = AssessmentRules.Context(allowed: allowed, infersTask: true)
        #expect(!AssessmentRules.decide(request, context: context).settled)
        // The person's task is never replaced, so there is nothing to infer.
        context.hasTask = true
        context.taskPinned = true
        #expect(AssessmentRules.decide(request, context: context).settled)
        // The model's task carries on through a follow-up.
        context.taskPinned = false
        #expect(AssessmentRules.decide("And the date in Paris?", context: context).settled)
        #expect(!AssessmentRules.decide(request, context: context).settled)
        // Short requests ask for nothing to infer.
        #expect(AssessmentRules.decide("hello there", context: context).settled)
    }

    @Test func aRequestRestatesTheTaskOnlyWhenASentenceThatIsNotAQuestionStatesOne() {
        for stated in [
            "Today's task: add a --dry-run flag to `harbour sync`. Reply in one sentence.",
            "Back to the task: the --dry-run flag for harbour sync.",
            "The goal is a green build by Friday.",
            "New task. Rename the config file.",
            "Let's switch to the release notes now",
            "We need to work on the installer next.",
            "From now on, keep replies short.",
        ] {
            #expect(AssessmentRules.restatesTask(stated), "\(stated)")
        }
        for asked in [
            "Let's get back to the task we started with. What is the task, and what is your first step?",
            "What is the task?",
            "Let's take a detour from the task for a while. Use read_file to read a.md.",
            "Is the goal: a green build?",
            "What is the codename for this release?",
            "",
        ] {
            #expect(!AssessmentRules.restatesTask(asked), "\(asked)")
        }
    }

    @Test func underRestatedATaskChangesOnlyWhenTheRequestStatesOne() {
        let allowed = ["current_date", "run_command", "memory"]
        let request = "What is the date today in Tokyo for the release plan?"
        var context = AssessmentRules.Context(allowed: allowed, hasTask: true, taskChanges: .restated)
        // A task exists and the request does not state one: settled, with no model call for the task.
        #expect(AssessmentRules.decide(request, context: context).settled && !context.mayChangeTask)
        // A request that states one may change it, so the model is asked.
        context.restates = true
        #expect(!AssessmentRules.decide(request, context: context).settled && context.mayChangeTask)
        // With no task yet the first one may be inferred, as under `any`.
        context.restates = false
        context.hasTask = false
        #expect(context.mayChangeTask && !AssessmentRules.decide(request, context: context).settled)
        // Under `any`, the default, every request the rules leave open may change it.
        let any = AssessmentRules.Context(allowed: allowed, hasTask: true)
        #expect(any.mayChangeTask && !AssessmentRules.decide(request, context: any).settled)
        #expect(AssessmentSettings().taskChanges == .any)
    }

    @Test func relevantFactsAreChosenByWordOverlapLeavingOutTheNowBlocks() {
        let now = Date()
        func fact(_ id: String, _ scope: FactScope, _ subject: String, _ name: String, _ value: String) -> Fact {
            Fact(
                id: id, identity: FactIdentity(scope: scope, subject: subject, name: name), source: .person,
                version: 1, value: value, temporalClass: scope == .session ? .ephemeral : .dynamic, method: .stated,
                detail: nil, entries: [], audit: [], recorded: now, turn: 1, supersededBy: nil, state: .current,
                approved: nil)
        }
        let view = FactView([
            fact("c1", .thread, "entity", "release codename", "BLUE HERON"),
            fact("c2", .thread, "entity", "ticket", "4127"),
            fact("c3", .thread, "task", "", "the release codename work"),
            fact("s1", .session, "service", "port 8080", "release server listening"),
        ])
        #expect(AssessmentRules.overlapping("What is the release codename?", in: view, limit: 4) == ["c1"])
        #expect(AssessmentRules.overlapping("Which ticket is it?", in: view, limit: 4) == ["c2"])
        #expect(AssessmentRules.overlapping("What is it?", in: view, limit: 4).isEmpty)
        #expect(AssessmentRules.overlapping("codename and ticket", in: view, limit: 1).count == 1)
    }

    @Test func theCatalogueIsOneShortClausePerAllowedTool() throws {
        let registry = ToolRegistry(
            custom: [
                .init(name: "deploy_site", description: "Deploys the site to staging. Takes a minute.", command: "true")
            ])
        let text = try #require(ToolCatalogue.text(registry.all))
        let lines = text.split(separator: "\n")
        #expect(lines.first.map(String.init) == ToolCatalogue.header)
        #expect(lines.count == registry.all.count + 1)
        #expect(text.contains("- run_command: run a shell command; the fallback for anything else"))
        #expect(text.contains("- memory: recall earlier material of this conversation, note a fact, or set the task"))
        #expect(text.contains("- deploy_site: Deploys the site to staging"))
        #expect(ToolCatalogue.text([]) == nil)
        // Every built-in has a hand-written clause.
        #expect(Set(ToolCatalogue.clauses.keys) == Set(ToolRegistry.builtInNames))
        // Sizes, for the proposal: bytes of the catalogue of every built-in.
        #expect(try #require(ToolCatalogue.text(ToolRegistry().all)).utf8.count < 700)
    }

    @Test func theModelIsShownIdentitiesNotValuesWithinBounds() {
        let facts = (1...40).map { ("c\($0)", FactIdentity.Key(subject: "entity", name: "thing \($0)")) }
        let prompt = Assessor.prompt(
            request: String(repeating: "word ", count: 1000), catalogue: "Tools:\n- run_command: run",
            task: "fix the build", infersTask: true, facts: facts, previous: ["read_file"])
        #expect(prompt.hasPrefix("Tools:\n- run_command: run"))
        #expect(prompt.contains("The task: fix the build\n"))
        #expect(prompt.contains("The previous request used: read_file"))
        #expect(prompt.contains("- c1 entity thing 1") && !prompt.contains("- c31 "))
        #expect(prompt.utf8.count < 3_000, "the request is cut to \(Assessor.requestCharacters) characters")
        let fixed = Assessor.prompt(
            request: "x", catalogue: nil, task: nil, infersTask: false, facts: [], previous: [])
        #expect(fixed.contains("The task: none yet (fixed; leave task and objective empty)"))
        #expect(!fixed.contains("Recorded facts"))
    }

    @Test func aTaskAndItsObjectiveAreOneValue() {
        #expect(
            Assessor.taskValue("fix the build", objective: "swift test passes")
                == "fix the build; objective: swift test passes")
        #expect(Assessor.taskValue(" fix the build ", objective: " ") == "fix the build")
        #expect(Assessor.taskValue("", objective: "x").isEmpty)
    }

    @Test func theAnswerIsAppliedWithinTheAllowedToolsAndTheFactsInForce() throws {
        let now = Date()
        let codename = Fact(
            id: "c1", identity: FactIdentity(scope: .thread, subject: "entity", name: "release codename"),
            source: .person, version: 1, value: "BLUE HERON", temporalClass: .dynamic, method: .stated, detail: nil,
            entries: [], audit: [], recorded: now, turn: 1, supersededBy: nil, state: .current, approved: nil)
        let view = FactView([codename])
        let answer = try Assessor.Answer(
            GeneratedContent(
                json:
                    #"{"intent":"start","tools":["read_file","edit_file"],"task":"add a flag","objective":"it works","facts":["c1","c9"]}"#
            ))
        let rules = Assessment(
            method: .rules, tools: ["run_command"], ruleTools: ["run_command"], intent: nil, task: nil, facts: [],
            failure: nil)
        let context = AssessmentRules.Context(allowed: ["run_command", "read_file"], infersTask: true)
        let applied = Agent.applying(answer, to: rules, allowed: context.allowed, view: view, context: context)
        #expect(applied.method == .model && applied.tools == ["run_command", "read_file"], "never widened")
        #expect(applied.intent == "start" && applied.task == "add a flag; objective: it works")
        #expect(applied.facts == ["c1"])
        // A pinned task, or one not inferred here, is left alone.
        var pinned = context
        pinned.taskPinned = true
        #expect(Agent.applying(answer, to: rules, allowed: context.allowed, view: view, context: pinned).task == nil)
        var mcp = context
        mcp.infersTask = false
        #expect(Agent.applying(answer, to: rules, allowed: context.allowed, view: view, context: mcp).task == nil)
        // Under `restated`, an existing task changes only when the request stated one.
        var restated = context
        restated.taskChanges = .restated
        restated.hasTask = true
        #expect(Agent.applying(answer, to: rules, allowed: context.allowed, view: view, context: restated).task == nil)
        restated.restates = true
        #expect(Agent.applying(answer, to: rules, allowed: context.allowed, view: view, context: restated).task != nil)
    }
}
