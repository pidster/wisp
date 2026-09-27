import Foundation
import Synchronization
import Testing

@testable import WispCore

/// Fixture credentials are assembled at run time so no token-shaped literal is committed: push
/// protection would refuse it, and wisp's own scan would report it.
@Suite struct SecretScannerTests {
    static let github = "ghp_" + String(repeating: "aB3", count: 12)
    static let aws = "AKIA" + "IOSFODNN7" + "QWERTYU"
    static let stripe = "sk_" + "live_" + String(repeating: "x1Y2", count: 6)
    static let anthropic = "sk-" + "ant-" + String(repeating: "Zq9_", count: 8)

    @Test func findsKnownCredentialShapesAndMasksThem() {
        let text = """
            token: \(Self.github)
            aws_access_key_id = \(Self.aws)
            STRIPE=\(Self.stripe)
            let key = "\(Self.anthropic)"
            postgres://app:\("hunter2" + "-prod")@db.internal:5432/app
            -----BEGIN RSA PRIVATE KEY-----
            MIIEowIBAAKCAQEA
            -----END RSA PRIVATE KEY-----
            """
        let matches = SecretScanner.scan(text, categories: [.secret])
        #expect(
            matches.map(\.kind) == [
                "github-token", "aws-access-key", "stripe-key", "anthropic-key", "url-password", "private-key",
            ], "\(matches.map(\.kind))")
        #expect(matches.map(\.line) == [1, 2, 3, 4, 5, 6])
        #expect(matches[4].value == "hunter2-prod")
        #expect(matches[5].value.hasSuffix("-----END RSA PRIVATE KEY-----"))
        #expect(SecretScanner.mask(Self.github) == "ghp_…(40 chars)")
        #expect(SecretScanner.mask("abcdefgh") == "ab…(8 chars)" && SecretScanner.mask("abc") == "…(3 chars)")
    }

    @Test func assignmentsNeedARealLookingValue() {
        let real = "password = \"" + "Tr0ub4dor&3x" + "\""
        #expect(SecretScanner.scan(real).map(\.kind) == ["assigned-secret"])
        for placeholder in [
            #"password = "changeme123""#, #"api_key: "${API_KEY}""#, #"token = "xxxxxxxxxxxx""#,
            #"secret = "<your-secret-here>""#, "DB_PASSWORD=$DB_PASSWORD",
        ] {
            #expect(SecretScanner.scan(placeholder).isEmpty, "\(placeholder)")
        }
        #expect(SecretScanner.scan("export GITHUB_TOKEN=" + "abc123def456ghi").map(\.kind) == ["env-secret"])
    }

    @Test func personalDataIsItsOwnCategory() {
        let text = """
            Contact jane.doe@acme.co or +44 20 7946 0958; card 4111 1111 1111 1111; from 81.2.69.160
            crash in /Users/jane/src/app/main.swift; ignore 4111 1111 1111 1112, 10.0.0.1, dev@example.com
            """
        let personal = SecretScanner.scan(text, categories: [.personal])
        #expect(
            personal.map(\.kind) == ["email", "phone", "card-number", "ip-address", "user-name"],
            "\(personal.map { "\($0.kind)=\($0.value)" })")
        #expect(personal.last?.value == "jane")
        let places = SecretScanner.scan(
            "ship to 42 Wren Lane, or 7b Upper Park Road; host db1.corp and mac.local; not 3 apples or 10 Items",
            categories: [.personal])
        #expect(places.map(\.value) == ["42 Wren Lane", "7b Upper Park Road", "db1.corp", "mac.local"], "\(places)")
        #expect(SecretScanner.scan(text, categories: [.secret]).isEmpty)
        #expect(SecretScanner.passesLuhn("4111111111111111") && !SecretScanner.passesLuhn("1234"))
        #expect(!SecretScanner.isPublicIPv4("192.168.1.1") && !SecretScanner.isPublicIPv4("300.1.1.1"))
        #expect(SecretScanner.isPublicIPv4("8.8.8.8"))
    }

    @Test func credentialsNamedByTheirHeaderFlagOrKeyAreFound() {
        let hash = "$2b$12$" + String(repeating: "Ab9.", count: 13) + "x"
        let lines = [
            ("Authorization: Basic " + "ZGVwbG95OmNvcm4tZmllbGQtOQ==", "auth-header"),
            ("curl -H \"Authorization: Bearer " + String(repeating: "Fq7Lm2", count: 4) + "\"", "auth-header"),
            ("Cookie: PHPSESSID=" + "r4v9t3b8y2c6h1d5", "session-cookie"),
            ("db_pass: " + "kX9mQ2vL", "assigned-secret"),
            ("spring.datasource.password=" + "Orion#2026", "assigned-secret"),
            ("X-Api-Key: " + "live_4569a774f8a6", "assigned-secret"),
            ("mysql -u root -p" + "S3cretRoot shop", "cli-password"),
            ("curl -u admin:" + "Sup3rS3cret https://ci.example.com/api", "cli-password"),
            ("docker login -u ci -p " + "Pat-7731-lark ghcr.example.com", "cli-password"),
            ("password_hash = \"" + hash + "\"", "password-hash"),
            ("https://acct.blob.core.windows.net/q3.csv?sv=2024&sig=" + "CXXBK56qXT7zZfWZbmMm", "url-secret"),
            ("-----BEGIN PGP PRIVATE KEY BLOCK-----", "private-key"),
        ]
        for (line, kind) in lines {
            #expect(SecretScanner.scan(line, categories: [.secret]).map(\.kind) == [kind], "\(line)")
        }
    }

    @Test func emailOnADomainReservedForExamplesIdentifiesNoOne() {
        let reserved = ["dev@example.com", "ops@mail.example.net", "a.b@example.org", "x@host.test", "y@z.invalid"]
        for address in reserved { #expect(SecretScanner.scan("mail \(address)").isEmpty, "\(address)") }
        for address in ["jo@example.co", "jo@notexample.com", "jo@example.com.au"] {
            #expect(SecretScanner.scan("mail \(address)").map(\.kind) == ["email"], "\(address)")
        }
    }

    @Test func aURLPasswordIsASecretNotAnEmailAddress() {
        let matches = SecretScanner.scan("mongodb://backup:" + "dumpIt88@mongo.example.com:27017")
        #expect(matches.map(\.kind) == ["url-password"] && matches.first?.value == "dumpIt88")
        #expect(SecretScanner.scan("redis://:" + "hush-hush@cache.example.com:6379").map(\.kind) == ["url-password"])
    }

    @Test func lookAlikesOfNamedCredentialsAreLeftAlone() {
        let lines = [
            #"print("\(ok ? "pass" : "FAIL")")"#, "--- PASS: TestGo (0.00s)", "the model's pass: names and numbers",
            "echo ${TOKEN:+yes}", "token_count = 42", "password: String", "let secret = await store.read()",
            #"let token = "ghp_" + String(repeating: "a", count: 36)"#, "password = os.environ.get(\"DB\")",
            "arn:aws:secretsmanager:us-east-1:000000000000:secret:prod/db-AbCdEf", "PUBLIC_KEY_PATH=/etc/wisp/pub.pem",
            #"export OPENAI_API_KEY="sk-...""#, "-e POSTGRES_PASSWORD=postgres", "token: ghp_****abcd",
            "docker run -p 5432:5432 postgres:16", "git push --token-file ~/.token", #"mock_api_key = "test-key""#,
        ]
        for line in lines {
            #expect(SecretScanner.scan(line, categories: [.secret]).isEmpty, "\(line)")
        }
    }

    @Test func aTrainingLineIsLabelledByItsMostSevereMatchWithTheScannerMarkRemoved() {
        let marked = String(Self.github.prefix(4)) + "\u{200B}" + Self.github.dropFirst(4)
        #expect(SecretScanner.label(of: "token: \(marked) for jo@acme.co") == "secret")
        #expect(SecretScanner.label(of: "reply to jo@acme.co") == "personal")
        #expect(SecretScanner.label(of: "build finished in 3.2 s") == "none")
    }

    @Test func aDiffIsScannedByItsAddedLinesAtTheirNewFileLines() {
        let diff = """
            diff --git a/Config.swift b/Config.swift
            --- a/Config.swift
            +++ b/Config.swift
            @@ -10,3 +10,4 @@ struct Config {
                 let name = "wisp"
            -    let old = "\(Self.github)"
            +    let key = "\(Self.aws)"
            +    let other = 1
            @@ -40,2 +41,2 @@
            -    let x = 1
            +    let token = "\(Self.stripe)"
            """
        #expect(SecretScanner.looksLikeDiff(diff) && !SecretScanner.looksLikeDiff("plain text\n"))
        let findings = SecretScanner.scanDiff(diff)
        #expect(findings.map(\.location) == ["Config.swift:11", "Config.swift:41"], "\(findings)")
        #expect(findings.map(\.kind) == ["aws-access-key", "stripe-key"])
        #expect(!findings.contains { $0.preview.contains(Self.aws) })
        #expect(SecretScanner.hunkStart("@@ -1 +7 @@") == 7 && SecretScanner.hunkStart("@@ nothing") == nil)
    }

    @Test func overlappingMatchesKeepTheFirstAndLongest() {
        // The Anthropic rule and the OpenAI rule both match an sk-ant key; one finding results.
        #expect(SecretScanner.scan(Self.anthropic).map(\.kind) == ["anthropic-key"])
    }

    @Test func theRedactorNumbersValuesPerKindAndLeavesMarkersAlone() {
        let text = "a jane@acme.co b bob@acme.co c jane@acme.co"
        var redactor = Redactor()
        let redacted = redactor.apply(SecretScanner.scan(text), to: text)
        #expect(redacted == "a [REDACTED:email#1] b [REDACTED:email#2] c [REDACTED:email#1]")
        #expect(redactor.counts == ["email": 3])
        let swept = redactor.apply(literals: [("Jane Doe", "name"), ("email", "name")], to: redacted + " Jane Doe")
        #expect(swept.hasSuffix(" [REDACTED:name#1]") && swept.contains("[REDACTED:email#2]"), "\(swept)")
        #expect(redactor.counts["name"] == 1)
    }

    @Test func theModelSweepKeepsOnlyValuesThatAreInTheChunk() {
        let chunk = "Customer Jane Doe at 12 High Street, ref CUST-00417, host db7.corp.internal"
        let answer = """
            {"items":[{"text":"Jane Doe","kind":"name"},{"text":"12 High Street","kind":"address"},
            {"text":"Invented Person","kind":"name"},{"text":"ab","kind":"name"},
            {"text":"CUST-00417","kind":"planet"},{"text":"[REDACTED:email#1]","kind":"email"}]}
            """
        let values = ModelSweep.values(in: answer, chunk: chunk + " [REDACTED:email#1]")
        #expect(values.map(\.value) == ["Jane Doe", "12 High Street"])
        #expect(ModelSweep.values(in: "not json", chunk: chunk).isEmpty)
        #expect(ModelSweep.prompt(chunk: "X", index: 1, count: 2, label: "the file a").contains("part 1 of 2"))
    }

    @Test func theSweepAsksAgainWithWhatItFoundHiddenUntilNothingIsNew() async throws {
        let prompts = PromptLog()
        let answers = [
            #"{"items":[{"text":"Jane Doe","kind":"name"}]}"#, #"{"items":[{"text":"42 Wren Lane","kind":"address"}]}"#,
            #"{"items":[{"text":"Jane Doe","kind":"name"}]}"#,
        ]
        let sweep = ModelSweep(passes: 5) { prompt in
            prompts.append(prompt)
            return answers[min(prompts.all.count, answers.count) - 1]
        }
        let result = try await sweep.run("Jane Doe lives at 42 Wren Lane.", label: "a note")
        #expect(result.values.map(\.value) == ["Jane Doe", "42 Wren Lane"] && result.chunks == 1)
        // Three turns: two added a value, the third repeated one and ended the chunk.
        #expect(prompts.all.count == 3)
        #expect(prompts.all[1].contains("[REDACTED:name#0] lives at 42 Wren Lane"))
        #expect(prompts.all[2].contains("[REDACTED:name#0] lives at [REDACTED:address#0]"))
        let once = PromptLog()
        _ = try await ModelSweep(passes: 0) { prompt in
            once.append(prompt)
            return answers[0]
        }.run("Jane Doe", label: "x")
        #expect(once.all.count == 1)
    }

    @Test func aScanReportsWithoutValuesAndTheModelPassAddsWhatRulesMiss() async throws {
        let text = "user Jane Doe\nkey \(Self.github)\n"
        let rules = try await SecretScan().run(text, from: .path("/tmp/x.log"))
        #expect(rules.findings.map(\.location) == ["/tmp/x.log:2"] && rules.chunks == nil && !rules.diff)
        #expect(!rules.rendered.contains(Self.github) && rules.rendered.contains("github-token"))
        #expect(rules.kinds == ["github-token": 1])
        let prompts = PromptLog()
        let thorough = try await SecretScan(
            options: .init(categories: [.secret, .personal], thorough: true),
            judge: { prompt in
                prompts.append(prompt)
                return #"{"items":[{"text":"Jane Doe","kind":"name"}]}"#
            }
        ).run(text, from: nil)
        #expect(thorough.findings.map(\.detector) == ["rule", "model"])
        #expect(thorough.findings.last?.location == "line 1" && thorough.chunks == 1)
        // The model never saw the credential the rules had already caught.
        #expect(prompts.all.allSatisfy { !$0.contains(Self.github) && $0.contains("[REDACTED:github-token#1]") })
        #expect(thorough.json.objectValue?["source"] == ["stdin": true])
        let capped = try await SecretScan(options: .init(maxFindings: 1)).run(text + Self.aws, from: nil)
        #expect(capped.more && capped.findings.count == 1 && capped.rendered.hasPrefix("1+ finding"))
    }

    @Test func aChunkTheModelFailsOnTwiceIsReportedAndTheSweepGoesOn() async throws {
        // Chunk 1 fails once and is asked again; chunk 2 always fails; chunk 3 answers.
        let prompts = PromptLog()
        let sweep = ModelSweep(chunkBytes: 14, passes: 1) { prompt in
            prompts.append(prompt)
            if prompt.contains("part 1 of"), prompts.all.count == 1 { throw TurnFailure() }
            if prompt.contains("part 2 of") { throw TurnFailure() }
            if prompt.contains("part 1 of") { return #"{"items":[{"text":"Jane Doe","kind":"name"}]}"# }
            return #"{"items":[{"text":"Sam Park","kind":"name"}]}"#
        }
        let result = try await sweep.run("Jane Doe here\nMia Lund here\nSam Park here", label: "a note")
        #expect(result.chunks == 3 && result.failed == [2], "\(result.failed)")
        #expect(result.values.map(\.value) == ["Jane Doe", "Sam Park"])
        #expect(prompts.all.count == 5)
        let cancelled = Task {
            try await ModelSweep { _ in throw CancellationError() }.run("Jane Doe", label: "x")
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    @Test func aScanOrRedactionTheModelFailsOnKeepsTheRulesFindingsAndSaysSo() async throws {
        let text = "user Jane Doe\nkey \(Self.github)\n"
        let scan = try await SecretScan(options: .init(thorough: true), judge: { _ in throw TurnFailure() }).run(
            text, from: nil)
        #expect(scan.findings.map(\.kind) == ["github-token"] && scan.chunks == 1 && scan.failedChunks == [1])
        #expect(scan.rendered.contains("the model failed on chunk 1, checked by rule only"), "\(scan.rendered)")
        #expect(scan.json.objectValue?["failedChunks"] == [1])
        #expect(AuditEvent.Details.secretScan(scan)["failedChunks"] == [1])
        let redaction = try await Redaction(options: .init(thorough: true), judge: { _ in throw TurnFailure() }).run(
            text, from: nil)
        #expect(redaction.text.contains("[REDACTED:github-token#1]") && redaction.failedChunks == [1])
        #expect(redaction.summary.hasSuffix("the model failed on chunk 1, checked by rule only"))
        #expect(AuditEvent.Details.redaction(redaction)["failedChunks"] == [1])
        let clean = try await SecretScan().run(text, from: nil)
        #expect(clean.failedChunks.isEmpty && !clean.rendered.contains("failed"))
    }

    @Test func aThoroughDiffScanLocatesModelFindingsOnAddedLinesOnly() async throws {
        let diff = """
            diff --git a/notes.md b/notes.md
            --- a/notes.md
            +++ b/notes.md
            @@ -3,2 +3,2 @@
            -Owner: Old Name
            +Owner: Jane Doe
             Reviewed by Sam Park
            """
        // The model names a value on an added line, one only on a context line, and one of an unwanted kind.
        let answer = #"{"items":[{"text":"Jane Doe","kind":"name"},{"text":"Sam Park","kind":"name"}]}"#
        let report = try await SecretScan(
            options: .init(categories: [.secret, .personal], thorough: true), judge: { _ in answer }
        ).run(diff, from: .command("git diff", workingDirectory: nil))
        #expect(report.diff && report.findings.map(\.location) == ["notes.md:3"], "\(report.findings)")
        let secretsOnly = try await SecretScan(options: .init(thorough: true), judge: { _ in answer }).run(
            diff, from: nil)
        #expect(secretsOnly.findings.isEmpty)
        #expect(SecretScan.locate("absent", in: "text", diff: false, source: nil) == nil)
        #expect(Condensing.label(nil) == "text read from standard input")
        #expect(Condensing.json(.command("ls", workingDirectory: "/r")) == ["command": "ls", "workingDirectory": "/r"])
    }

    @Test func aRedactionReplacesByRuleThenByModelAndCapsItsOutput() async throws {
        let text = "Jane Doe <jane@acme.co> used \(Self.github)\n"
        let rules = try await Redaction().run(text, from: nil)
        #expect(rules.text == "Jane Doe <[REDACTED:email#1]> used [REDACTED:github-token#1]\n")
        #expect(rules.summary == "redacted 2 values (email 1, github-token 1)")
        let thorough = try await Redaction(
            options: .init(thorough: true), judge: { _ in #"{"items":[{"text":"Jane Doe","kind":"name"}]}"# }
        ).run(text, from: .command("cat x", workingDirectory: nil))
        #expect(thorough.text.hasPrefix("[REDACTED:name#1] <"))
        #expect(thorough.counts["name"] == 1 && thorough.chunks == 1)
        let secretsOnly = try await Redaction(options: .init(categories: [.secret])).run(text, from: nil)
        #expect(secretsOnly.text.contains("jane@acme.co"))
        let cut = try await Redaction(options: .init(maxOutputBytes: 10)).run(text, from: nil)
        #expect(cut.truncated && cut.text.utf8.count == 10 && cut.summary.hasSuffix("output cut to 10 bytes"))
        #expect(cut.json.objectValue?["truncated"] == true)
    }
}

/// Prompts a scripted judge received.
/// A model turn that fails, as a guardrail refusal does.
struct TurnFailure: Error {}

final class PromptLog: Sendable {
    private let prompts = Mutex<[String]>([])
    func append(_ prompt: String) { prompts.withLock { $0.append(prompt) } }
    var all: [String] { prompts.withLock { $0 } }
}
