//
//  GemmaLiteRTLMEnhancer.swift
//  Pindrop
//
//  Created on 2026-06-07.
//
//  In-process AI Enhancement via LiteRT-LM. Talks to the SAME Gemma engine that
//  `GemmaLiteRTLMEngine` already loaded for transcription — no second model load,
//  no LM Studio HTTP hop, no external dependency.
//
//  Same routing pattern as `AppleFoundationModelsEnhancer`. Different model, same
//  shape.
//
//  Tracks: Forgejo issue #8 — cleanup-in-process side.
//

import Foundation
import LiteRTLM

@MainActor
final class GemmaLiteRTLMEnhancer {

    enum EnhancerError: Error, LocalizedError {
        case engineNotLoaded
        case inferenceFailed(String)

        var errorDescription: String? {
            switch self {
            case .engineNotLoaded:
                return "Gemma engine not loaded. Select Gemma in Settings → Models first."
            case .inferenceFailed(let msg):
                return "Gemma cleanup failed: \(msg)"
            }
        }
    }

    /// Optional callback invoked as cleanup tokens stream in. Lets the caller wire
    /// the "watch it write" UX — same hook the streaming refinement coordinator uses
    /// for live transcription updates.
    var onPartial: ((String) -> Void)?

    /// Edit-list cleanup. Returns a list of find/replace operations rather than a
    /// full rewrite. Massively faster on long transcripts because the model only
    /// emits ~20-50 tokens of edit JSON instead of re-emitting the entire cleaned
    /// transcript (which scales linearly with input length and dominated post-stop
    /// latency for >300-char dictations).
    ///
    /// Same architectural pattern as `AppleFoundationModelsEnhancer.refineAsEdits`,
    /// minus the `@Generable` struct path — Gemma doesn't have constrained-output
    /// support yet, so we instruct via prompt + parse JSON. Parse failures throw;
    /// caller falls back to `enhance(...)` (full rewrite) if that happens.
    func refineAsEdits(transcript: String, systemPrompt: String) async throws -> [TranscriptEdit] {
        guard !transcript.isEmpty else { return [] }
        guard let engine = GemmaLiteRTLMEngine.sharedEngine else {
            throw EnhancerError.engineNotLoaded
        }

        let editPrompt = """
        You are a transcript cleanup assistant. Output a JSON array of find/replace edits to apply to the transcript.

        Each edit has the shape: {"find": "<exact substring to locate>", "replace": "<new text, or empty string to delete>"}

        Rules — follow strictly:
        1. "find" must be an EXACT substring of the transcript: case-sensitive, including spaces and punctuation. Verbatim copy.
        2. Include enough context in "find" so the substring is UNIQUE in the transcript. Ambiguous matches are dropped.
        3. Focus on: removing filler words (um, uh, like, you know), removing false starts and repetitions, fixing obvious grammar slips. Do NOT rewrite for style.
        4. Do NOT introduce information that isn't in the transcript.
        5. Output ONLY the JSON array, no commentary, no code fences, no preamble.
        6. If the transcript is already clean, output an empty array: []

        Transcript to clean:
        \(transcript)
        """

        let conversation = try await engine.createConversation()
        let message = Message(editPrompt, role: .user)

        var raw = ""
        do {
            let stream = conversation.sendMessageStream(message)
            for try await chunk in stream {
                let piece = chunk.toString
                if !piece.isEmpty {
                    raw += piece
                    onPartial?(raw)
                }
            }
        } catch {
            throw EnhancerError.inferenceFailed("edit-stream: \(error.localizedDescription)")
        }

        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            throw EnhancerError.inferenceFailed("Edit JSON not UTF-8 decodable")
        }

        let parsed: [[String: Any]]
        do {
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw EnhancerError.inferenceFailed("Edit JSON not an array of objects. Got: \(cleaned.prefix(200))")
            }
            parsed = arr
        } catch let enhancerError as EnhancerError {
            throw enhancerError
        } catch {
            throw EnhancerError.inferenceFailed("Edit JSON parse failed: \(error.localizedDescription). Output: \(cleaned.prefix(200))")
        }

        return parsed.compactMap { dict in
            guard let find = dict["find"] as? String, !find.isEmpty else { return nil }
            let replace = (dict["replace"] as? String) ?? (dict["replacement"] as? String) ?? ""
            return TranscriptEdit(find: find, replacement: replace)
        }
    }

    func enhance(text: String, systemPrompt: String) async throws -> String {
        guard !text.isEmpty else { return text }
        guard let engine = GemmaLiteRTLMEngine.sharedEngine else {
            throw EnhancerError.engineNotLoaded
        }

        let normalizedInstructions = systemPrompt
            .replacingOccurrences(of: "${transcription}", with: "")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let conversation: Conversation
        do {
            // System message first, then user content. Same shape as
            // AppleFoundationModelsEnhancer (instructions on session) but expressed
            // via LiteRT-LM's Message API.
            let conversationConfig = try ConversationConfig(
                systemMessage: Message(normalizedInstructions, role: .system)
            )
            conversation = try await engine.createConversation(with: conversationConfig)
        } catch {
            throw EnhancerError.inferenceFailed("createConversation: \(error.localizedDescription)")
        }

        let userMessage = Message(text, role: .user)
        var output = ""

        do {
            let stream = conversation.sendMessageStream(userMessage)
            for try await chunk in stream {
                let piece = chunk.toString
                if !piece.isEmpty {
                    output += piece
                    onPartial?(output)
                }
            }
        } catch {
            throw EnhancerError.inferenceFailed(error.localizedDescription)
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
