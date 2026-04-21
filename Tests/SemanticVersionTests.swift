import Testing

@Suite("SemanticVersion") struct SemanticVersionTests {

    @Test func newerMajor() {
        #expect(SemanticVersion.compare("2.0.0", isGreaterThan: "1.0.0"))
    }

    @Test func newerMinor() {
        #expect(SemanticVersion.compare("1.1.0", isGreaterThan: "1.0.0"))
    }

    @Test func newerPatch() {
        #expect(SemanticVersion.compare("1.0.1", isGreaterThan: "1.0.0"))
    }

    @Test func doubleDigitPatch() {
        // "1.0.10" must beat "1.0.9" numerically, not lexicographically
        #expect(SemanticVersion.compare("1.0.10", isGreaterThan: "1.0.9"))
    }

    @Test func equalVersions() {
        #expect(!SemanticVersion.compare("1.0.6", isGreaterThan: "1.0.6"))
    }

    @Test func olderVersion() {
        #expect(!SemanticVersion.compare("1.0.5", isGreaterThan: "1.0.6"))
    }

    @Test func missingPatchTreatedAsZero() {
        #expect(SemanticVersion.compare("1.1", isGreaterThan: "1.0.0"))
        #expect(!SemanticVersion.compare("1.0", isGreaterThan: "1.0.0"))
    }

    @Test func fourComponentVersion() {
        #expect(SemanticVersion.compare("1.0.0.1", isGreaterThan: "1.0.0"))
    }
}
