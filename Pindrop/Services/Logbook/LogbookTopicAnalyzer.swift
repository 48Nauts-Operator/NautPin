//
//  LogbookTopicAnalyzer.swift
//  Pindrop
//
//  Created on 2026-05-17.
//
//  Sends the last 7 days of dictation transcripts to the user's configured
//  local LLM (LM Studio / Ollama / any OpenAI-compatible endpoint) and
//  asks it to identify 3-7 topic clusters. Cached in UserDefaults for
//  one hour so the view doesn't refire the LLM on every open.
//

import Foundation

struct LogbookTopicCluster: Codable, Identifiable {
    let title: String
    let description: String
    var id: String { title }
}

struct LogbookTopicResult: Codable {
    let clusters: [LogbookTopicCluster]
    let generatedAt: Date
    let recordCountSignature: Int
}

enum LogbookTopicAnalyzerError: Error, LocalizedError {
    case noEndpoint
    case llmError(Int, String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .noEndpoint:
            return "No local LLM endpoint configured."
        case .llmError(let code, let body):
            return "Local LLM returned \(code): \(body)"
        case .parseFailed(let reason):
            return "Could not parse topic clusters: \(reason)"
        }
    }
}

@MainActor
final class LogbookTopicAnalyzer {
    private let cacheKey = "logbookTopicCache_v1"
    private let cacheLifetime: TimeInterval = 60 * 60 // 1 hour
    private let session: URLSession

    /// LLM endpoint. Reads from UserDefaults so the user can override.
    var endpointURL: URL? {
        let raw = UserDefaults.standard.string(forKey: "logbookLLMURL")
            ?? "http://127.0.0.1:1234/v1/chat/completions"
        // If the user only stored the base, append the chat path.
        if raw.hasSuffix("/v1") {
            return URL(string: raw + "/chat/completions")
        }
        return URL(string: raw)
    }

    var modelID: String {
        UserDefaults.standard.string(forKey: "logbookLLMModel")
            ?? "gemma-4-e4b-it-obliterated"
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Returns cached result if fresh and signature matches, else re-runs the LLM.
    func clusters(for records: [TranscriptionRecord], forceRefresh: Bool = false) async -> Result<[LogbookTopicCluster], LogbookTopicAnalyzerError> {
        let lastWeek = filterLastSevenDays(records)
        guard !lastWeek.isEmpty else {
            return .success([])
        }

        if !forceRefresh, let cached = readCache(), cached.recordCountSignature == lastWeek.count,
           Date().timeIntervalSince(cached.generatedAt) < cacheLifetime {
            return .success(cached.clusters)
        }

        do {
            let clusters = try await fetchFromLLM(transcripts: lastWeek.map { $0.text })
            writeCache(LogbookTopicResult(clusters: clusters,
                                          generatedAt: Date(),
                                          recordCountSignature: lastWeek.count))
            return .success(clusters)
        } catch let error as LogbookTopicAnalyzerError {
            return .failure(error)
        } catch {
            return .failure(.llmError(-1, error.localizedDescription))
        }
    }

    private func filterLastSevenDays(_ records: [TranscriptionRecord]) -> [TranscriptionRecord] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return records.filter { $0.timestamp >= cutoff }
    }

    private func fetchFromLLM(transcripts: [String]) async throws -> [LogbookTopicCluster] {
        guard let url = endpointURL else { throw LogbookTopicAnalyzerError.noEndpoint }

        // Cap context to ~8000 chars worth of transcripts so we don't blow context.
        let joined = transcripts.joined(separator: "\n---\n")
        let trimmed = joined.count > 8000 ? String(joined.suffix(8000)) : joined

        let systemPrompt = """
        You analyze a user's dictation transcripts and identify the main topic clusters they have been thinking about.
        Return ONLY a JSON array — no prose before or after, no markdown code fences.
        Each entry has two fields: "title" (2-5 words) and "description" (one sentence, under 25 words).
        Return between 3 and 7 clusters. If transcripts are too short to find distinct themes, return fewer.
        """

        let userPrompt = "Transcripts from the past week:\n\n\(trimmed)\n\nIdentify topic clusters."

        let body: [String: Any] = [
            "model": modelID,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.3,
            "max_tokens": 600
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LogbookTopicAnalyzerError.llmError(-1, "no HTTP response")
        }
        guard http.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw LogbookTopicAnalyzerError.llmError(http.statusCode, bodyStr)
        }

        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = outer["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LogbookTopicAnalyzerError.parseFailed("OpenAI envelope shape unexpected")
        }

        return try parseClusterJSON(content)
    }

    private func parseClusterJSON(_ raw: String) throws -> [LogbookTopicCluster] {
        // Strip markdown fences and any prose before/after the array.
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            // remove first fence line
            if let firstNewline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
            }
            // remove trailing fence
            if let lastFence = trimmed.range(of: "```", options: .backwards) {
                trimmed = String(trimmed[..<lastFence.lowerBound])
            }
        }
        // Slice from first '[' to last ']' to be tolerant of stray prose.
        if let lb = trimmed.firstIndex(of: "["),
           let rb = trimmed.lastIndex(of: "]"),
           lb < rb {
            trimmed = String(trimmed[lb...rb])
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw LogbookTopicAnalyzerError.parseFailed("not utf-8")
        }
        // First try the strict object-array shape.
        if let clusters = try? JSONDecoder().decode([LogbookTopicCluster].self, from: data) {
            return clusters
        }
        // Fallback: model returned a flat string array (Gemma does this often).
        if let titles = try? JSONDecoder().decode([String].self, from: data) {
            return titles.map { LogbookTopicCluster(title: $0, description: "") }
        }
        // Fallback: model returned an object array with different keys (e.g. {"topic":"..."}).
        if let dicts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return dicts.compactMap { dict in
                let title = (dict["title"] ?? dict["topic"] ?? dict["name"] ?? dict["theme"]) as? String
                let desc = (dict["description"] ?? dict["summary"] ?? dict["detail"]) as? String ?? ""
                guard let t = title, !t.isEmpty else { return nil }
                return LogbookTopicCluster(title: t, description: desc)
            }
        }
        throw LogbookTopicAnalyzerError.parseFailed("unrecognized JSON shape: \(trimmed.prefix(120))")
    }

    // MARK: - Cache (UserDefaults)

    private func readCache() -> LogbookTopicResult? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(LogbookTopicResult.self, from: data)
    }

    private func writeCache(_ result: LogbookTopicResult) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}
