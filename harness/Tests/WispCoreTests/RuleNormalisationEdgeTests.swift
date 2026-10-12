import Testing

@testable import WispCore

/// The edges of the rules' second spelling of a command (`RuleRiskClassifier.spellings`): which words of a
/// searching or editing program are data (masked) and which are what it runs.
@Suite struct RuleNormalisationEdgeTests {
    /// `normalisedForms` is the unquoted spelling, with git's global options gone and a searched pattern kept.
    @Test func normalisedFormsIsTheUnquotedSpellingOfTheLine() {
        #expect(RuleRiskClassifier.normalisedForms(of: "'rm' -rf  \"a b\"") == ["rm -rf a b"])
        #expect(RuleRiskClassifier.normalisedForms(of: "git -C . --no-pager push --force") == ["git push --force"])
    }

    /// A backup suffix after `sed -i` is an option's value, not the script: the script after it is still data.
    @Test func sedsBackupSuffixIsNotTakenForItsScript() {
        let suffixed = RuleRiskClassifier.spellings(of: "sed -i .bak 's/a|sh/b/' f.txt")
        #expect(suffixed.maskedNormalised == "sed -i .bak '' f.txt")
        // Without a suffix the first word is the script.
        let plain = RuleRiskClassifier.spellings(of: "sed -i 's/a|sh/b/' f.txt")
        #expect(plain.maskedNormalised == "sed -i '' f.txt")
    }

    /// `--regexp=PATTERN` gives grep its pattern, so the next word is a file, not a second pattern.
    @Test func aRegexpOptionGivesGrepItsPatternAndTheNextWordIsAFile() {
        let spelled = RuleRiskClassifier.spellings(of: "grep '--regexp=a|sh' notes.txt")
        #expect(spelled.maskedNormalised == "grep '' notes.txt")
    }

    /// An escaped quote inside double quotes does not end them, so a `;` after it is still quoted.
    @Test func anEscapedQuoteInsideDoubleQuotesKeepsTheOperatorQuoted() {
        #expect(!RuleRiskClassifier.holdsAnOperator("\"a\\\"b;c\""))
        #expect(RuleRiskClassifier.holdsAnOperator("\"a\\\"b\";c"))
    }
}
