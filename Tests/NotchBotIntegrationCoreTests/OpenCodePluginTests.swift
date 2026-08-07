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

/// Without the opt-in, none of the usage or cost machinery may reach the generated file — not the
/// hook that reads the model limit, not the token access, and not the payload fields.
@Test func pluginOmitsAllUsageAndCostCollectionWhenTrackingIsOff() {
    let plugin = OpenCodePlugin.generate(hookPath: "/tmp/hook", includeCostTracking: false)

    #expect(!plugin.contains("chat.params"))
    #expect(!plugin.contains("event.type === \"message.updated\""))
    #expect(!plugin.contains("event.type === \"session.compacted\""))
    #expect(!plugin.contains("tokens"))
    #expect(!plugin.contains("limit?.context"))
    #expect(!plugin.contains("usageComponent"))
    #expect(!plugin.contains("contextPercentage"))
    #expect(!plugin.contains("contextUpdateFor"))
    #expect(!plugin.contains("sessionContextLimits"))
    #expect(!plugin.contains("sessionContextPercentages"))
    #expect(!plugin.contains("context_window"))
    #expect(!plugin.contains("used_percentage"))
    #expect(!plugin.contains("payload.cost_usd"))
    #expect(!plugin.contains("payload.cost_generation"))
    #expect(!plugin.contains("costGeneration"))
    #expect(!plugin.contains("messageCosts"))
    #expect(!plugin.contains("sessionCosts"))
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
    #expect(plugin.contains("setCostBaseline(messageCosts, messageKey, cost)"))
    #expect(plugin.contains("payload.cost_usd = usage.costUSD"))
    #expect(plugin.contains("payload.cost_generation = costGeneration"))
    #expect(!plugin.contains("payload.input_tokens"))
    #expect(!plugin.contains("payload.output_tokens"))
}

/// The derived percentage must match what OpenCode's own sidebar shows: the same five token
/// components over the model context limit, qualified on a completed response.
@Test func pluginDerivesContextUsageTheSameWayOpenCodeDoes() {
    let plugin = OpenCodePlugin.generate(hookPath: "/tmp/hook", includeCostTracking: true)

    #expect(plugin.contains("\"chat.params\": async (input, _output) => {"))
    #expect(plugin.contains("const limit = input?.model?.limit?.context"))
    #expect(plugin.contains("setBounded(sessionContextLimits, sid, limit)"))

    #expect(plugin.contains("const output = usageComponent(tokens.output)"))
    #expect(plugin.contains("+ usageComponent(tokens.input)"))
    #expect(plugin.contains("+ usageComponent(tokens.reasoning)"))
    #expect(plugin.contains("+ usageComponent(tokens.cache?.read)"))
    #expect(plugin.contains("+ usageComponent(tokens.cache?.write)"))
    #expect(plugin.contains("if (!Number.isFinite(output) || output <= 0) return undefined"))
    #expect(plugin.contains("Number.isFinite(value) && value >= 0 ? value : NaN"))
    #expect(plugin.contains("const percentage = Math.round((total / limit) * 100)"))
    #expect(plugin.contains("return Math.min(100, Math.max(0, percentage))"))

    // Only the derived scalar crosses the boundary.
    #expect(plugin.contains("payload.context_window = usage.contextWindow === null"))
    #expect(plugin.contains(": { used_percentage: usage.contextWindow }"))
    #expect(!plugin.contains("payload.tokens"))
    #expect(!plugin.contains("payload.context_limit"))
    #expect(!plugin.contains("payload.model"))
    #expect(!plugin.contains("input.model.id"))
    #expect(!plugin.contains("providerID"))
}

@Test func pluginClearsContextUsageWhenItStopsBeingTrue() {
    let plugin = OpenCodePlugin.generate(hookPath: "/tmp/hook", includeCostTracking: true)

    #expect(plugin.contains("event.type === \"session.compacted\" || event.type === \"message.removed\""))
    #expect(plugin.contains("if (!sid || !sessionContextPercentages.has(sid)) return"))
    #expect(plugin.contains("{ contextWindow: null }"))
    // No stored percentage means nothing to retract, so no event is sent.
    #expect(plugin.contains("if (previous === undefined) return undefined"))
    // A completed response with no usable context limit clears rather than keeping a stale figure.
    #expect(plugin.contains("if (typeof limit !== \"number\" || !Number.isFinite(limit) || limit <= 0) return null"))

    // Session deletion drops every per-session map alongside the existing `cleared` event.
    #expect(plugin.contains("sessionContextLimits.delete(sessionID)"))
    #expect(plugin.contains("sessionContextPercentages.delete(sessionID)"))
}

@Test func pluginDeduplicatesContextAndCostIndependently() {
    let plugin = OpenCodePlugin.generate(hookPath: "/tmp/hook", includeCostTracking: true)

    #expect(plugin.contains("const contextWindow = contextUpdateFor(sid, message.tokens)"))
    // Either one alone is enough to send; neither suppresses the other.
    #expect(plugin.contains("if (sessionCost == null && contextWindow === undefined) return"))
    #expect(plugin.contains("{ costUSD: sessionCost, contextWindow }"))
    #expect(plugin.contains("if (derived === previous) return undefined"))
    #expect(plugin.contains("setBounded(sessionContextPercentages, sessionID, derived)"))
    // Per-session usage state stays bounded like every other map in the plugin.
    #expect(plugin.contains("const sessionContextLimits = new Map()"))
    #expect(plugin.contains("const sessionContextPercentages = new Map()"))
    #expect(plugin.contains("map.size >= 256"))
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

@Test(arguments: [
    "{{USAGE_STATE}}",
    "{{USAGE_HELPERS}}",
    "{{USAGE_PAYLOAD}}",
    "{{USAGE_EVENT}}",
    "{{USAGE_PARAMS}}",
    "{{USAGE_CLEANUP}}",
])
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
