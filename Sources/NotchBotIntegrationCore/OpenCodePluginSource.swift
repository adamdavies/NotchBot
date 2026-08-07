import Foundation

/// Raw JavaScript for the generated OpenCode plugin, kept in one place so it can be
/// syntax-checked as JavaScript. `Tools/check-plugin-js.sh` runs `node --check` over the
/// generated output; edit the template here rather than assembling JS in `OpenCodePlugin`.
enum OpenCodePluginSource {
    static let usageState = """
    const costGeneration = crypto.randomUUID()
    const sessionCosts = new Map()
    const messageCosts = new Map()
    const sessionContextLimits = new Map()
    const sessionContextPercentages = new Map()
    """

    static let usagePayload = """
      if (usage) {
        if (typeof usage.costUSD === "number" && usage.costUSD >= 0) {
          payload.cost_usd = usage.costUSD
          payload.cost_generation = costGeneration
        }
        if (usage.contextWindow !== undefined) {
          payload.context_window = usage.contextWindow === null
            ? {}
            : { used_percentage: usage.contextWindow }
        }
      }
    """

    /// Context-usage helpers. `usageComponent` treats an absent token field as zero so a model
    /// that reports no reasoning or cache tokens still yields a usable total, but rejects a field
    /// that is present and unusable — that is a malformed payload, not an empty one.
    static let usageHelpers = """
    function usageComponent(value) {
      if (value === undefined || value === null) return 0
      return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : NaN
    }

    // Returns undefined for "no authoritative update", null for "clear the stored percentage",
    // or a bounded integer percentage. Mirrors the sum OpenCode's own sidebar displays.
    function contextPercentage(sessionID, tokens) {
      if (!tokens || typeof tokens !== "object") return undefined
      const output = usageComponent(tokens.output)
      // OpenCode only treats a response as measurable once it has produced output; earlier
      // streaming updates would otherwise report a percentage that immediately jumps.
      if (!Number.isFinite(output) || output <= 0) return undefined
      const total = output
        + usageComponent(tokens.input)
        + usageComponent(tokens.reasoning)
        + usageComponent(tokens.cache?.read)
        + usageComponent(tokens.cache?.write)
      if (!Number.isFinite(total)) return null
      const limit = sessionContextLimits.get(sessionID)
      if (typeof limit !== "number" || !Number.isFinite(limit) || limit <= 0) return null
      const percentage = Math.round((total / limit) * 100)
      if (!Number.isFinite(percentage)) return null
      // OpenCode can display over 100; NotchBot's meter domain is explicitly bounded.
      return Math.min(100, Math.max(0, percentage))
    }

    // Applies the dedup rule and reports what, if anything, should go on the wire.
    function contextUpdateFor(sessionID, tokens) {
      const derived = contextPercentage(sessionID, tokens)
      if (derived === undefined) return undefined
      const previous = sessionContextPercentages.get(sessionID)
      if (derived === null) {
        if (previous === undefined) return undefined
        sessionContextPercentages.delete(sessionID)
        return null
      }
      if (derived === previous) return undefined
      setBounded(sessionContextPercentages, sessionID, derived)
      return derived
    }

    """

