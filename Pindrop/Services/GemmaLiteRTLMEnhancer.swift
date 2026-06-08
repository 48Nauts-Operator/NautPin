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
        // Prefer the dedicated 12B text model when loaded — better cleanup quality.
        // Fall back to the E4B audio model (also a competent text LLM) otherwise.
        guard let engine = GemmaLiteRTLMEngine.sharedTextEngine else {
            throw EnhancerError.engineNotLoaded
        }

        let editPrompt = """
        You are a CONSERVATIVE transcript cleanup assistant. Your job is to remove ONLY clear disfluencies. You MUST preserve the speaker's meaning, tone, sentence type (declarative/question/exclamation), and word choice exactly.

        Output a JSON array of find/replace edits. Each edit: {"find": "<exact substring>", "replace": "<replacement, or empty string to delete>"}

        STRICT RULES — violating any of these means the edit is wrong:
        1. "find" must be an EXACT substring of the transcript — case-sensitive, including spaces and punctuation. Copy verbatim.
        2. "find" must be UNIQUE in the transcript. Include surrounding context so it can only match once. Ambiguous edits are dropped.
        3. NEVER change a declarative sentence to a question or vice versa. NEVER add or remove a "?". NEVER negate or affirm a sentence the speaker did not. (Example: do NOT change "It works" to "It does not work", or "I think so" to "I don't think so".)
        4. NEVER introduce words, phrases, names, numbers, or topics that are not already present in the transcript.
        5. ONLY edit: filler words ("um", "uh", "ähm", "like", "you know" — when used as filler, not as meaningful words), false starts ("I was going to- I went"), unintentional repetitions ("the the cat" → "the cat"), and obvious typo-grade misspellings.
        6. Output AT MOST 20 edits total. If there are more disfluencies, pick the 20 most obvious. Long transcripts get fewer, more targeted edits — not more edits.
        7. If the transcript is already clean enough, output [] — an empty array. That's a valid answer.
        8. Output ONLY the JSON array. No commentary, no code fences, no preamble, no trailing notes.

        Transcript:
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
        // Same preference order as refineAsEdits: 12B if loaded, else E4B.
        guard let engine = GemmaLiteRTLMEngine.sharedTextEngine else {
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
