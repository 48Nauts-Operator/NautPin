//
//  VoiceOutputService.swift
//  Pindrop
//
//  Created on 2026-05-17.
//
//  Two voice-output engines, side by side:
//
//    • Kokoro (English + many other languages) — streams PCM from a remote
//      Kokoro-FastAPI server over HTTP. NO in-process KokoroSwift / MLX —
//      that path crashes on macOS 26 / Swift 6 SDK with a runtime ABI bug
//      in MainActor.assumeIsolated when invoked from a SwiftUI Button
//      gesture. The HTTP architecture is what the user's working iOS app
//      (Bucki, /Users/cand0rian/DevHub_Studio/factory/03-iOS/Bucki) uses
//      and it sidesteps the crash entirely.
//    • AVSpeechSynthesizer — Apple's on-device system voices. Used for
//      German (Anna, Markus, etc.) since the Kokoro voice pack is
//      English-focused. Also the offline fallback when the server is
//      unreachable.
//
//  Implementation borrows heavily from Bucki/Bucki/Services/TTSService.swift.
//

import Foundation
import AVFoundation
import Combine
import ApplicationServices

// NOTE: Using legacy ObservableObject + @Published instead of @Observable.
// The new @Observable macro's AttributeGraph integration triggers a runtime
// crash on macOS 26 / Swift 6 SDK when SwiftUI button gestures access
// observable state — keep this until Apple ships a fix.
@MainActor
final class VoiceOutputService: ObservableObject {

    enum State: Equatable {
        case idle
        case speaking
        case loadingKokoro
    }

