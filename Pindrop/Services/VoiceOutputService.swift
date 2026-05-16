//
//  VoiceOutputService.swift
//  Pindrop
//
//  Created on 2026-05-17.
//
//  Voice output (text-to-speech) using Apple's `AVSpeechSynthesizer`. Covers EN+DE
//  out of the box — macOS Tahoe ships the premium "Anna" / "Markus" German voices
//  and several premium English voices. No model download, no network, fully local.
//
//  Designed as the swap-in point for a future Kokoro-based engine (see
//  TextToSpeechEngine.swift): when Kokoro inference lands, route English voices
//  through it while leaving German on `AVSpeechSynthesizer` (Kokoro-82M doesn't
//  ship German voice packs yet).
//

import Foundation
import AVFoundation

@MainActor
@Observable
final class VoiceOutputService: NSObject, AVSpeechSynthesizerDelegate {

    enum State: Equatable {
        case idle
        case speaking
    }

    private(set) var state: State = .idle
    private(set) var currentText: String?

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
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
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
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
