import Testing
@testable import NotchBotIntegrationCore

@Test func pluginNeverCollectsAssistantResponseText() {
    let plugin = OpenCodePlugin.generate(
        hookPath: "/Users/test/Library/Application Support/NotchBot/bin/notchbot-hook"
    )

    #expect(plugin.contains("event.type === \"message.part.updated\""))
    #expect(plugin.contains("part?.state?.title"))
    #expect(plugin.contains("const stateTimestamp = properties.time"))
    #expect(plugin.contains("part?.time?.updated"))
    #expect(plugin.contains("part?.state?.time?.updated"))
    #expect(plugin.contains("const partID = identifier(part?.id)"))
    #expect(plugin.contains("properties.part?.sessionID"))
    #expect(!plugin.contains("properties.part.text"))
    #expect(!plugin.contains("part?.text"))
    #expect(!plugin.contains("part?.reasoning"))
    #expect(!plugin.contains("part?.state?.input"))
    #expect(!plugin.contains("part?.state?.output"))
    #expect(!plugin.contains("latestResponses"))
    #expect(!plugin.contains("last_assistant_message"))
    #expect(!plugin.contains("--session"))
    #expect(!plugin.contains("--cwd"))
    #expect(!plugin.contains("--summary"))
    #expect(plugin.contains("stdin: \"pipe\""))
    #expect(plugin.contains("JSON.stringify(payload)"))
    #expect(!plugin.contains("event.type === \"message.updated\""))
    #expect(!plugin.contains("payload.cost_usd"))
}

@Test func pluginCostTrackingIsOptInAndDeduplicatesMessageUpdates() {
    let plugin = OpenCodePlugin.generate(hookPath: "/tmp/hook", includeCostTracking: true)

    #expect(plugin.contains("event.type === \"message.updated\""))
    #expect(plugin.contains("const message = properties.info"))
    #expect(plugin.contains("identifier(message?.sessionID)"))
    #expect(plugin.contains("const messageCosts = new Map()"))
    #expect(plugin.contains("const costGeneration = crypto.randomUUID()"))
    #expect(plugin.contains("const previous = messageCosts.get(messageKey) ?? 0"))
    #expect(plugin.contains("+ cost - previous"))
    #expect(plugin.contains("map.size >= 10000) return false"))
    #expect(plugin.contains("if (!setCostBaseline(messageCosts, messageKey, cost)) return"))
    #expect(plugin.contains("payload.cost_usd = cost.costUSD"))
    #expect(plugin.contains("payload.cost_generation = costGeneration"))
    #expect(!plugin.contains("payload.input_tokens"))
    #expect(!plugin.contains("payload.output_tokens"))
}

@Test func pluginBoundsLifecycleStateAndHandlesRejectedQuestions() {
    let plugin = OpenCodePlugin.generate(hookPath: "/tmp/hook")

    #expect(plugin.contains("map.size >= 256"))
    #expect(plugin.contains("question.rejected"))
    #expect(plugin.contains("question.v2.rejected"))
}

@Test func pluginEscapesHookPathAsAJSONString() {
    let plugin = OpenCodePlugin.generate(hookPath: "/tmp/a\"b\\c")
    #expect(plugin.contains("const hookPath = \"/tmp/a\\\"b\\\\c\""))
}

@Test(arguments: ["{{COST_STATE}}", "{{COST_PAYLOAD}}", "{{COST_EVENT}}", "{{COST_CLEANUP}}"])
func pluginPreservesPlaceholderTextInHookPath(placeholder: String) {
    let hookPath = "/tmp/\(placeholder)/notchbot-hook"

    for includeCostTracking in [false, true] {
        let plugin = OpenCodePlugin.generate(
            hookPath: hookPath,
            includeCostTracking: includeCostTracking
        )
        #expect(plugin.contains("const hookPath = \"\(hookPath)\""))
    }
}

@Test func requestRepliesResolveOnlyTheirExactRequest() throws {
    let plugin = OpenCodePlugin.generate(hookPath: "/tmp/hook")
    let resolution = try #require(plugin.range(of: "event.type === \"permission.replied\""))
    let parentLookup = try #require(plugin.range(of: "if (!sessionParents.has(sessionID))"))

    #expect(resolution.lowerBound < parentLookup.lowerBound)
    #expect(plugin.contains("resolveRequest(sessionID, \"permission\", nativeRequestID(properties))"))
    #expect(plugin.contains("resolveRequest(sessionID, \"question\", nativeRequestID(properties))"))
    #expect(plugin.contains("knownRequests.delete(key)"))
    #expect(plugin.contains("\"request_resolved\""))
}

