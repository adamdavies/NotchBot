import Foundation

public enum OpenCodePlugin {
    public static func generate(hookPath: String, assistantExcerptsEnabled: Bool) -> String {
        let pathLiteral = jsonString(hookPath)
        let excerptStorage = assistantExcerptsEnabled ? enabledExcerptStorage : ""
        let eventCapture = assistantExcerptsEnabled ? enabledEventCapture : ""
        let attentionSummary = assistantExcerptsEnabled
            ? "const summary = takeResponse(sessionID)"
            : "const summary = null"
        let errorCleanup = assistantExcerptsEnabled ? "\n            latestResponses.delete(sessionID)" : ""
        let deletionCleanup = assistantExcerptsEnabled ? "\n            latestResponses.delete(sessionID)" : ""

        return """
        // \(NotchBotIntegrationFiles.generatedMarker). Do not edit.
        const hookPath = \(pathLiteral)
        const taskLabels = new Map()
        const sessionParents = new Map()
        const completedSessions = new Set()
        const waitingSessions = new Set()
        let sendQueue = Promise.resolve()
        \(excerptStorage)
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

        function taskLabel(value) {
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

        function basename(value) {
          if (typeof value !== "string") return null
          return value.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || null
        }

        function send(kind, sessionID, parentSessionID, reason, directory, expiresAfter, summary, label) {
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
          if (summary) payload.last_assistant_message = summary
          if (label) payload.task_label = label
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
          const fallbackTaskLabel = taskLabel(project?.name) ?? taskLabel(basename(worktree)) ?? taskLabel(basename(directory)) ?? "OpenCode"
          const sendEvent = (kind, sessionID, reason, expiresAfter, summary) =>
            send(kind, sessionID, sessionParents.get(sessionID), reason, directory, expiresAfter, summary, taskLabels.get(sessionID) ?? fallbackTaskLabel)
          const sendWorking = (sessionID) => {
            completedSessions.delete(sessionID)
            waitingSessions.delete(sessionID)
            sendEvent("working", sessionID, null, null, null)
          }
          const sendCompletion = (sessionID, summary) => {
            if (waitingSessions.has(sessionID)) return
            if (sessionParents.get(sessionID)) {
              sendEvent("cleared", sessionID, null, null, summary)
            } else if (!completedSessions.has(sessionID)) {
              addBounded(completedSessions, sessionID)
              sendEvent("attention", sessionID, "OpenCode finished working", null, summary)
            }
          }
          const resolveParentSessionID = async (sessionID, info) => {
            const direct = identifier(info?.parentID)
            if (direct && direct !== sessionID) {
              setBounded(sessionParents, sessionID, direct)
              return direct
            }
            if (sessionParents.has(sessionID)) return sessionParents.get(sessionID)
            try {
              const response = await client.session.get({ path: { id: sessionID } })
              const parentSessionID = identifier(response?.data?.parentID ?? response?.parentID)
              setBounded(sessionParents, sessionID, parentSessionID && parentSessionID !== sessionID ? parentSessionID : null)
            } catch (_) {
              // Session metadata can be unavailable during shutdown; lifecycle handling still continues.
            }
            return sessionParents.get(sessionID) ?? null
          }
          return {
          event: async ({ event }) => {
            const properties = event.properties ?? {}
            const sessionID = identifier(properties.sessionID ?? properties.info?.id)
        \(eventCapture)
            if (!sessionID) return

            if (event.type === "session.created" || event.type === "session.updated") {
              const parentSessionID = identifier(properties.info?.parentID)
              setBounded(sessionParents, sessionID, parentSessionID && parentSessionID !== sessionID ? parentSessionID : null)
              const label = taskLabel(properties.info?.title)
              if (label) {
                setBounded(taskLabels, sessionID, label)
              }
              send("metadata", sessionID, parentSessionID, null, directory, null, null, label)
            }
            if (!sessionParents.has(sessionID)) await resolveParentSessionID(sessionID, properties.info)

            switch (event.type) {
              case "session.status":
                if (properties.status?.type === "busy" || properties.status?.type === "retry") {
                  sendWorking(sessionID)
                } else if (properties.status?.type === "idle") {
                  \(attentionSummary)
                  await resolveParentSessionID(sessionID, properties.info)
                  sendCompletion(sessionID, summary)
                }
                break
              case "session.idle": {
                \(attentionSummary)
                await resolveParentSessionID(sessionID, properties.info)
                sendCompletion(sessionID, summary)
                break
              }
              case "permission.asked":
              case "permission.v2.asked":
                addBounded(waitingSessions, sessionID)
                sendEvent("attention", sessionID, "OpenCode needs permission", null, null)
                break
              case "question.asked":
              case "question.v2.asked":
                addBounded(waitingSessions, sessionID)
                sendEvent("attention", sessionID, "OpenCode has a question", null, null)
                break
              case "permission.replied":
              case "permission.v2.replied":
              case "question.replied":
              case "question.v2.replied":
              case "question.rejected":
              case "question.v2.rejected":
                sendWorking(sessionID)
                break
              case "session.error":
                addBounded(waitingSessions, sessionID)
                sendEvent("attention", sessionID, "OpenCode encountered an error", null, null)\(errorCleanup)
                break
              case "session.deleted":
                sendEvent("cleared", sessionID, null, null, null)
                taskLabels.delete(sessionID)
                sessionParents.delete(sessionID)\(deletionCleanup)
                completedSessions.delete(sessionID)
                waitingSessions.delete(sessionID)
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

    public static func isOwned(_ contents: String) -> Bool {
        hasGeneratedHeader(NotchBotIntegrationFiles.generatedMarker, in: contents)
    }

    public static func isPreviousVersion(_ contents: String) -> Bool {
        NotchBotIntegrationFiles.previousGeneratedMarkers.contains { hasGeneratedHeader($0, in: contents) }
            && contents.contains("function send(kind, sessionID")
            && contents.contains("Bun.spawn(args")
            && contents.contains("case \"session.status\"")
            && contents.contains("\"tool.execute.before\"")
    }

    public static func isLegacyV01(_ contents: String) -> Bool {
        contents.hasPrefix("// Generated by NotchBot. Remove this file")
            && contents.contains("const latestResponses = new Map()")
            && contents.contains("Bun.spawn(args")
            && contents.contains("--source\", \"opencode")
    }

    private static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try! encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func hasGeneratedHeader(_ marker: String, in contents: String) -> Bool {
        contents.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
            == Substring("// \(marker). Do not edit.")
    }

    private static let enabledExcerptStorage = """

        const messageSessions = new Map()
        const latestResponses = new Map()

        function excerpt(value) {
          if (typeof value !== "string") return null
          const normalized = value.replace(/\\s+/g, " ").trim()
          return normalized.length > 240 ? normalized.slice(0, 237).trimEnd() + "..." : normalized
        }

        function takeResponse(sessionID) {
          const response = latestResponses.get(sessionID) ?? null
          latestResponses.delete(sessionID)
          return response
        }
    """

    private static let enabledEventCapture = """

            if (event.type === "message.updated" && properties.info?.role === "assistant") {
              const messageID = identifier(properties.info.id)
              const messageSessionID = identifier(properties.info.sessionID)
              if (messageID && messageSessionID) setBounded(messageSessions, messageID, messageSessionID)
            }
            if (event.type === "message.part.updated" && properties.part?.type === "text") {
              const partSessionID = messageSessions.get(identifier(properties.part.messageID))
              const response = excerpt(properties.part.text)
              if (partSessionID && response) setBounded(latestResponses, partSessionID, response)
            }
    """
}
