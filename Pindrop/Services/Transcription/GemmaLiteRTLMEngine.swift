//
//  GemmaLiteRTLMEngine.swift
//  Pindrop
//
//  Created on 2026-06-07.
//
//  In-process Gemma 4 12B transcription engine via Google's LiteRT-LM Swift package.
//  Encoder-free audio path: raw 16 kHz mono PCM Float32 → cleaned text in a single
//  Gemma forward pass. Same architecture as Google AI Edge Eloquent.
//
//  Tracks: Forgejo issue #8.
//
//  Spike scope: implements only the batch `TranscriptionEngine` protocol. Output still
//  streams from Gemma during decode (via Conversation.sendMessageStream), so users see
//  text appearing progressively after stop — same UX shape as Eloquent's post-stop
//  cleanup phase. Streaming-during-speech (StreamingTranscriptionEngine conformance)
//  is a follow-up, mirroring Parakeet's split into Parakeet/ParakeetStreamingEngine.
//

import AVFoundation
import Foundation
import LiteRTLM

@MainActor
public final class GemmaLiteRTLMEngine: TranscriptionEngine, CapabilityReporting {

    public static var capabilities: AudioEngineCapabilities {
        [.transcription, .languageDetection]
    }

    public enum EngineError: Error, LocalizedError {
        case modelNotFound(String)
        case modelNotLoaded
        case engineInitFailed(String)
        case wavWriteFailed(String)
        case inferenceFailed(String)

        public var errorDescription: String? {
            switch self {
            case .modelNotFound(let path): return "Gemma model not found at: \(path)"
            case .modelNotLoaded: return "Gemma model is not loaded"
            case .engineInitFailed(let msg): return "Gemma engine init failed: \(msg)"
            case .wavWriteFailed(let msg): return "WAV serialization failed: \(msg)"
            case .inferenceFailed(let msg): return "Gemma inference failed: \(msg)"
            }
        }
    }

    public private(set) var state: TranscriptionEngineState = .unloaded
    public private(set) var error: Error?

    private var engine: Engine?
    private var modelPath: String?

    /// Shared accessor so the in-process AI Enhancement path can talk to the SAME
    /// loaded engine — no second model load, no LM Studio HTTP hop. Set when this
    /// instance finishes loading; cleared on unload.
    public static private(set) var sharedEngine: Engine?

    /// NautPin's pipeline produces 16 kHz mono Float32 PCM (see TranscriptionEngine
    /// protocol header).
    private let sampleRate: Double = 16_000

    public init() {}

    // MARK: - TranscriptionEngine

    public func loadModel(path: String) async throws {
        guard state != .loading else { return }
        state = .loading
        error = nil

        let resolvedPath: String
        do {
            resolvedPath = try resolveLitertlmPath(from: path)
        } catch {
            self.error = error
            state = .error
            throw error
        }

        let wallStart = CFAbsoluteTimeGetCurrent()
        Log.boot.info("GemmaLiteRTLMEngine.loadModel(path) begin path=\(resolvedPath)")

        // ML Drift compiles weights to a sibling cache on first load; persist them
        // alongside the model so subsequent launches reuse the compiled cache.
        let cacheDir = (resolvedPath as NSString).deletingLastPathComponent

        do {
            // Gemma 4 audio-multimodal models require:
            //   - Main backend GPU (ML Drift on Apple Silicon — fast LLM decode)
            //   - Audio backend CPU (XNNPACK — the audio adapter weights are quantized
            //     for CPU inference, mismatch with GPU throws "Audio backend constraint
            //     mismatch" at engine create time)
            let config = try EngineConfig(
                modelPath: resolvedPath,
                backend: .gpu,
                audioBackend: .cpu(),
                cacheDir: cacheDir
            )
            let engine = Engine(engineConfig: config)
            try await engine.initialize()
            self.engine = engine
            self.modelPath = resolvedPath
            Self.sharedEngine = engine
            state = .ready
            Log.boot.info("GemmaLiteRTLMEngine loaded in \(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - wallStart))")
        } catch {
            Log.boot.error("GemmaLiteRTLMEngine.loadModel failed after \(String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - wallStart)): \(error.localizedDescription)")
            self.error = error
            state = .error
            throw EngineError.engineInitFailed(error.localizedDescription)
        }
    }

    public func loadModel(name: String, downloadBase: URL?) async throws {
        // ModelManager hands us a registry name. We resolve to NautPin's standard cache
        // location: ~/Library/Application Support/NautPin/AIModels/<name>/
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
        let candidate = appSupport
            .appendingPathComponent(AppPaths.applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent("AIModels", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try await loadModel(path: candidate.path)
    }

    public func transcribe(audioData: Data, options: TranscriptionOptions) async throws -> String {
        guard let engine = self.engine else { throw EngineError.modelNotLoaded }
        state = .transcribing
        defer { state = self.engine == nil ? .unloaded : .ready }

        let samples = audioData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let wavURL = try writeFloat32WAV(samples: samples, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let conversation = try await engine.createConversation()
        let prompt = Self.transcriptionPrompt(for: options.language)
        let message = Message(
            contents: [.text(prompt), .audioFile(wavURL.path)],
            role: .user
        )

        var output = ""
        let stream = conversation.sendMessageStream(message)
        do {
            for try await chunk in stream {
                output += chunk.toString
            }
        } catch {
            throw EngineError.inferenceFailed(error.localizedDescription)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func unloadModel() async {
        engine = nil
        modelPath = nil
        Self.sharedEngine = nil
        state = .unloaded
    }

    // MARK: - Helpers

    private func resolveLitertlmPath(from path: String) throws -> String {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw EngineError.modelNotFound(path)
        }
        if !isDir.boolValue { return path }
        let url = URL(fileURLWithPath: path)
        let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
        guard let match = contents.first(where: { $0.hasSuffix(".litertlm") }) else {
            throw EngineError.modelNotFound("no .litertlm in \(path)")
        }
        return url.appendingPathComponent(match).path
    }

    private static func transcriptionPrompt(for language: AppLanguage) -> String {
        // Instruction-tuned prompt that exploits Gemma 4 12B's audio modality:
        // transcribe AND clean in one pass — the whole point of going encoder-free.
        let lang: String
        switch language {
        case .automatic:
            lang = "the language being spoken"
        default:
            lang = language.displayName(locale: Locale(identifier: "en"))
        }
        return """
        Transcribe the attached audio into clean, well-punctuated written text in \(lang). \
        Remove filler words and false starts. Preserve the speaker's meaning and tone. \
        Output only the transcribed text — no preamble, no commentary.
        """
    }

    private func writeFloat32WAV(samples: [Float], sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nautpin-gemma-\(UUID().uuidString).wav")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw EngineError.wavWriteFailed("could not build AVAudioFormat")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
                throw EngineError.wavWriteFailed("could not allocate AVAudioPCMBuffer")
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            if let channelData = buffer.floatChannelData {
                samples.withUnsafeBufferPointer { src in
                    channelData[0].update(from: src.baseAddress!, count: samples.count)
                }
            }
            try file.write(from: buffer)
            return url
        } catch let engineError as EngineError {
            throw engineError
        } catch {
            throw EngineError.wavWriteFailed(error.localizedDescription)
        }
    }
}
