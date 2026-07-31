import Foundation

public enum OpenCodePlugin {
    public static func generate(hookPath: String, includeCostTracking: Bool = false) -> String {
        let pathLiteral = jsonString(hookPath)
        let costState = includeCostTracking ? """
        const costGeneration = crypto.randomUUID()
        const sessionCosts = new Map()
        const messageCosts = new Map()
        """ : ""
        let costPayload = includeCostTracking ? """
          if (cost) {
            if (typeof cost.costUSD === "number" && cost.costUSD >= 0) payload.cost_usd = cost.costUSD
            payload.cost_generation = costGeneration
          }
        """ : ""
        let costEvent = includeCostTracking ? """
            if (event.type === "message.updated") {
              const message = properties.info
              const sid = identifier(message?.sessionID)
              const messageID = identifier(message?.id)
              if (!sid || !messageID || message?.role !== "assistant") return
              const cost = typeof message.cost === "number" && Number.isFinite(message.cost) && message.cost >= 0
                ? message.cost
                : null
              if (cost == null) return
              const messageKey = JSON.stringify([sid, messageID])
              const previous = messageCosts.get(messageKey) ?? 0
              if (cost === previous) return
              if (!setCostBaseline(messageCosts, messageKey, cost)) return
              const sessionCost = Math.max(0, (sessionCosts.get(sid) ?? 0) + cost - previous)
              if (!setCostBaseline(sessionCosts, sid, sessionCost)) return
              send(
                "metadata",
                sid,
                sessionParents.get(sid),
                null,
                directory,
                null,
                taskLabels.get(sid) ?? fallbackTaskLabel,
                null,
                { costUSD: sessionCost },
              )
              return
            }

        """ : ""
        let costCleanup = includeCostTracking ? """
              sessionCosts.delete(sessionID)
              for (const key of messageCosts.keys()) {
                if (JSON.parse(key)[0] === sessionID) messageCosts.delete(key)
              }
        """ : ""

        return """
        // \(NotchBotIntegrationFiles.generatedMarker). Do not edit.
        const hookPath = \(pathLiteral)
        const taskLabels = new Map()
        \(costState)
        const sessionParents = new Map()
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

        function nativeRequestID(properties) {
          return identifier(properties.id ?? properties.requestID ?? properties.permissionID)
        }

        function requestKey(sessionID, kind, requestID) {
          return JSON.stringify([sessionID, kind, requestID])
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

        function send(kind, sessionID, parentSessionID, reason, directory, expiresAfter, label, request, cost) {
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
          if (label) payload.task_label = label
          if (request) {
            payload.request_id = request.id
            payload.request_kind = request.kind
            payload.request_state = request.state
          }
        \(costPayload)
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
          const sendEvent = (kind, sessionID, reason, expiresAfter) =>
            send(kind, sessionID, sessionParents.get(sessionID), reason, directory, expiresAfter, taskLabels.get(sessionID) ?? fallbackTaskLabel)
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
                taskLabels.get(sessionID) ?? fallbackTaskLabel,
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
                taskLabels.get(sessionID) ?? fallbackTaskLabel,
                { id: requestID, kind: "permission", state: "opened" },
              )
              return
            }
            const args = [hookPath, "--source", "opencode", "--kind", "attention", "--reason", "OpenCode needs permission", "--mode", "permission"]
            const payload = {
              session_id: sessionID,
              parent_session_id: sessionParents.get(sessionID),
              cwd: bounded(directory, 1024),
              task_label: taskLabels.get(sessionID) ?? fallbackTaskLabel,
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
                    taskLabels.get(sessionID) ?? fallbackTaskLabel,
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
                  taskLabels.get(sessionID) ?? fallbackTaskLabel,
                  { id: requestID, kind: "permission", state: "opened" },
                )
              }
            } finally {
              if (activePermissionRequests.get(key)?.child === child) activePermissionRequests.delete(key)
            }
          }
          return {
          event: async ({ event }) => {
            const properties = event.properties ?? {}
        \(costEvent)
            const sessionID = identifier(properties.sessionID ?? properties.info?.id)
            if (!sessionID) return

            if (event.type === "permission.replied" || event.type === "permission.v2.replied") {
              resolveRequest(sessionID, "permission", nativeRequestID(properties))
              return
            }
            if (event.type === "session.deleted") {
              setBounded(sessionGenerations, sessionID, {})
              sendEvent("cleared", sessionID, null, null)
              taskLabels.delete(sessionID)
        \(costCleanup)
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
              const label = taskLabel(properties.info?.title)
              if (label) {
                setBounded(taskLabels, sessionID, label)
              }
              send("metadata", sessionID, parentSessionID, null, directory, null, label)
            }
            if (!sessionParents.has(sessionID)) {
              const parentResolution = resolveParentSessionID(sessionID, properties.info)
              if (immediateAttentionEvents.has(event.type)) {
                void parentResolution.then((parentSessionID) => {
                  if (parentSessionID) {
                    send("metadata", sessionID, parentSessionID, null, directory, null, taskLabels.get(sessionID) ?? fallbackTaskLabel)
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
                  taskLabels.get(sessionID) ?? fallbackTaskLabel,
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
            && contents.contains("export const NotchBot")
            && contents.contains("Bun.spawn(args")
            && contents.contains("process.unref()")
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

}
