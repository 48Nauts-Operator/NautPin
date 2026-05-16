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
         Button {
            service.speakSample(voice)
         } label: {
            HStack(spacing: 4) {
               Image(systemName: service.state == .speaking ? "speaker.wave.2.fill" : "play.fill")
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
