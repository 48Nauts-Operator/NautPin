//
//  VoiceOutputService.swift
//  Pindrop
//
//  Created on 2026-05-17.
//
//  Voice output (text-to-speech) with two engines side by side:
//
//    • KokoroSwift (mlalma/kokoro-ios) — neural TTS for English. 28 voices.
//      Model + voices bundled in app Resources/Kokoro/. ~3× realtime on Apple
//      Silicon after a one-time warm-up.
//    • AVSpeechSynthesizer — Apple's on-device system voices. Covers German
//      (Anna, Markus, etc.) and falls back here for any non-English voice
//      or before Kokoro is loaded.
//
//  Engine dispatch is by chosen voice, not by language sniffing — the UI lists
//  both Kokoro and Apple voices and the user picks. The sample helper still
//  uses the language sniff for "pick a sensible default."
//

import Foundation
import AVFoundation
import KokoroSwift
import MLX
import MLXUtilsLibrary

@MainActor
@Observable
final class VoiceOutputService: NSObject, AVSpeechSynthesizerDelegate {

    enum State: Equatable {
        case idle
        case speaking
        case loadingKokoro
    }

    /// Identifies a voice across both engines.
    enum Voice: Hashable {
        /// Kokoro voice (key into the voices.npz bundle — e.g. "af_sarah", "bm_george").
        case kokoro(String, KokoroSwift.Language)
        /// Apple system voice.
        case apple(AVSpeechSynthesisVoice)

        var displayName: String {
            switch self {
            case .kokoro(let id, _): return Self.kokoroDisplayName(for: id)
            case .apple(let v):      return v.name
            }
        }

        var languageCode: String {
            switch self {
            case .kokoro(_, let lang): return lang == .enGB ? "en-GB" : "en-US"
            case .apple(let v):        return v.language
            }
        }

        var engineLabel: String {
            switch self {
            case .kokoro: return "Kokoro"
            case .apple:  return "Apple"
            }
        }

        private static func kokoroDisplayName(for id: String) -> String {
            // af_sarah → "Sarah (en-US ♀)"; bm_george → "George (en-GB ♂)"; etc.
            guard id.count > 3 else { return id }
            let region = id.first == "a" ? "en-US" : (id.first == "b" ? "en-GB" : "en")
            let gender = id.dropFirst().first == "f" ? "♀" : (id.dropFirst().first == "m" ? "♂" : "")
            let name = id.split(separator: "_").last.map(String.init)?.capitalized ?? id
            return "\(name) (\(region) \(gender))".trimmingCharacters(in: .whitespaces)
        }
    }

    private(set) var state: State = .idle
    private(set) var currentText: String?

    private let synthesizer = AVSpeechSynthesizer()

    // Kokoro lazy state — model takes ~1-2s to load, only pay it on first English use.
    private var kokoroTTS: KokoroTTS?
    private var kokoroVoices: [String: MLXArray]?
    /// Names sorted alphabetically for stable UI ordering, populated after first load.
    private(set) var kokoroVoiceNames: [String] = []

    // Playback for Kokoro PCM output. AVAudioEngine + a player node lets us
    // schedule the [Float] buffer KokoroTTS returns without writing a temp file.
    private let audioEngine = AVAudioEngine()
    private let kokoroPlayerNode = AVAudioPlayerNode()
    private var audioEngineStarted = false

    override init() {
        super.init()
        synthesizer.delegate = self
        audioEngine.attach(kokoroPlayerNode)
        audioEngine.connect(kokoroPlayerNode, to: audioEngine.mainMixerNode, format: nil)
    }

    // MARK: - Voices

