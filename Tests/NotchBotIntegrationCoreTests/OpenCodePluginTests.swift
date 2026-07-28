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

@Test func pluginCachesOnlyExplicitSessionTitlesAndUsesMetadataFallbacks() {
    let plugin = OpenCodePlugin.generate(hookPath: "/tmp/hook", assistantExcerptsEnabled: false)

    #expect(plugin.contains("event.type === \"session.created\" || event.type === \"session.updated\""))
    #expect(plugin.contains("const label = taskLabel(properties.info?.title)"))
    #expect(plugin.contains("send(\"metadata\""))
    #expect(plugin.contains("taskLabels.size >= 256") || plugin.contains("map.size >= 256"))
    #expect(plugin.contains("payload.task_label = label"))
    #expect(plugin.contains("project?.name"))
    #expect(plugin.contains("basename(worktree)"))
    #expect(plugin.contains("basename(directory)"))
    #expect(plugin.contains("New session|Child session"))
    #expect(plugin.contains("taskLabels.delete(sessionID)"))
    #expect(plugin.contains("const sessionParents = new Map()"))
    #expect(plugin.contains("properties.info?.parentID"))
    #expect(plugin.contains("payload.parent_session_id = parentSessionID"))
    #expect(plugin.contains("client.session.get({ path: { id: sessionID } })"))
    #expect(plugin.contains("if (!sessionParents.has(input.sessionID)) await resolveParentSessionID(input.sessionID)"))
    #expect(plugin.contains("const completedSessions = new Set()"))
    #expect(plugin.contains("const waitingSessions = new Set()"))
    #expect(plugin.contains("if (waitingSessions.has(sessionID)) return"))
    #expect(plugin.contains("if (!completedSessions.has(sessionID))"))
    #expect(plugin.contains("sendEvent(\"attention\", sessionID, \"OpenCode finished working\", null, summary)"))
    #expect(plugin.contains("sendCompletion(sessionID, summary)"))
    #expect(!plugin.contains("OpenCode finished working\", 2.5"))
    #expect(plugin.contains("sessionParents.delete(sessionID)"))
    #expect(plugin.contains("sendEvent(\"attention\", sessionID, \"OpenCode needs permission\""))
    #expect(plugin.contains("case \"permission.updated\":"))
    #expect(plugin.contains("void requestPermission(sessionID, properties)"))
    #expect(plugin.contains("\"--mode\", \"permission\""))
    #expect(plugin.contains("permission_summary: permissionSummary(properties)"))
    #expect(plugin.contains("permission_context: permissionContext(properties)"))
    #expect(plugin.contains("metadata.command"))
    #expect(plugin.contains("metadata.file_path"))
    #expect(plugin.contains("patterns.some((pattern) => permissionText(pattern) === context) ? null : context"))
    #expect(plugin.contains("permission_can_always: true"))
    #expect(plugin.contains("client.permission?.reply"))
    #expect(plugin.contains("client.postSessionIdPermissionsPermissionId"))
    #expect(plugin.contains("decision === \"allowOnce\" ? \"once\""))
    #expect(plugin.contains("let sendQueue = Promise.resolve()"))
    #expect(plugin.contains("await child.exited"))
    #expect(plugin.contains("sessionID = identifier(sessionID)"))
    #expect(!plugin.contains("session_id: bounded(sessionID"))
    #expect(!plugin.contains("properties.prompt"))
}