    static let usageEvent = """
        if (event.type === "session.compacted" || event.type === "message.removed") {
          // Both invalidate the last derived percentage. The next completed assistant response
          // establishes the new one; until then a retained figure would be wrong, not merely old.
          const sid = identifier(properties.sessionID ?? properties.info?.sessionID)
          if (!sid || !sessionContextPercentages.has(sid)) return
          sessionContextPercentages.delete(sid)
          send(
            "metadata",
            sid,
            sessionParents.get(sid),
            null,
            directory,
            null,
            sessionTitles.get(sid) ?? fallbackSessionTitle,
            sessionActivities.get(sid),
            null,
            { contextWindow: null },
          )
          return
        }

        if (event.type === "message.updated") {
          const message = properties.info
          const sid = identifier(message?.sessionID)
          const messageID = identifier(message?.id)
          if (!sid || !messageID || message?.role !== "assistant") return
          const cost = typeof message.cost === "number" && Number.isFinite(message.cost) && message.cost >= 0
            ? message.cost
            : null
          // Cost and context are deduplicated independently: an unchanged cost must not suppress
          // a moved percentage, and an unchanged percentage must not suppress a new cost.
          let sessionCost = null
          if (cost != null) {
            const messageKey = JSON.stringify([sid, messageID])
            const previous = messageCosts.get(messageKey) ?? 0
            if (cost !== previous && setCostBaseline(messageCosts, messageKey, cost)) {
              const updated = Math.max(0, (sessionCosts.get(sid) ?? 0) + cost - previous)
              if (setCostBaseline(sessionCosts, sid, updated)) sessionCost = updated
            }
          }
          const contextWindow = contextUpdateFor(sid, message.tokens)
          if (sessionCost == null && contextWindow === undefined) return
          send(
            "metadata",
            sid,
            sessionParents.get(sid),
            null,
            directory,
            null,
            sessionTitles.get(sid) ?? fallbackSessionTitle,
            sessionActivities.get(sid),
            null,
            { costUSD: sessionCost, contextWindow },
          )
          return
        }

    """

    /// Captures the model context limit for a session. Only the numeric limit is read, and
    /// `output` is returned untouched so the plugin never influences the request.
    static let usageParams = """
      "chat.params": async (input, _output) => {
        const sid = identifier(input?.sessionID)
        const limit = input?.model?.limit?.context
        if (!sid || typeof limit !== "number" || !Number.isFinite(limit) || limit <= 0) return
        setBounded(sessionContextLimits, sid, limit)
      },

    """

    static let usageCleanup = """
          sessionCosts.delete(sessionID)
          sessionContextLimits.delete(sessionID)
          sessionContextPercentages.delete(sessionID)
          for (const key of messageCosts.keys()) {
            if (JSON.parse(key)[0] === sessionID) messageCosts.delete(key)
          }
    """

