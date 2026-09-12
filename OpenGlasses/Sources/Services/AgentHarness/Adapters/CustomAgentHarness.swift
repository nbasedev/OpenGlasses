import Foundation

/// Generic HTTP agent harness (Plan N, Phase 2): drives any user-supplied endpoint described by a
/// `CustomHarnessConfig` — POST to start, GET to poll status, optional POST to cancel — mapping the
/// responses through `JSONPath`. Same opt-in spirit as a custom MCP server: supported, never
/// required, and entirely phone-only (we connect to a URL the user already runs).
///
/// The request building + response parsing live in `CustomHarnessConfig`/`JSONPath` (pure, tested);
/// this adapter is the thin async layer. `session` is injectable so tests exercise the HTTP shape
/// through a `URLProtocol` stub.
struct CustomAgentHarness: AgentHarness {
    let kind: AgentHarnessKind
    let config: CustomHarnessConfig
    var session: URLSession = .shared
    private let displayNameOverride: String?
    private let isConfiguredOverride: Bool?

    /// - Parameters:
    ///   - kind: the harness identity. Defaults to `.custom`; the Codex / Claude Code presets pass
    ///     `.codexCloud` / `.claudeRemote` so dispatched runs are tagged correctly.
    ///   - displayName / isConfigured: optional overrides for the preset-backed harnesses (whose
    ///     readiness is gated on a token, not just the start URL).
    init(kind: AgentHarnessKind = .custom,
         config: CustomHarnessConfig,
         displayName: String? = nil,
         isConfigured: Bool? = nil,
         session: URLSession = .shared) {
        self.kind = kind
        self.config = config
        self.displayNameOverride = displayName
        self.isConfiguredOverride = isConfigured
        self.session = session
    }

    var displayName: String {
        if let displayNameOverride { return displayNameOverride }
        return config.name.trimmingCharacters(in: .whitespaces).isEmpty ? kind.displayName : config.name
    }
    var isConfigured: Bool { isConfiguredOverride ?? config.isConfigured }

    // MARK: - AgentHarness

    func start(prompt: String, project: String?) async throws -> AgentRun {
        try await start(prompt: prompt, project: project, attachment: nil)
    }

    func start(prompt: String, project: String?, attachment: AgentTaskAttachment?) async throws -> AgentRun {
        guard let request = config.startRequest(prompt: prompt, project: project, attachment: attachment) else {
            throw AgentHarnessError.notConfigured(kind)
        }
        let json = try await sendJSON(request)
        guard let id = JSONPath.string(at: config.idPath, in: json) else {
            throw AgentHarnessError.transport("Response had no run id at '\(config.idPath)'.")
        }
        let status = AgentRunStatus.parse(JSONPath.string(at: config.statusPath, in: json)) ?? .running
        return AgentRun(id: id, harness: kind, prompt: prompt, project: project,
                        status: status, startedAt: Date())
    }

    func status(_ run: AgentRun) async throws -> AgentRunStatus {
        guard let request = config.statusRequest(runID: run.id) else { return .running }
        let json = try await sendJSON(request)
        return AgentRunStatus.parse(JSONPath.string(at: config.statusPath, in: json)) ?? .running
    }

    /// One poll: the status plus whatever the endpoint said about the outcome.
    ///
    /// The status-only `status(_:)` above can't carry a result, so a completed run was previously
    /// summarised from an empty `AgentRunResult` — the wearer heard "finished with no file changes"
    /// no matter what the agent actually did. Polling once for both keeps the spoken summary
    /// truthful without doubling the request rate.
    private func poll(_ run: AgentRun) async throws -> (status: AgentRunStatus, result: AgentRunResult, question: String?) {
        guard let request = config.statusRequest(runID: run.id) else {
            return (.running, AgentRunResult(), nil)
        }
        let json = try await sendJSON(request)
        let status = AgentRunStatus.parse(JSONPath.string(at: config.statusPath, in: json)) ?? .running
        return (status, Self.result(from: json), Self.question(from: json))
    }