    /// All installed system voices, sorted by language then quality (premium first).
    var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted { lhs, rhs in
            if lhs.language != rhs.language {
                return lhs.language < rhs.language
            }
            if lhs.quality.rawValue != rhs.quality.rawValue {
                return lhs.quality.rawValue > rhs.quality.rawValue  // premium first
            }
            return lhs.name < rhs.name
        }
    }

    /// Voices matching a BCP-47 language prefix (e.g. "en", "de").
    func voices(forLanguagePrefix prefix: String) -> [AVSpeechSynthesisVoice] {
        availableVoices.filter { $0.language.hasPrefix(prefix) }
    }

    /// Best default voice for a given language, preferring premium / enhanced quality.
    func defaultVoice(forLanguagePrefix prefix: String) -> AVSpeechSynthesisVoice? {
        voices(forLanguagePrefix: prefix).first
    }

    // MARK: - Playback

    // MARK: - Kokoro

    /// 24kHz mono Float — Kokoro's output format.
    private static let kokoroSampleRate: Double = 24000

    /// Load Kokoro model + voices from the app bundle. Idempotent.
    /// Heavy: ~1-2s on Apple Silicon for first call. Subsequent calls are no-ops.
    @discardableResult
    func loadKokoroIfNeeded() -> Bool {
        guard kokoroTTS == nil else { return true }

        guard let modelURL = Bundle.main.url(forResource: "kokoro-v1_0", withExtension: "safetensors"),
              let voicesURL = Bundle.main.url(forResource: "voices", withExtension: "npz") else {
            Log.app.error("Kokoro assets missing from app bundle — run `just fetch-kokoro` then rebuild")
            return false
        }

        state = .loadingKokoro
        Log.app.info("Loading Kokoro model from \(modelURL.lastPathComponent) (this may take 1-2s)")
        let started = CFAbsoluteTimeGetCurrent()

        let tts = KokoroTTS(modelPath: modelURL, g2p: .misaki)
        guard let voices = NpyzReader.read(fileFromPath: voicesURL) else {
            Log.app.error("Failed to read voice styles from voices.npz")
            state = .idle
            return false
        }

        self.kokoroTTS = tts
        self.kokoroVoices = voices
        self.kokoroVoiceNames = voices.keys.sorted()
        state = .idle

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        Log.app.info("Kokoro loaded: \(voices.count) voices, \(String(format: "%.2fs", elapsed))")
        return true
    }

    /// Speak text using a Kokoro voice. Returns immediately; playback runs on the audio engine.
    func speakKokoro(_ text: String, voiceName: String, language: KokoroSwift.Language = .enUS) {
        guard loadKokoroIfNeeded(),
              let tts = kokoroTTS,
              let voiceStyle = kokoroVoices?[voiceName] else {
            Log.app.error("Kokoro speak failed: model not loaded or voice '\(voiceName)' not found")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Cancel any in-flight playback (Apple or Kokoro).
        stop()

        currentText = trimmed
        state = .speaking
        Log.app.info("VoiceOutput.kokoro speak voice=\(voiceName) chars=\(trimmed.count)")

        // Synthesis is CPU-bound; run off-main so the UI stays responsive.
        let synthesisStart = CFAbsoluteTimeGetCurrent()
        Task.detached(priority: .userInitiated) {
            do {
                let (samples, _) = try tts.generateAudio(voice: voiceStyle, language: language, text: trimmed)
                let elapsed = CFAbsoluteTimeGetCurrent() - synthesisStart
                let audioDuration = Double(samples.count) / Self.kokoroSampleRate
                Log.app.info("Kokoro synth: \(samples.count) samples, \(String(format: "%.2fs", audioDuration)) audio in \(String(format: "%.2fs", elapsed)) wall (\(String(format: "%.1fx", audioDuration/elapsed)) realtime)")
                await MainActor.run {
                    self.playKokoroSamples(samples)
                }
            } catch {
                Log.app.error("Kokoro synthesis failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.state = .idle
                    self.currentText = nil
                }
            }
        }
    }

    /// Schedule a [Float] PCM buffer (24kHz mono) on the player node and start it.
    private func playKokoroSamples(_ samples: [Float]) {
        guard !samples.isEmpty else {
            state = .idle
            currentText = nil
            return
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: Self.kokoroSampleRate,
                                          channels: 1,
                                          interleaved: false) else {
            Log.app.error("Could not construct AVAudioFormat for Kokoro output")
            state = .idle
            currentText = nil
            return
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            Log.app.error("Could not allocate AVAudioPCMBuffer")
            state = .idle
            currentText = nil
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channelData.update(from: src.baseAddress!, count: samples.count)
            }
        }

        if !audioEngineStarted {
            do {
                try audioEngine.start()
                audioEngineStarted = true
            } catch {
                Log.app.error("AudioEngine failed to start: \(error.localizedDescription)")
                state = .idle
                currentText = nil
                return
            }
        }

        kokoroPlayerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                self?.state = .idle
                self?.currentText = nil
            }
        }
        kokoroPlayerNode.play()
    }

    // MARK: - Apple AVSpeechSynthesizer

    func speak(_ text: String, voice: AVSpeechSynthesisVoice? = nil, rate: Float? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Cancel any in-flight utterance so a second "Speak" press replaces, not queues.
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        if let voice {
            utterance.voice = voice
        } else if let detected = detectLanguagePrefix(in: trimmed),
                  let resolved = defaultVoice(forLanguagePrefix: detected) {
            utterance.voice = resolved
        }
        if let rate {
            utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate,
                                 min(AVSpeechUtteranceMaximumSpeechRate, rate))
        }

        currentText = trimmed
        state = .speaking
        Log.app.info("VoiceOutput speak voice=\(utterance.voice?.identifier ?? "default") chars=\(trimmed.count)")
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if kokoroPlayerNode.isPlaying {
            kokoroPlayerNode.stop()
            state = .idle
            currentText = nil
        }
    }

    /// Speak a Kokoro sample for the Settings preview button.
    func speakKokoroSample(voiceName: String) {
        let language: KokoroSwift.Language = voiceName.hasPrefix("b") ? .enGB : .enUS
        let sample = language == .enGB
            ? "Hello, I'm NautPin, and I'll happily read your transcripts aloud."
            : "Hi, I'm NautPin, and I'll read your transcripts aloud whenever you want."
        speakKokoro(sample, voiceName: voiceName, language: language)
    }

    /// Speak a short sample in the given voice, useful for the Settings preview button.
    func speakSample(_ voice: AVSpeechSynthesisVoice) {
        let prefix = String(voice.language.prefix(2)).lowercased()
        let sample: String
        switch prefix {
        case "de": sample = "Hallo, ich bin NautPin und transkribiere für dich."
        case "fr": sample = "Bonjour, je suis NautPin et je transcris pour vous."
        case "es": sample = "Hola, soy NautPin y transcribo para ti."
        case "it": sample = "Ciao, sono NautPin e trascrivo per te."
        case "nl": sample = "Hallo, ik ben NautPin en transcribeer voor je."
        case "pt": sample = "Olá, eu sou NautPin e transcrevo para você."
        case "ja": sample = "こんにちは、私はNautPinです。"
        case "zh": sample = "你好，我是NautPin。"
        default: sample = "Hello, I'm NautPin and I transcribe for you."
        }
        speak(sample, voice: voice)
    }

    // MARK: - Heuristic language detection

    /// Crude language sniff for picking a default voice when no explicit voice is set.
    /// Looks at a handful of high-signal cues for German vs English — sufficient for the
    /// EN+DE primary use case. Returns "en" as the fallback.
    private func detectLanguagePrefix(in text: String) -> String? {
        let lower = text.lowercased()
        let germanCues = [" der ", " die ", " das ", " und ", " ist ", " nicht ",
                          " ich ", " mit ", " für ", "ä", "ö", "ü", "ß", " sind ", " wir "]
        let germanHits = germanCues.reduce(0) { acc, cue in acc + (lower.contains(cue) ? 1 : 0) }
        return germanHits >= 2 ? "de" : "en"
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.state = .idle
            self.currentText = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.state = .idle
            self.currentText = nil
        }
    }
}