    /// Bridges AVSpeechSynthesizer's NSObject-based delegate API into our
    /// service without making the service itself inherit NSObject.
    private final class SynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate {
        weak var owner: VoiceOutputService?

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            Task { @MainActor [weak owner] in
                owner?.state = .idle
                owner?.currentText = nil
            }
        }

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            Task { @MainActor [weak owner] in
                owner?.state = .idle
                owner?.currentText = nil
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentText: String?

    /// Voices returned by the Kokoro server's `/v1/audio/voices` endpoint,
    /// sorted alphabetically. Empty until `loadKokoroVoicesIfNeeded()`
    /// succeeds.
    @Published private(set) var kokoroVoiceNames: [String] = []

    /// Kokoro-FastAPI server base URL. Defaults to the Tailscale IP that
    /// the user's Bucki app already points at. Configurable via Settings.
    @Published var kokoroServerURL: String = "http://100.69.95.60:8880"

    @Published private(set) var kokoroServerError: String?

    /// Supplies the user's default voice preferences. Wired by AppCoordinator
    /// from SettingsStore after both objects exist, same pattern as
    /// `activePowerModeProvider`. Default returns fixed fallbacks so the
    /// service still works in previews / tests where SettingsStore isn't
    /// injected.
    var defaultVoicesProvider: () -> (kokoro: String, appleDE: String) = { ("bf_emma", "") }

    private let synthesizer = AVSpeechSynthesizer()
    private let synthesizerDelegate = SynthesizerDelegate()

    // Kokoro PCM playback pipeline. 24 kHz mono, signed 16-bit LE — what
    // the Kokoro-FastAPI server returns with `response_format: "pcm"`.
    private static let kokoroSampleRate: Double = 24000
    private let audioEngine = AVAudioEngine()
    private let kokoroPlayerNode = AVAudioPlayerNode()
    private var audioEngineConfigured = false
    private var playerNodePlaying = false
    private var kokoroPlayerFormat: AVAudioFormat?
    private var currentStreamSession: KokoroStreamSession?

    init() {
        synthesizerDelegate.owner = self
        synthesizer.delegate = synthesizerDelegate
    }

    // MARK: - Kokoro voice catalog

    /// Fetches the voice list from `<kokoroServerURL>/v1/audio/voices`.
    /// Idempotent: skips if already loaded. ~50ms on Tailnet.
    func loadKokoroVoicesIfNeeded() {
        guard kokoroVoiceNames.isEmpty, state != .loadingKokoro else { return }

        guard let url = URL(string: "\(kokoroServerURL)/v1/audio/voices") else {
            kokoroServerError = "Invalid server URL"
            return
        }

        state = .loadingKokoro
        kokoroServerError = nil
        Log.app.info("Fetching Kokoro voices from \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state = .idle
                if let error {
                    self.kokoroServerError = "Server unreachable: \(error.localizedDescription)"
                    Log.app.error("Kokoro voices fetch failed: \(error.localizedDescription)")
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let voices = json["voices"] as? [String] else {
                    self.kokoroServerError = "Unexpected /v1/audio/voices response"
                    Log.app.error("Kokoro voices: unexpected response body")
                    return
                }
                self.kokoroVoiceNames = voices.sorted()
                Log.app.info("Loaded \(voices.count) Kokoro voices")
            }
        }.resume()
    }

    // MARK: - Speak via Kokoro server

    /// Streams Kokoro TTS for `text` using `voiceName` and plays it
    /// chunk-by-chunk. First audible sample lands ~300-600ms after the
    /// call (Tailnet latency + server time-to-first-byte + audio engine
    /// scheduling).
    func speakKokoro(_ text: String, voiceName: String, speed: Float = 1.0) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Cancel any in-flight playback (Kokoro or Apple).
        stop()

        do {
            try prepareKokoroPlaybackEngine()
        } catch {
            Log.app.error("Kokoro playback engine prepare failed: \(error.localizedDescription)")
            return
        }

        guard let url = URL(string: "\(kokoroServerURL)/v1/audio/speech") else {
            kokoroServerError = "Invalid server URL"
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "input": trimmed,
            "voice": voiceName,
            "model": "kokoro",
            "response_format": "pcm",
            "speed": speed,
            "stream": true,
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            Log.app.error("Kokoro speech JSON encode failed: \(error.localizedDescription)")
            return
        }

        currentText = trimmed
        state = .speaking
        kokoroServerError = nil
        Log.app.info("VoiceOutput.kokoro speak voice=\(voiceName) chars=\(trimmed.count)")

        let session = KokoroStreamSession(
            request: request,
            onResponse: { status in
                Log.app.info("Kokoro stream HTTP \(status)")
            },
            onChunk: { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.handleKokoroChunk(data)
                }
            },
            onComplete: { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.handleKokoroStreamComplete(error: error)
                }
            }
        )
        currentStreamSession = session
        session.start()
    }

    /// Speak a short sample for the Settings preview button.
    func speakKokoroSample(voiceName: String) {
        let region = voiceName.first
        let sample: String
        switch region {
        case "b": sample = "Hello, I'm NautPin. I'll happily read your transcripts aloud."
        case "e": sample = "Hola, soy NautPin y transcribo para ti."
        case "f": sample = "Bonjour, je suis NautPin et je transcris pour vous."
        case "h": sample = "नमस्ते, मैं NautPin हूँ।"
        case "i": sample = "Ciao, sono NautPin e trascrivo per te."
        case "j": sample = "こんにちは、私はNautPinです。"
        case "p": sample = "Olá, eu sou NautPin e transcrevo para você."
        case "z": sample = "你好，我是NautPin。"
        default:  sample = "Hi, I'm NautPin, and I'll read your transcripts aloud whenever you want."
        }
        speakKokoro(sample, voiceName: voiceName)
    }

    private func handleKokoroChunk(_ data: Data) {
        currentStreamSession?.appendAndSchedule(data) { [weak self] aligned in
            self?.schedulePCM(aligned)
        }
    }

    private func handleKokoroStreamComplete(error: Error?) {
        currentStreamSession?.flush { [weak self] tail in
            self?.schedulePCM(tail)
        }
        if let error {
            Log.app.error("Kokoro stream error: \(error.localizedDescription)")
            kokoroServerError = error.localizedDescription
            state = .idle
            currentText = nil
            return
        }
        Log.app.info("Kokoro stream complete")
        scheduleEndMarker { [weak self] in
            Task { @MainActor [weak self] in
                self?.state = .idle
                self?.currentText = nil
            }
        }
    }

    // MARK: - AVAudioEngine playback (Bucki pattern)

    private func prepareKokoroPlaybackEngine() throws {
        if kokoroPlayerFormat == nil {
            kokoroPlayerFormat = AVAudioFormat(
                standardFormatWithSampleRate: Self.kokoroSampleRate,
                channels: 1
            )
        }
        guard let format = kokoroPlayerFormat else { throw VoiceOutputError.playbackFailed }

        if !audioEngineConfigured {
            audioEngine.attach(kokoroPlayerNode)
            audioEngine.connect(kokoroPlayerNode, to: audioEngine.mainMixerNode, format: format)
            audioEngineConfigured = true
            Log.app.info("AudioEngine configured @ \(Self.kokoroSampleRate) Hz")
        }

        if !audioEngine.isRunning {
            try audioEngine.start()
            Log.app.info("AudioEngine started")
        }
    }

    private func schedulePCM(_ int16Bytes: Data) {
        guard let format = kokoroPlayerFormat else { return }
        let frameCount = AVAudioFrameCount(int16Bytes.count / 2)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            Log.app.error("schedulePCM: buffer alloc failed for \(int16Bytes.count) B")
            return
        }
        pcmBuffer.frameLength = frameCount

        int16Bytes.withUnsafeBytes { raw in
            guard let dst = pcmBuffer.floatChannelData?[0] else { return }
            let src = raw.bindMemory(to: Int16.self)
            let scale = 1.0 / Float(Int16.max)
            for i in 0..<Int(frameCount) {
                dst[i] = Float(Int16(littleEndian: src[i])) * scale
            }
        }

        kokoroPlayerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)

        if !playerNodePlaying {
            kokoroPlayerNode.play()
            playerNodePlaying = true
        }
    }

    private func scheduleEndMarker(_ onFinished: @escaping () -> Void) {
        guard let format = kokoroPlayerFormat,
              let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
            onFinished(); return
        }
        marker.frameLength = 1
        if let ch = marker.floatChannelData?[0] { ch[0] = 0 }
        kokoroPlayerNode.scheduleBuffer(marker, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playerNodePlaying = false
                onFinished()
            }
        }
    }

    // MARK: - Apple AVSpeechSynthesizer (used for German + fallback)

    var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted { lhs, rhs in
            if lhs.language != rhs.language {
                return lhs.language < rhs.language
            }
            if lhs.quality.rawValue != rhs.quality.rawValue {
                return lhs.quality.rawValue > rhs.quality.rawValue
            }
            return lhs.name < rhs.name
        }
    }

    func voices(forLanguagePrefix prefix: String) -> [AVSpeechSynthesisVoice] {
        availableVoices.filter { $0.language.hasPrefix(prefix) }
    }

    func defaultVoice(forLanguagePrefix prefix: String) -> AVSpeechSynthesisVoice? {
        voices(forLanguagePrefix: prefix).first
    }

    func speak(_ text: String, voice: AVSpeechSynthesisVoice? = nil, rate: Float? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()

        let utterance = AVSpeechUtterance(string: trimmed)
        if let voice {
            utterance.voice = voice
        }
        if let rate {
            utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate,
                                 min(AVSpeechUtteranceMaximumSpeechRate, rate))
        }
        currentText = trimmed
        state = .speaking
        Log.app.info("VoiceOutput.apple speak voice=\(utterance.voice?.identifier ?? "default") chars=\(trimmed.count)")
        synthesizer.speak(utterance)
    }

    func speakSample(_ voice: AVSpeechSynthesisVoice) {
        let prefix = String(voice.language.prefix(2)).lowercased()
        let sample: String
        switch prefix {
        case "de": sample = "Hallo, ich bin NautPin und transkribiere für dich."
        case "fr": sample = "Bonjour, je suis NautPin et je transcris pour vous."
        case "es": sample = "Hola, soy NautPin y transcribo para ti."
        case "it": sample = "Ciao, sono NautPin e trascrivo per te."
        case "nl": sample = "Hallo, ik ben NautPin en transcribeer voor je."
        default:   sample = "Hello, I'm NautPin and I transcribe for you."
        }
        speak(sample, voice: voice)
    }

    // MARK: - Read aloud (auto-route by detected language)

    /// Speaks arbitrary text using the user's configured default voices.
    /// German text routes through Apple AVSpeechSynthesizer (Anna et al.);
    /// everything else routes through Kokoro on the remote server.
    /// Used by the global "read selected text" hotkey and any other
    /// surface that needs read-aloud without explicit voice selection.
    func readAloud(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let (kokoroVoice, appleDEVoiceID) = defaultVoicesProvider()
        let lang = Self.detectLanguagePrefix(in: trimmed)

        Log.app.info("readAloud lang=\(lang) chars=\(trimmed.count)")

        if lang == "de" {
            let voice: AVSpeechSynthesisVoice? = appleDEVoiceID.isEmpty
                ? defaultVoice(forLanguagePrefix: "de")
                : (AVSpeechSynthesisVoice(identifier: appleDEVoiceID) ?? defaultVoice(forLanguagePrefix: "de"))
            speak(trimmed, voice: voice)
        } else {
            speakKokoro(trimmed, voiceName: kokoroVoice)
        }
    }

    /// Crude language sniff. EN/DE are the only two routed differently
    /// today (Kokoro server has no DE voices). Defaults to English on
    /// ambiguous text.
    nonisolated static func detectLanguagePrefix(in text: String) -> String {
        let lower = text.lowercased()
        let germanCues = [" der ", " die ", " das ", " und ", " ist ", " nicht ",
                          " ich ", " mit ", " für ", "ä", "ö", "ü", "ß", " sind ", " wir ",
                          " hat ", " haben ", " war ", " kann ", " auch "]
        let hits = germanCues.reduce(0) { acc, cue in acc + (lower.contains(cue) ? 1 : 0) }
        return hits >= 2 ? "de" : "en"
    }

    // MARK: - Selected-text reader (Accessibility API)

    /// Fetches the currently-selected text from the focused UI element of
    /// the frontmost app. Returns nil if nothing is selected, if the
    /// element doesn't support `kAXSelectedTextAttribute`, or if the app
    /// lacks Accessibility permission. The user granted Accessibility for
    /// dictation insert; the same grant covers this read.
    nonisolated static func selectedTextFromFrontmostApp() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusedResult == .success, let focused = focusedRef else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)

        var selectedRef: CFTypeRef?
        let selectedResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedRef
        )
        guard selectedResult == .success,
              let str = selectedRef as? String,
              !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return str
    }

    /// One-shot: grab selected text from the frontmost app and read it
    /// aloud. Called by the global hotkey handler.
    func readSelectedTextAloud() {
        guard let selected = Self.selectedTextFromFrontmostApp() else {
            Log.app.info("readSelectedTextAloud: no selected text in frontmost app")
            return
        }
        readAloud(selected)
    }

    // MARK: - Stop (both engines)

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        currentStreamSession?.cancel()
        currentStreamSession = nil
        if playerNodePlaying {
            kokoroPlayerNode.stop()
            playerNodePlaying = false
        }
        state = .idle
        currentText = nil
    }
}

