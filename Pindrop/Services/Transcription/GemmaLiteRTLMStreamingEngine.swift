//
//  GemmaLiteRTLMStreamingEngine.swift
//  Pindrop
//
//  Created on 2026-06-08.
//
//  Chunked re-transcription during audio capture, using the same in-process Gemma 4
//  E4B engine that the batch transcription path uses (GemmaLiteRTLMEngine.sharedEngine).
//
//  Why: the batch path runs STT on the full audio buffer AFTER the user presses stop,
//  so total post-stop latency scales linearly with audio length (8-15s for a 60-90s
//  utterance). With chunked re-transcription, we run STT on the accumulating buffer
//  every retransInterval seconds DURING speech, so by the time the user stops most
//  of the work is already done. Same architecture Google AI Edge Eloquent uses.
//
//  Implementation shape: mirrors ParakeetStreamingEngine. Conforms to
//  StreamingTranscriptionEngine. Single-flight on transcription passes — if one's
//  in flight when the timer fires, skip; always work on the freshest buffer.
//
//  Tracks: Forgejo issue #8 (Path B), task #32.
//

import AVFoundation
import Foundation
import LiteRTLM

@MainActor
public final class GemmaLiteRTLMStreamingEngine: StreamingTranscriptionEngine {

    public enum EngineError: Error, LocalizedError {
        case modelNotLoaded
        case invalidState(String)
        case wavWriteFailed(String)
        case inferenceFailed(String)

