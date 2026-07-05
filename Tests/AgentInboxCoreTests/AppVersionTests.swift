import Testing
@testable import AgentInboxCore

@Test
func appVersionDefaultsTo001WhenBundleVersionIsMissing() {
    #expect(AppVersion.displayValue(shortVersionString: nil) == "0.0.1")
    #expect(AppVersion.displayValue(shortVersionString: "") == "0.0.1")
    #expect(AppVersion.displayValue(shortVersionString: "   \n") == "0.0.1")
}

@Test
func appVersionUsesManualShortVersionString() {
    #expect(AppVersion.displayValue(shortVersionString: "0.1.0") == "0.1.0")
    #expect(AppVersion.displayValue(shortVersionString: " 1.2.3 ") == "1.2.3")
}