// MARK: - Error type

enum VoiceOutputError: LocalizedError {
    case playbackFailed
    case serverUnreachable(String)

    var errorDescription: String? {
        switch self {
        case .playbackFailed: return "Audio playback failed"
        case .serverUnreachable(let detail): return "Kokoro server unreachable: \(detail)"
        }
    }
}

// MARK: - Streaming session (ported from Bucki)

private final class KokoroStreamSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let onResponse: @Sendable (Int) -> Void
    private let onChunk: @Sendable (Data) -> Void
    private let onComplete: @Sendable (Error?) -> Void

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var leftover = Data()

    init(request: URLRequest,
         onResponse: @escaping @Sendable (Int) -> Void,
         onChunk: @escaping @Sendable (Data) -> Void,
         onComplete: @escaping @Sendable (Error?) -> Void) {
        self.request = request
        self.onResponse = onResponse
        self.onChunk = onChunk
        self.onComplete = onComplete
        super.init()
    }

    func start() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        session?.invalidateAndCancel()
    }

    /// Buffer and schedule even-byte-aligned PCM chunks. Odd trailing
    /// bytes (rare but possible at chunk boundaries) carry over to the
    /// next call to avoid mis-aligned Int16 decoding.
    func appendAndSchedule(_ data: Data, schedule: (Data) -> Void) {
        if cancelled { return }
        var combined = leftover
        combined.append(data)
        let usable = combined.count - (combined.count % 2)
        if usable > 0 {
            schedule(combined.prefix(usable))
        }
        leftover = combined.suffix(combined.count - usable)
    }

    func flush(schedule: (Data) -> Void) {
        let aligned = leftover.count - (leftover.count % 2)
        if aligned > 0 {
            schedule(leftover.prefix(aligned))
        }
        leftover.removeAll()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        onResponse(status)
        if !(200...299).contains(status) {
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        if cancelled { return }
        onChunk(data)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if cancelled { return }
        onComplete(error)
    }
}