        public var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "Gemma streaming: shared audio engine not loaded — select Gemma in Settings → Models first"
            case .invalidState(let msg):
                return msg
            case .wavWriteFailed(let msg):
                return "WAV write failed: \(msg)"
            case .inferenceFailed(let msg):
                return "Gemma streaming inference failed: \(msg)"
            }
        }
    }

    public private(set) var state: StreamingTranscriptionState = .unloaded

    private var audioBuffer: [Float] = []
    private var transcriptionCallback: StreamingTranscriptionCallback?
    private var endOfUtteranceCallback: EndOfUtteranceCallback?
    private var retransTimer: Timer?
    private var isTranscribing = false
    private var lastTranscription = ""

    /// Interval between chunked re-transcription passes during active streaming.
    /// 1.5s is the sweet spot: fast enough to feel live (visible text appears
    /// within ~2s of speaking), slow enough that we're not constantly re-running
    /// the model on tiny audio differences. Single-flight skip handles the case
    /// where one pass takes longer than the interval.
    private static let retransInterval: TimeInterval = 1.5

    /// Minimum sample count (Float32 at 16 kHz) before kicking off the first
    /// transcription pass. 0.8 s — below this the model gets noisy input
    /// without enough context to produce useful output.
    private static let minAudioSamples = 12_800

    /// Sample rate the streaming protocol contract uses (see
    /// `TranscriptionEngine.swift` — "expected format: 16kHz mono PCM Float32").
    private let sampleRate: Double = 16_000

    public init() {}

    // MARK: - StreamingTranscriptionEngine

    public func loadModel(name: String) async throws {
        // We piggyback on the shared E4B audio engine — no separate model load
        // needed. The batch transcription path loads it via GemmaLiteRTLMEngine;
        // we just verify it's available. (AppCoordinator.setupGemmaTextCompanion
        // also loads the 12B; we don't use that one for streaming STT — only the
        // E4B has the audio modality.)
        guard GemmaLiteRTLMEngine.sharedEngine != nil else {
            throw EngineError.modelNotLoaded
        }
        state = .ready
    }

    public func unloadModel() async {
        retransTimer?.invalidate()
        retransTimer = nil
        audioBuffer.removeAll(keepingCapacity: false)
        lastTranscription = ""
        state = .unloaded
    }

    public func startStreaming() async throws {
        guard GemmaLiteRTLMEngine.sharedEngine != nil else {
            throw EngineError.modelNotLoaded
        }
        guard state == .ready || state == .paused else {
            throw EngineError.invalidState("startStreaming called in state \(state)")
        }
        audioBuffer.removeAll(keepingCapacity: true)
        lastTranscription = ""
        state = .streaming
        startRetransTimer()
    }

    public func stopStreaming() async throws -> String {
        guard state == .streaming || state == .paused else {
            throw EngineError.invalidState("stopStreaming called in state \(state)")
        }
        retransTimer?.invalidate()
        retransTimer = nil

        // Wait briefly for any in-flight transcription to finish so we can use
        // its result. Bounded so we don't hang forever on a stuck inference.
        var waited: TimeInterval = 0
        while isTranscribing && waited < 30 {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
            waited += 0.05
        }

        // Run one final pass on the complete buffer. This catches the tail —
        // any audio that arrived after the last in-flight pass started. On
        // failure, fall back to the latest partial we successfully captured.
        let finalText: String
        if let fresh = try? await runTranscription() {
            finalText = fresh
        } else {
            Log.transcription.warning("Gemma streaming: final pass failed, using last partial")
            finalText = lastTranscription
        }

        state = .ready
        endOfUtteranceCallback?(finalText)
        return finalText
    }

    public func pauseStreaming() async {
        guard state == .streaming else { return }
        retransTimer?.invalidate()
        retransTimer = nil
        state = .paused
    }

    public func resumeStreaming() async throws {
        guard state == .paused else {
            throw EngineError.invalidState("resumeStreaming called in state \(state)")
        }
        state = .streaming
        startRetransTimer()
    }

    public func processAudioChunk(_ samples: [Float]) async throws {
        guard state == .streaming else { return }
        audioBuffer.append(contentsOf: samples)
    }

    public func processAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        guard state == .streaming, let channelData = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
        audioBuffer.append(contentsOf: samples)
    }

    public func setTranscriptionCallback(_ callback: @escaping StreamingTranscriptionCallback) {
        self.transcriptionCallback = callback
    }

    public func setEndOfUtteranceCallback(_ callback: @escaping EndOfUtteranceCallback) {
        self.endOfUtteranceCallback = callback
    }

    public func reset() async {
        retransTimer?.invalidate()
        retransTimer = nil
        audioBuffer.removeAll(keepingCapacity: false)
        lastTranscription = ""
        state = state == .unloaded ? .unloaded : .ready
    }

    // MARK: - Internals

    private func startRetransTimer() {
        retransTimer?.invalidate()
        retransTimer = Timer.scheduledTimer(withTimeInterval: Self.retransInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.state == .streaming else { return }
                // Single-flight: skip this tick if a pass is already running.
                // The timer fires again in retransInterval seconds; by then
                // we'll have an even fresher buffer to work with.
                guard !self.isTranscribing else { return }
                guard self.audioBuffer.count >= Self.minAudioSamples else { return }

                do {
                    let text = try await self.runTranscription()
                    if text != self.lastTranscription && !text.isEmpty {
                        self.lastTranscription = text
                        let result = StreamingTranscriptionResult(
                            text: text,
                            isFinal: false,
                            confidence: nil,
                            timestamp: Date().timeIntervalSince1970
                        )
                        self.transcriptionCallback?(result)
                    }
                } catch {
                    Log.transcription.warning("Gemma chunked re-transcription failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func runTranscription() async throws -> String {
        guard let engine = GemmaLiteRTLMEngine.sharedEngine else {
            throw EngineError.modelNotLoaded
        }
        isTranscribing = true
        defer { isTranscribing = false }

        // Snapshot the buffer so we don't trip on new chunks arriving while
        // inference is in flight. The audio that arrives after this point
        // gets picked up by the next pass (or the final pass on stop).
        let samples = audioBuffer

        let wavURL = try writeFloat32WAV(samples: samples, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let conversation = try await engine.createConversation()
        let prompt = "Transcribe the attached audio into text. Output only the transcription, nothing else."
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

    private func writeFloat32WAV(samples: [Float], sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nautpin-gemma-stream-\(UUID().uuidString).wav")

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