@Test func pluginCachesOnlyExplicitSessionTitlesAndUsesMetadataFallbacks() {
    let plugin = OpenCodePlugin.generate(hookPath: "/tmp/hook")

    #expect(plugin.contains("event.type === \"session.created\" || event.type === \"session.updated\""))
    #expect(plugin.contains("properties.info?.title"))
    #expect(plugin.contains("properties.info?.time?.updated"))
    #expect(plugin.contains("map.size >= 256"))
    #expect(plugin.contains("payload.session_title = sessionTitle"))
    #expect(plugin.contains("payload.activity_description = activityDescription"))
    #expect(plugin.contains("project?.name"))
    #expect(plugin.contains("basename(worktree)"))
    #expect(plugin.contains("basename(directory)"))
    #expect(plugin.contains("New session|Child session"))
    #expect(plugin.contains("sessionTitles.delete(sessionID)"))
    #expect(plugin.contains("sessionTitleTimestamps.delete(sessionID)"))
    #expect(plugin.contains("sessionActivities.delete(sessionID)"))
    #expect(plugin.contains("sessionActivityTimestamps.delete(sessionID)"))
    #expect(plugin.contains("const deletedSessions = new Set()"))
    #expect(plugin.contains("addBounded(deletedSessions, sessionID)"))
    #expect(plugin.contains("else if (deletedSessions.has(sessionID)) return"))
    #expect(plugin.contains("timestamp < previousTimestamp"))
    #expect(plugin.contains("const sessionParents = new Map()"))
    #expect(plugin.contains("properties.info?.parentID"))
    #expect(plugin.contains("payload.parent_session_id = parentSessionID"))
    #expect(plugin.contains("client.session.get({ path: { id: sessionID } })"))
    #expect(plugin.contains("if (!sessionParents.has(input.sessionID)) await resolveParentSessionID(input.sessionID)"))
    #expect(plugin.contains("const completedSessions = new Set()"))
    #expect(plugin.contains("const knownRequests = new Map()"))
    #expect(!plugin.contains("waitingSessions"))
    #expect(plugin.contains("if (!completedSessions.has(sessionID))"))
    #expect(plugin.contains("sendEvent(\"attention\", sessionID, \"OpenCode finished working\", null)"))
    #expect(plugin.contains("sendCompletion(sessionID)"))
    #expect(!plugin.contains("OpenCode finished working\", 2.5"))
    #expect(plugin.contains("sessionParents.delete(sessionID)"))
    #expect(plugin.contains("sendEvent(\"attention\", sessionID, \"OpenCode needs your attention\""))
    #expect(plugin.contains("case \"permission.updated\":"))
    #expect(plugin.contains("void requestPermission(sessionID, properties, requestID, key)"))
    #expect(plugin.contains("const activePermissionRequests = new Map()"))
    #expect(plugin.contains("if (activePermissionRequests.has(key)) return"))
    #expect(plugin.contains("activePermissionRequests.size >= 32"))
    #expect(plugin.contains("activePermissionRequests.set(key, { sessionID, child })"))
    #expect(plugin.contains("active.child.kill()"))
    #expect(plugin.contains("setTimeout(sendResolution, 250)"))
    #expect(plugin.contains("setTimeout(sendResolution, 1000)"))
    #expect(plugin.contains("const resolvedRequests = new Map()"))
    #expect(plugin.contains("activePermissionRequests.delete(key)"))
    #expect(plugin.contains("request_id: requestID"))
    #expect(plugin.contains("request_kind: \"permission\""))
    #expect(plugin.contains("request_state: \"opened\""))
    #expect(plugin.contains("const immediateAttentionEvents = new Set(["))
    #expect(plugin.contains("if (immediateAttentionEvents.has(event.type))"))
    #expect(plugin.contains("void parentResolution.then((parentSessionID) =>"))
    #expect(plugin.contains("\"--mode\", \"permission\""))
    #expect(plugin.contains("permission_summary: permissionSummary(properties)"))
    #expect(plugin.contains("permission_context: permissionContext(properties)"))
    #expect(plugin.contains("metadata.command"))
    #expect(plugin.contains("metadata.file_path"))
    #expect(plugin.contains("patterns.some((pattern) => permissionText(pattern) === context) ? null : context"))
    #expect(plugin.contains("permission_can_always: true"))
    #expect(plugin.contains("bounded(properties.action, 128)"))
    #expect(plugin.contains("Array.isArray(properties.resources)"))
    #expect(plugin.contains("client.permission?.reply"))
    #expect(plugin.contains("client.postSessionIdPermissionsPermissionId"))
    #expect(plugin.contains("decision === \"allowOnce\" ? \"once\""))
    #expect(plugin.contains("let sendQueue = Promise.resolve()"))
    #expect(plugin.contains("await child.exited"))
    #expect(plugin.contains("sessionID = identifier(sessionID)"))
    #expect(!plugin.contains("session_id: bounded(sessionID"))
    #expect(!plugin.contains("properties.prompt"))
}

@Test func pluginKeepsTimestampedSessionAndActivityStateIndependent() {
    let plugin = OpenCodePlugin.generate(hookPath: "/tmp/hook")

    #expect(plugin.contains("const sessionTitles = new Map()"))
    #expect(plugin.contains("const sessionTitleTimestamps = new Map()"))
    #expect(plugin.contains("const sessionActivities = new Map()"))
    #expect(plugin.contains("const sessionActivityTimestamps = new Map()"))
    #expect(plugin.contains("previousTimestamp != null && timestamp < previousTimestamp"))
    #expect(plugin.contains("map.delete(oldestSessionID)"))
    #expect(plugin.contains("timestamps.delete(oldestSessionID)"))
    #expect(plugin.contains("sessionTitles.get(sessionID) ?? fallbackSessionTitle"))
    #expect(plugin.contains("sessionActivities.get(sessionID)"))
    #expect(plugin.contains("if (!sessionID || !value) return false"))
    #expect(!plugin.contains("payload.task_label"))
}