    static let template = """
    // {{MARKER}}. Do not edit.
    const hookPath = {{HOOK_PATH}}
    const sessionTitles = new Map()
    const sessionTitleTimestamps = new Map()
    const sessionActivities = new Map()
    const sessionActivityTimestamps = new Map()
    {{USAGE_STATE}}
    const sessionParents = new Map()
    const deletedSessions = new Set()
    const completedSessions = new Set()
    const knownRequests = new Map()
    const resolvedRequests = new Map()
    const activePermissionRequests = new Map()
    const sessionGenerations = new Map()
    const immediateAttentionEvents = new Set([
      "permission.updated",
      "permission.asked",
      "permission.v2.asked",
      "question.asked",
      "question.v2.asked",
      "session.error",
    ])
    let sendQueue = Promise.resolve()
    function bounded(value, maximum) {
      if (typeof value !== "string" || value.length === 0) return null
      return new TextEncoder().encode(value).length <= maximum ? value : null
    }

    function identifier(value) {
      if (typeof value !== "string" || value.length === 0) return null
      if (/[\\u0000-\\u001f\\u007f]/.test(value)) return null
      return new TextEncoder().encode(value).length <= 128 ? value : null
    }

    function setBounded(map, key, value) {
      if (!map.has(key) && map.size >= 256) map.delete(map.keys().next().value)
      map.set(key, value)
    }

    function addBounded(set, value) {
      if (!set.has(value) && set.size >= 256) set.delete(set.values().next().value)
      set.add(value)
    }

    function setCostBaseline(map, key, value) {
      if (!map.has(key) && map.size >= 10000) return false
      map.set(key, value)
      return true
    }

    {{USAGE_HELPERS}}
    function nativeRequestID(properties) {
      return identifier(properties.id ?? properties.requestID ?? properties.permissionID)
    }

    function requestKey(sessionID, kind, requestID) {
      return JSON.stringify([sessionID, kind, requestID])
    }

    function presentationText(value) {
      if (typeof value !== "string") return null
      const normalized = value.replace(/\\s+/g, " ").trim()
      if (!normalized || /^(New session|Child session)(?:\\s*-\\s*\\d{4}-\\d{2}-\\d{2}T[^ ]+)?$/i.test(normalized)) return null
      let result = ""
      for (const character of normalized) {
        if (Array.from(result).length >= 100) break
        const candidate = result + character
        if (new TextEncoder().encode(candidate).length > 512) break
        result = candidate
      }
      return result || null
    }

    function nativeTimestamp(value) {
      if (typeof value === "number" && Number.isFinite(value)) return value
      if (typeof value !== "string" || !value) return null
      const parsed = Date.parse(value)
      return Number.isFinite(parsed) ? parsed : null
    }

    function cacheTimestamped(map, timestamps, sessionID, value, timestamp) {
      value = presentationText(value)
      timestamp = nativeTimestamp(timestamp)
      if (!sessionID || !value) return false
      const previousTimestamp = timestamps.get(sessionID)
      if (map.has(sessionID) && (timestamp == null || (previousTimestamp != null && timestamp < previousTimestamp))) return false
      if (!map.has(sessionID) && map.size >= 256) {
        const oldestSessionID = map.keys().next().value
        map.delete(oldestSessionID)
        timestamps.delete(oldestSessionID)
      }
      map.set(sessionID, value)
      if (timestamp != null) timestamps.set(sessionID, timestamp)
      return true
    }

    function basename(value) {
      if (typeof value !== "string") return null
      return value.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || null
    }

    function permissionText(value) {
      if (typeof value !== "string") return null
      const normalized = value.replace(/\\s+/g, " ").trim()
      if (!normalized) return null
      let result = ""
      for (const character of normalized) {
        if (Array.from(result).length >= 240) break
        const candidate = result + character
        if (new TextEncoder().encode(candidate).length > 1024) break
        result = candidate
      }
      return result || null
    }

    function permissionSummary(properties) {
      const rawAction = bounded(properties.permission, 128) ?? bounded(properties.action, 128) ?? bounded(properties.type, 128) ?? bounded(properties.title, 128) ?? "Permission"
      const words = rawAction.replace(/[_-]+/g, " ")
      const action = words.charAt(0).toUpperCase() + words.slice(1)
      const patterns = Array.isArray(properties.patterns)
        ? properties.patterns
        : Array.isArray(properties.resources) ? properties.resources
        : Array.isArray(properties.pattern) ? properties.pattern : [properties.pattern]
      const detail = patterns.filter((value) => typeof value === "string" && value.length > 0).slice(0, 3).join(", ")
      return permissionText(`${action}${detail ? ` · ${detail}` : ""}`) ?? "Permission"
    }

    function permissionContext(properties) {
      const metadata = properties.metadata ?? {}
      const candidates = [
        metadata.command,
        metadata.file_path,
        metadata.filePath,
        metadata.path,
        metadata.url,
        metadata.query,
        metadata.description,
      ]
      const context = candidates.map(permissionText).find(Boolean) ?? null
      if (!context) return null
      const patterns = Array.isArray(properties.patterns)
        ? properties.patterns
        : Array.isArray(properties.resources) ? properties.resources
        : Array.isArray(properties.pattern) ? properties.pattern : [properties.pattern]
      return patterns.some((pattern) => permissionText(pattern) === context) ? null : context
    }

    function send(kind, sessionID, parentSessionID, reason, directory, expiresAfter, sessionTitle, activityDescription, request, usage) {
      sessionID = identifier(sessionID)
      if (!sessionID) return
      parentSessionID = identifier(parentSessionID)
      const args = [hookPath, "--source", "opencode", "--kind", kind]
      if (reason) args.push("--reason", reason)
      if (expiresAfter) args.push("--expires-after", String(expiresAfter))
      const payload = {
        session_id: sessionID,
        cwd: bounded(directory, 1024),
      }
      if (parentSessionID && parentSessionID !== sessionID) payload.parent_session_id = parentSessionID
      if (sessionTitle) payload.session_title = sessionTitle
      if (activityDescription) payload.activity_description = activityDescription
      if (request) {
        payload.request_id = request.id
        payload.request_kind = request.kind
        payload.request_state = request.state
      }
    {{USAGE_PAYLOAD}}
      sendQueue = sendQueue.then(async () => {
        try {
          const child = Bun.spawn(args, { stdin: "pipe", stdout: "ignore", stderr: "ignore" })
          child.stdin.write(JSON.stringify(payload))
          child.stdin.end()
          await child.exited
        } catch (_) {
          // The optional NotchBot UI may not be available.
        }
      })
    }

    export const NotchBot = async ({ client, directory, worktree, project }) => {
      const fallbackSessionTitle = presentationText(project?.name) ?? presentationText(basename(worktree)) ?? presentationText(basename(directory)) ?? "OpenCode"
      const sendEvent = (kind, sessionID, reason, expiresAfter) =>
        send(
          kind,
          sessionID,
          sessionParents.get(sessionID),
          reason,
          directory,
          expiresAfter,
          sessionTitles.get(sessionID) ?? fallbackSessionTitle,
          sessionActivities.get(sessionID),
        )
      const sendWorking = (sessionID) => {
        completedSessions.delete(sessionID)
        sendEvent("working", sessionID, null, null)
      }
      const sendCompletion = (sessionID) => {
        if (sessionParents.get(sessionID)) {
          sendEvent("cleared", sessionID, null, null)
        } else if (!completedSessions.has(sessionID)) {
          addBounded(completedSessions, sessionID)
          sendEvent("attention", sessionID, "OpenCode finished working", null)
        }
      }
      const resolveParentSessionID = async (sessionID, info) => {
        let generation = sessionGenerations.get(sessionID)
        if (!generation) {
          generation = {}
          setBounded(sessionGenerations, sessionID, generation)
        }
        const direct = identifier(info?.parentID)
        if (direct && direct !== sessionID) {
          setBounded(sessionParents, sessionID, direct)
          return direct
        }
        if (sessionParents.has(sessionID)) return sessionParents.get(sessionID)
        try {
          const response = await client.session.get({ path: { id: sessionID } })
          if (sessionGenerations.get(sessionID) !== generation) return null
          const parentSessionID = identifier(response?.data?.parentID ?? response?.parentID)
          setBounded(sessionParents, sessionID, parentSessionID && parentSessionID !== sessionID ? parentSessionID : null)
        } catch (_) {
          // Session metadata can be unavailable during shutdown; lifecycle handling still continues.
        }
        return sessionParents.get(sessionID) ?? null
      }
      const resolveRequest = (sessionID, kind, requestID) => {
        if (!requestID) return
        const key = requestKey(sessionID, kind, requestID)
        knownRequests.delete(key)
        setBounded(resolvedRequests, key, sessionID)
        const active = activePermissionRequests.get(key)
        if (active) {
          active.child.kill()
          activePermissionRequests.delete(key)
        }
        const sendResolution = () => {
          send(
            "request_resolved",
            sessionID,
            sessionParents.get(sessionID),
            null,
            directory,
            null,
            sessionTitles.get(sessionID) ?? fallbackSessionTitle,
            sessionActivities.get(sessionID),
            { id: requestID, kind, state: "resolved" },
          )
        }
        sendResolution()
        setTimeout(sendResolution, 250)
        setTimeout(sendResolution, 1000)
      }
      const requestPermission = async (sessionID, properties, requestID, key) => {
        if (activePermissionRequests.has(key)) return
        if (activePermissionRequests.size >= 32) {
          send(
            "attention",
            sessionID,
            sessionParents.get(sessionID),
            "OpenCode needs your attention",
            directory,
            null,
            sessionTitles.get(sessionID) ?? fallbackSessionTitle,
            sessionActivities.get(sessionID),
            { id: requestID, kind: "permission", state: "opened" },
          )
          return
        }
        const args = [hookPath, "--source", "opencode", "--kind", "attention", "--reason", "OpenCode needs permission", "--mode", "permission"]
        const payload = {
          session_id: sessionID,
          parent_session_id: sessionParents.get(sessionID),
          cwd: bounded(directory, 1024),
          session_title: sessionTitles.get(sessionID) ?? fallbackSessionTitle,
          activity_description: sessionActivities.get(sessionID),
          permission_summary: permissionSummary(properties),
          permission_context: permissionContext(properties),
          permission_can_always: true,
          request_id: requestID,
          request_kind: "permission",
          request_state: "opened",
        }
        let child = null
        try {
          child = Bun.spawn(args, { stdin: "pipe", stdout: "pipe", stderr: "ignore" })
          activePermissionRequests.set(key, { sessionID, child })
          child.stdin.write(JSON.stringify(payload))
          child.stdin.end()
          const output = await new Response(child.stdout).text()
          if (await child.exited !== 0 || !output) {
            if (knownRequests.has(key)) {
              send(
                "attention",
                sessionID,
                sessionParents.get(sessionID),
                "OpenCode needs permission",
                directory,
                null,
                sessionTitles.get(sessionID) ?? fallbackSessionTitle,
                sessionActivities.get(sessionID),
                { id: requestID, kind: "permission", state: "opened" },
              )
            }
            return
          }
          const decision = JSON.parse(output).decision
          const reply = decision === "allowOnce" ? "once" : decision === "alwaysAllow" ? "always" : decision === "decline" ? "reject" : null
          if (!reply) return
          if (typeof client.permission?.reply === "function") {
            await client.permission.reply({ requestID, reply })
          } else if (typeof client.postSessionIdPermissionsPermissionId === "function") {
            await client.postSessionIdPermissionsPermissionId({
              path: { id: sessionID, permissionID: requestID },
              body: { response: reply },
            })
          }
        } catch (_) {
          // OpenCode's native permission prompt remains available on helper or API failure.
          if (knownRequests.has(key)) {
            send(
              "attention",
              sessionID,
              sessionParents.get(sessionID),
              "OpenCode needs permission",
              directory,
              null,
              sessionTitles.get(sessionID) ?? fallbackSessionTitle,
              sessionActivities.get(sessionID),
              { id: requestID, kind: "permission", state: "opened" },
            )
          }
        } finally {
          if (activePermissionRequests.get(key)?.child === child) activePermissionRequests.delete(key)
        }
      }
      return {
    {{USAGE_PARAMS}}
      event: async ({ event }) => {
        const properties = event.properties ?? {}
    {{USAGE_EVENT}}
        const sessionID = identifier(
          event.type === "message.part.updated"
            ? properties.part?.sessionID
            : properties.sessionID ?? properties.info?.id
        )
        if (!sessionID) return
        if (event.type === "session.created") deletedSessions.delete(sessionID)
        else if (deletedSessions.has(sessionID)) return

        if (event.type === "message.part.updated") {
          const part = properties.part
          const partID = identifier(part?.id)
          const stateTimestamp = properties.time?.updated
            ?? properties.time?.end
            ?? properties.time?.start
            ?? properties.time
            ?? part?.time?.updated
            ?? part?.state?.time?.updated
            ?? part?.state?.time?.end
            ?? part?.state?.time?.start
          if (partID && nativeTimestamp(stateTimestamp) != null && cacheTimestamped(
            sessionActivities,
            sessionActivityTimestamps,
            sessionID,
            part?.state?.title,
            stateTimestamp,
          )) {
            send(
              "metadata",
              sessionID,
              sessionParents.get(sessionID),
              null,
              directory,
              null,
              sessionTitles.get(sessionID) ?? fallbackSessionTitle,
              sessionActivities.get(sessionID),
            )
          }
          return
        }

        if (event.type === "permission.replied" || event.type === "permission.v2.replied") {
          resolveRequest(sessionID, "permission", nativeRequestID(properties))
          return
        }
        if (event.type === "session.deleted") {
          setBounded(sessionGenerations, sessionID, {})
          addBounded(deletedSessions, sessionID)
          sendEvent("cleared", sessionID, null, null)
          sessionTitles.delete(sessionID)
          sessionTitleTimestamps.delete(sessionID)
          sessionActivities.delete(sessionID)
          sessionActivityTimestamps.delete(sessionID)
    {{USAGE_CLEANUP}}
          sessionParents.delete(sessionID)
          completedSessions.delete(sessionID)
          for (const [key, requestSessionID] of knownRequests) {
            if (requestSessionID !== sessionID) continue
            const [, kind, requestID] = JSON.parse(key)
            resolveRequest(sessionID, kind, requestID)
          }
          for (const [key, active] of activePermissionRequests) {
            if (active.sessionID !== sessionID) continue
            active.child.kill()
            activePermissionRequests.delete(key)
          }
          return
        }
        if (
          event.type === "question.replied"
          || event.type === "question.v2.replied"
          || event.type === "question.rejected"
          || event.type === "question.v2.rejected"
        ) {
          resolveRequest(sessionID, "question", nativeRequestID(properties))
          return
        }

        if (event.type === "session.created" || event.type === "session.updated") {
          const parentSessionID = identifier(properties.info?.parentID)
          setBounded(sessionParents, sessionID, parentSessionID && parentSessionID !== sessionID ? parentSessionID : null)
          cacheTimestamped(
            sessionTitles,
            sessionTitleTimestamps,
            sessionID,
            properties.info?.title,
            properties.info?.time?.updated,
          )
          send(
            "metadata",
            sessionID,
            parentSessionID,
            null,
            directory,
            null,
            sessionTitles.get(sessionID) ?? fallbackSessionTitle,
            sessionActivities.get(sessionID),
          )
        }
        if (!sessionParents.has(sessionID)) {
          const parentResolution = resolveParentSessionID(sessionID, properties.info)
          if (immediateAttentionEvents.has(event.type)) {
            void parentResolution.then((parentSessionID) => {
              if (parentSessionID) {
                send(
                  "metadata",
                  sessionID,
                  parentSessionID,
                  null,
                  directory,
                  null,
                  sessionTitles.get(sessionID) ?? fallbackSessionTitle,
                  sessionActivities.get(sessionID),
                )
              }
            })
          } else {
            await parentResolution
          }
        }

        switch (event.type) {
          case "session.status":
            if (properties.status?.type === "busy" || properties.status?.type === "retry") {
              sendWorking(sessionID)
            } else if (properties.status?.type === "idle") {
              await resolveParentSessionID(sessionID, properties.info)
              sendCompletion(sessionID)
            }
            break
          case "session.idle": {
            await resolveParentSessionID(sessionID, properties.info)
            sendCompletion(sessionID)
            break
          }
          case "permission.updated":
          case "permission.asked":
          case "permission.v2.asked": {
            const requestID = nativeRequestID(properties)
            if (!requestID) {
              sendEvent("attention", sessionID, "OpenCode needs your attention", null)
              break
            }
            const key = requestKey(sessionID, "permission", requestID)
            if (resolvedRequests.has(key)) break
            if (knownRequests.has(key)) break
            if (knownRequests.size >= 256) {
              sendEvent("attention", sessionID, "OpenCode needs your attention", null)
              break
            }
            knownRequests.set(key, sessionID)
            void requestPermission(sessionID, properties, requestID, key)
            break
          }
          case "question.asked":
          case "question.v2.asked": {
            const requestID = nativeRequestID(properties)
            if (!requestID) {
              sendEvent("attention", sessionID, "OpenCode has a question", null)
              break
            }
            const key = requestKey(sessionID, "question", requestID)
            if (resolvedRequests.has(key)) break
            if (knownRequests.has(key)) break
            if (knownRequests.size >= 256) {
              sendEvent("attention", sessionID, "OpenCode has a question", null)
              break
            }
            knownRequests.set(key, sessionID)
            send(
              "attention",
              sessionID,
              sessionParents.get(sessionID),
              "OpenCode has a question",
              directory,
              null,
              sessionTitles.get(sessionID) ?? fallbackSessionTitle,
              sessionActivities.get(sessionID),
              { id: requestID, kind: "question", state: "opened" },
            )
            break
          }
          case "session.error":
            sendEvent("attention", sessionID, "OpenCode encountered an error", null)
            break
        }
      },
      "tool.execute.before": async (input) => {
        if (!sessionParents.has(input.sessionID)) await resolveParentSessionID(input.sessionID)
        sendWorking(input.sessionID)
      },
      }
    }
    """
}
