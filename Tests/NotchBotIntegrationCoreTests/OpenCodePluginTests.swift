import Testing
@testable import NotchBotIntegrationCore

@Test func disabledPluginNeverCollectsAssistantResponseText() {
    let plugin = OpenCodePlugin.generate(
        hookPath: "/Users/test/Library/Application Support/NotchBot/bin/notchbot-hook",
        assistantExcerptsEnabled: false
    )

    #expect(!plugin.contains("message.updated"))
    #expect(!plugin.contains("message.part.updated"))
    #expect(!plugin.contains("properties.part.text"))
    #expect(!plugin.contains("latestResponses"))
    #expect(!plugin.contains("--session"))
    #expect(!plugin.contains("--cwd"))
    #expect(!plugin.contains("--summary"))
    #expect(plugin.contains("stdin: \"pipe\""))
    #expect(plugin.contains("JSON.stringify(payload)"))
}

@Test func enabledPluginTruncatesBeforeBoundedStorageAndClearsResponses() {
    let plugin = OpenCodePlugin.generate(hookPath: "/tmp/hook", assistantExcerptsEnabled: true)

    #expect(plugin.contains("map.size >= 256"))
    #expect(plugin.contains("const response = excerpt(properties.part.text)"))
    #expect(plugin.contains("setBounded(latestResponses, partSessionID, response)"))
    #expect(plugin.contains("latestResponses.delete(sessionID)"))
    #expect(plugin.contains("normalized.length > 240"))
    #expect(plugin.contains("question.rejected"))
    #expect(plugin.contains("question.v2.rejected"))
}

@Test func pluginEscapesHookPathAsAJSONString() {
    let plugin = OpenCodePlugin.generate(hookPath: "/tmp/a\"b\\c", assistantExcerptsEnabled: false)
    #expect(plugin.contains("const hookPath = \"/tmp/a\\\"b\\\\c\""))
}