    /// Map a status payload's `result` object onto `AgentRunResult`.
    ///
    /// Everything is optional: an endpoint that reports only a status still works, it just
    /// produces the generic summary. `summary` wins over `finalText` when both are present,
    /// since it is the line written to be spoken aloud.
    static func result(from json: [String: Any]) -> AgentRunResult {
        var result = AgentRunResult()
        guard let payload = JSONPath.value(at: "result", in: json) as? [String: Any] else { return result }

        let summary = (payload["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = (payload["finalText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        result.finalText = [summary, finalText].compactMap { $0 }.first { !$0.isEmpty }

        result.filesCreated = payload["filesCreated"] as? [String] ?? []
        result.filesModified = payload["filesChanged"] as? [String]
            ?? payload["filesModified"] as? [String] ?? []
        result.commandsRun = payload["commandsRun"] as? [String] ?? []
        result.pushed = payload["pushed"] as? Bool ?? false
        result.prURL = payload["prURL"] as? String
        if let error = (payload["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            result.error = error
        }
        return result
    }

    /// The text of a pending clarification, when the endpoint is reporting one.
    static func question(from json: [String: Any]) -> String? {
        guard let payload = JSONPath.value(at: "question", in: json) as? [String: Any] else { return nil }
        let text = (payload["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    /// Answer a pending clarification or approval.
    ///
    /// The protocol's `approved: Bool` can only say yes or no, so the spoken words are forwarded
    /// separately in `answer` — "no, skip authenticated users" has to reach the agent intact.
    /// A failure must throw: the session layer speaks "proceeding" on a silent success, and that
    /// would be a lie if the answer never arrived.
    func respondToInput(_ run: AgentRun, approved: Bool) async throws {
        try await respondToInput(run, approved: approved, answer: nil)
    }

    func respondToInput(_ run: AgentRun, approved: Bool, answer: String?) async throws {
        guard let request = config.inputRequest(runID: run.id, approved: approved, answer: answer) else {
            throw AgentHarnessError.unsupported("Replying to a question")
        }
        _ = try await sendJSON(request)
    }

    /// Record that this run's result has been spoken, so reconnecting doesn't announce it again.
    /// No-op when the endpoint declares no ack URL.
    func acknowledge(_ run: AgentRun) async throws {
        guard let request = config.ackRequest(runID: run.id) else { return }
        _ = try await sendJSON(request)
    }

    func cancel(_ run: AgentRun) async throws {
        guard let request = config.cancelRequest(runID: run.id) else {
            throw AgentHarnessError.unsupported("Cancel")
        }
        _ = try await sendJSON(request)
    }

    /// Status-poll event stream (no assumed push channel for an arbitrary endpoint). Emits
    /// `.started`, then polls until terminal and emits `.completed`/`.error`, forwarding the
    /// endpoint's own result so the spoken summary describes what actually happened.
    ///
    /// A non-terminal `awaitingInput` also surfaces its question, once per question, so a long
    /// job can ask something mid-run and have the wearer answer by voice.
    func events(for run: AgentRun) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(.started(run))
                var lastQuestion: String?
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    guard !Task.isCancelled else { break }

                    let poll = (try? await self.poll(run)) ?? (.running, AgentRunResult(), nil)

                    if poll.status == .awaitingInput, let question = poll.question {
                        // Only on change: the same question every 4s would talk over the wearer.
                        if question != lastQuestion {
                            lastQuestion = question
                            continuation.yield(.awaitingInput(prompt: question))
                        }
                    } else if poll.status != .awaitingInput {
                        lastQuestion = nil
                    }

                    if poll.status.isTerminal {
                        if poll.status == .failed {
                            // Prefer the endpoint's explanation over a generic failure line.
                            let detail = poll.result.error
                                ?? poll.result.finalText
                                ?? "The agent run failed."
                            continuation.yield(.error(detail))
                        } else {
                            continuation.yield(.completed(poll.result))
                        }
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - HTTP

    private func sendJSON(_ request: URLRequest) async throws -> [String: Any] {
        // The start/status URLs come from a user-supplied harness config, so they get the same
        // scheme, credential and cleartext rules as any other endpoint.
        try MedicalEgressGuard.check(.customAgentHarness)
        guard let url = request.url,
              (try? EndpointPolicy.require(url: url, for: .customAgentHarness)) != nil else {
            throw AgentHarnessError.transport("The harness URL is not a permitted endpoint.")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AgentHarnessError.transport("HTTP \(http.statusCode): \(String(body.prefix(160)))")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
