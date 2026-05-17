//
//  VoiceOutputSettingsView.swift
//  Pindrop
//
//  Created on 2026-05-17.
//
//  Settings tab for the voice-output (text-to-speech) feature. Lets the user
//  preview available system voices and pick a default for English and German.
//  Uses Apple's AVSpeechSynthesizer under the hood (see VoiceOutputService).
//
//  Future: when Kokoro inference lands, this view stays unchanged — the engine
//  router transparently routes EN voices through Kokoro while DE stays on
//  Apple's premium Anna / Markus voices.
//

import SwiftUI
import AVFoundation

struct VoiceOutputSettingsView: View {
   let service: VoiceOutputService
   @Environment(\.locale) private var locale

   var body: some View {
      VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
         introCard
         kokoroCard
         voicesCard
      }
   }

   private var introCard: some View {
      SettingsCard(
         title: localized("Voice Output", locale: locale),
         icon: "speaker.wave.2"
      ) {
         VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(localized("Read transcripts aloud using on-device speech synthesis. No network, no model download — uses macOS Tahoe's built-in voices.", locale: locale))
               .font(AppTypography.body)
               .foregroundStyle(AppColors.textPrimary)
            Text(localized("Tip: macOS ships premium German voices (Anna, Markus) — install them via System Settings → Accessibility → Spoken Content → System Voice if not already downloaded.", locale: locale))
               .font(AppTypography.caption)
               .foregroundStyle(AppColors.textSecondary)
         }
         .frame(maxWidth: .infinity, alignment: .leading)
      }
   }

   private var kokoroCard: some View {
      SettingsCard(
         title: localized("Kokoro (neural English voices)", locale: locale),
         icon: "waveform"
      ) {
         VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(localized("Kokoro-82M runs locally on Apple Silicon via MLX. 28 English voices (en-US + en-GB), bundled in the app. First sample takes ~1-2s to warm up; subsequent samples are ~3× realtime.", locale: locale))
               .font(AppTypography.caption)
               .foregroundStyle(AppColors.textSecondary)

            if service.kokoroVoiceNames.isEmpty {
               // Not yet loaded — show a single "warm up & list voices" button.
               // See speakKokoro button below for the Task wrapper rationale.
               Button {
                  Task { @MainActor in
                     _ = service.loadKokoroIfNeeded()
                  }
               } label: {
                  HStack(spacing: 4) {
                     Image(systemName: "arrow.down.circle")
                     Text(localized("Load Kokoro (one-time warm-up)", locale: locale))
                  }
               }
               .buttonStyle(.bordered)
               .controlSize(.small)
            } else {
               ForEach(service.kokoroVoiceNames, id: \.self) { voiceName in
                  kokoroVoiceRow(voiceName)
                  if voiceName != service.kokoroVoiceNames.last {
                     Divider().background(AppColors.divider)
                  }
               }
            }
         }
         .frame(maxWidth: .infinity, alignment: .leading)
      }
   }

   private func kokoroVoiceRow(_ voiceName: String) -> some View {
      let region = voiceName.first == "a" ? "en-US"
                 : voiceName.first == "b" ? "en-GB" : "?"
      let gender = voiceName.dropFirst().first == "f" ? "♀"
                 : voiceName.dropFirst().first == "m" ? "♂" : ""
      let displayName = voiceName.split(separator: "_").last.map(String.init)?.capitalized ?? voiceName

      return HStack(spacing: AppTheme.Spacing.md) {
         VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: AppTheme.Spacing.xs) {
               Text("\(displayName) \(gender)")
                  .font(AppTypography.body)
                  .foregroundStyle(AppColors.textPrimary)
               Text("Kokoro")
                  .font(AppTypography.caption.bold())
                  .foregroundStyle(AppColors.surfaceBackground)
                  .padding(.horizontal, 6).padding(.vertical, 2)
                  .background(Color.blue.opacity(0.7), in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            }
            Text("\(region) · \(voiceName)")
               .font(AppTypography.caption)
               .foregroundStyle(AppColors.textSecondary)
         }
         Spacer(minLength: AppTheme.Spacing.md)
         // NOTE: action is wrapped in an explicit Task and the label avoids
         // reading @Observable state — workaround for a macOS 26 / Swift 6
         // runtime crash in MainActor.assumeIsolated when a @MainActor
         // @Observable property is read inside a SwiftUI button label.
         Button {
            let name = voiceName
            Task { @MainActor in
               service.speakKokoroSample(voiceName: name)
            }
         } label: {
            HStack(spacing: 4) {
               Image(systemName: "play.fill")
               Text(localized("Sample", locale: locale))
            }
            .frame(minWidth: 70)
         }
         .buttonStyle(.bordered)
         .controlSize(.small)
      }
      .padding(.vertical, 4)
   }

   private var voicesCard: some View {
      SettingsCard(
         title: localized("Available voices", locale: locale),
         icon: "person.wave.2"
      ) {
         VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            let voices = preferredVoices()
            if voices.isEmpty {
               Text(localized("No voices installed for English or German. Open System Settings → Accessibility → Spoken Content to download them.", locale: locale))
                  .font(AppTypography.body)
                  .foregroundStyle(AppColors.textSecondary)
            } else {
               ForEach(voices, id: \.identifier) { voice in
                  voiceRow(voice)
                  if voice.identifier != voices.last?.identifier {
                     Divider().background(AppColors.divider)
                  }
               }
            }
         }
         .frame(maxWidth: .infinity, alignment: .leading)
      }
   }

   private func voiceRow(_ voice: AVSpeechSynthesisVoice) -> some View {
      HStack(spacing: AppTheme.Spacing.md) {
         VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: AppTheme.Spacing.xs) {
               Text(voice.name)
                  .font(AppTypography.body)
                  .foregroundStyle(AppColors.textPrimary)
               qualityBadge(voice.quality)
            }
            Text(localizedLanguageName(voice.language))
               .font(AppTypography.caption)
               .foregroundStyle(AppColors.textSecondary)
         }
         Spacer(minLength: AppTheme.Spacing.md)
         // Same Task + static-icon workaround as the Kokoro Sample button.
         Button {
            let v = voice
            Task { @MainActor in
               service.speakSample(v)
            }
         } label: {
            HStack(spacing: 4) {
               Image(systemName: "play.fill")
               Text(localized("Sample", locale: locale))
            }
            .frame(minWidth: 70)
         }
         .buttonStyle(.bordered)
         .controlSize(.small)
      }
      .padding(.vertical, 4)
   }

   @ViewBuilder
   private func qualityBadge(_ quality: AVSpeechSynthesisVoiceQuality) -> some View {
      switch quality {
      case .premium:
         Text("Premium")
            .font(AppTypography.caption.bold())
            .foregroundStyle(AppColors.surfaceBackground)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(AppColors.textPrimary, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
      case .enhanced:
         Text("Enhanced")
            .font(AppTypography.caption)
            .foregroundStyle(AppColors.textSecondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(AppColors.surfaceBackground, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
      default:
         EmptyView()
      }
   }

   private func preferredVoices() -> [AVSpeechSynthesisVoice] {
      // Prioritize EN+DE since that's the user's primary working language pair.
      let en = service.voices(forLanguagePrefix: "en")
      let de = service.voices(forLanguagePrefix: "de")
      return de + en
   }

   private func localizedLanguageName(_ bcp47: String) -> String {
      let canonical = bcp47.replacingOccurrences(of: "_", with: "-")
      if let name = Locale.current.localizedString(forIdentifier: canonical) {
         return "\(name) — \(canonical)"
      }
      return canonical
   }
}

// MARK: - Unavailable placeholder

struct VoiceOutputUnavailableView: View {
   @Environment(\.locale) private var locale

   var body: some View {
      VStack(spacing: AppTheme.Spacing.lg) {
         Image(systemName: "speaker.slash")
            .font(.system(size: 32, weight: .light))
            .foregroundStyle(AppColors.textTertiary)
         Text(localized("Voice Output service unavailable", locale: locale))
            .font(AppTypography.body)
            .foregroundStyle(AppColors.textSecondary)
         Text(localized("This usually appears in previews or test fixtures where the service is not wired in.", locale: locale))
            .font(AppTypography.caption)
            .foregroundStyle(AppColors.textTertiary)
            .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(AppTheme.Spacing.xxl)
   }
}
