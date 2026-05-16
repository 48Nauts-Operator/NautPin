//
//  PowerModeSettingsView.swift
//  Pindrop
//
//  Created on 2026-05-01.
//
//  Settings tab for Power Mode profiles. Lists configurations, opens an edit sheet
//  for add/update, and shows the currently active profile based on resolution.
//
//  Weekend 1 MVP scope: name, emoji, app bundle IDs, URL patterns, isDefault.
//  Prompt preset and model assignment override pickers are intentionally deferred
//  until the AIConfigurationV2 override layer is wired.
//

import SwiftUI

// MARK: - Top-level settings view

struct PowerModeSettingsView: View {
   let manager: PowerModeManager
   @Environment(\.locale) private var locale
   @State private var editingConfig: PowerModeConfig?
   @State private var isPresentingNew = false
   @State private var errorMessage: String?

   var body: some View {
      VStack(spacing: AppTheme.Spacing.xl) {
         activeStatusCard
         profilesCard
      }
      .sheet(isPresented: $isPresentingNew) {
         PowerModeConfigEditor(
            config: PowerModeConfig(name: "New Profile"),
            isNew: true,
            onSave: { commitNew($0) },
            onCancel: { isPresentingNew = false }
         )
      }
      .sheet(item: $editingConfig) { config in
         PowerModeConfigEditor(
            config: config,
            isNew: false,
            onSave: { commitUpdate($0) },
            onCancel: { editingConfig = nil }
         )
      }
      .alert(
         localized("Error", locale: locale),
         isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
         )
      ) {
         Button(localized("OK", locale: locale), role: .cancel) {}
      } message: {
         if let errorMessage {
            Text(errorMessage)
         }
      }
   }

   // MARK: - Active status

   private var activeStatusCard: some View {
      SettingsCard(
         title: localized("Active Profile", locale: locale),
         icon: "bolt.circle",
         detail: localized("Resolved on each dictation start based on the frontmost app", locale: locale)
      ) {
         HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
            Text(manager.activeConfiguration?.emoji ?? "—")
               .font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
               Text(manager.activeConfiguration?.name ?? localized("None", locale: locale))
                  .font(AppTypography.body)
                  .foregroundStyle(AppColors.textPrimary)
               Text(activeSubtitle)
                  .font(AppTypography.caption)
                  .foregroundStyle(AppColors.textSecondary)
            }
            Spacer(minLength: 0)
         }
         .padding(.vertical, AppTheme.Spacing.sm)
      }
   }

   private var activeSubtitle: String {
      if let active = manager.activeConfiguration {
         if active.isDefault {
            return localized("Default profile", locale: locale)
         }
         if !active.urlPatterns.isEmpty {
            return localized("URL match", locale: locale)
         }
         if !active.appBundleIDs.isEmpty {
            return localized("App match", locale: locale)
         }
         return ""
      }
      return localized("No active profile — global settings apply", locale: locale)
   }

   // MARK: - Profiles list

   private var profilesCard: some View {
      SettingsCard(
         title: localized("Profiles", locale: locale),
         icon: "rectangle.stack",
         detail: localized("Per-app and per-URL behavior overrides", locale: locale)
      ) {
         VStack(alignment: .leading, spacing: 0) {
            if manager.configurations.isEmpty {
               emptyState
            } else {
               ForEach(Array(manager.configurations.enumerated()), id: \.element.id) { index, config in
                  profileRow(config)
                  if index < manager.configurations.count - 1 {
                     SettingsDivider()
                  }
               }
            }

            SettingsDivider()
               .padding(.top, manager.configurations.isEmpty ? 0 : AppTheme.Spacing.sm)

            HStack {
               Spacer()
               Button {
                  isPresentingNew = true
               } label: {
                  Label(localized("Add Profile", locale: locale), systemImage: "plus")
               }
               .buttonStyle(.borderedProminent)
               .controlSize(.regular)
               .accessibilityIdentifier("powerMode.add")
            }
            .padding(.top, AppTheme.Spacing.sm)
         }
      }
   }

   private var emptyState: some View {
      VStack(spacing: AppTheme.Spacing.sm) {
         Image(systemName: "bolt.slash")
            .font(.system(size: 28, weight: .light))
            .foregroundStyle(AppColors.textTertiary)
         Text(localized("No Power Mode profiles yet", locale: locale))
            .font(AppTypography.body)
            .foregroundStyle(AppColors.textSecondary)
         Text(localized("Create a profile to swap behavior based on the active app or URL.", locale: locale))
            .font(AppTypography.caption)
            .foregroundStyle(AppColors.textTertiary)
            .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, AppTheme.Spacing.lg)
   }

   private func profileRow(_ config: PowerModeConfig) -> some View {
      HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
         Text(config.emoji)
            .font(.system(size: 20))

         VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: AppTheme.Spacing.xs) {
               Text(config.name)
                  .font(AppTypography.body)
                  .foregroundStyle(AppColors.textPrimary)
               if config.isDefault {
                  Text(localized("DEFAULT", locale: locale))
                     .font(.system(size: 10, weight: .semibold, design: .rounded))
                     .foregroundStyle(AppColors.accent)
                     .padding(.horizontal, 6)
                     .padding(.vertical, 2)
                     .background(
                        Capsule().stroke(AppColors.accent.opacity(0.6), lineWidth: 1)
                     )
               }
            }
            Text(rowSubtitle(for: config))
               .font(AppTypography.caption)
               .foregroundStyle(AppColors.textSecondary)
               .lineLimit(1)
         }

         Spacer(minLength: 0)

         HStack(spacing: AppTheme.Spacing.xs) {
            Button {
               editingConfig = config
            } label: {
               Image(systemName: "pencil")
                  .font(.system(size: 12, weight: .medium))
                  .foregroundStyle(AppColors.textSecondary)
            }
            .buttonStyle(.borderless)
            .help(localized("Edit", locale: locale))
            .accessibilityIdentifier("powerMode.edit.\(config.id.uuidString)")

            Button(role: .destructive) {
               commitDelete(config)
            } label: {
               Image(systemName: "trash")
                  .font(.system(size: 12, weight: .medium))
                  .foregroundStyle(AppColors.textSecondary)
            }
            .buttonStyle(.borderless)
            .help(localized("Delete", locale: locale))
            .accessibilityIdentifier("powerMode.delete.\(config.id.uuidString)")
         }
      }
      .padding(.vertical, AppTheme.Spacing.sm)
   }

   private func rowSubtitle(for config: PowerModeConfig) -> String {
      var parts: [String] = []
      if !config.appBundleIDs.isEmpty {
         parts.append(String(format: localized("%d apps", locale: locale), config.appBundleIDs.count))
      }
      if !config.urlPatterns.isEmpty {
         parts.append(String(format: localized("%d URLs", locale: locale), config.urlPatterns.count))
      }
      if parts.isEmpty {
         return localized("No matchers — only matches if marked default", locale: locale)
      }
      return parts.joined(separator: " · ")
   }

   // MARK: - Actions

   private func commitNew(_ config: PowerModeConfig) {
      do {
         try manager.add(config)
         isPresentingNew = false
      } catch {
         errorMessage = error.localizedDescription
      }
   }

   private func commitUpdate(_ config: PowerModeConfig) {
      do {
         try manager.update(config)
         editingConfig = nil
      } catch {
         errorMessage = error.localizedDescription
      }
   }

   private func commitDelete(_ config: PowerModeConfig) {
      do {
         try manager.remove(id: config.id)
      } catch {
         errorMessage = error.localizedDescription
      }
   }
}

// MARK: - Editor sheet

struct PowerModeConfigEditor: View {
   @Environment(\.locale) private var locale

   @State private var name: String
   @State private var emoji: String
   @State private var appBundleIDs: String
   @State private var urlPatterns: String
   @State private var isDefault: Bool

   private let originalID: UUID
   private let isNew: Bool
   private let onSave: (PowerModeConfig) -> Void
   private let onCancel: () -> Void

   init(
      config: PowerModeConfig,
      isNew: Bool,
      onSave: @escaping (PowerModeConfig) -> Void,
      onCancel: @escaping () -> Void
   ) {
      self.originalID = config.id
      self.isNew = isNew
      self.onSave = onSave
      self.onCancel = onCancel
      _name = State(initialValue: config.name)
      _emoji = State(initialValue: config.emoji)
      _appBundleIDs = State(initialValue: config.appBundleIDs.joined(separator: "\n"))
      _urlPatterns = State(initialValue: config.urlPatterns.joined(separator: "\n"))
      _isDefault = State(initialValue: config.isDefault)
   }

   var body: some View {
      VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
         Text(isNew ? localized("New Power Mode Profile", locale: locale) : localized("Edit Power Mode Profile", locale: locale))
            .font(AppTypography.title)
            .foregroundStyle(AppColors.textPrimary)

         VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.md) {
               labeledField(localized("Emoji", locale: locale), width: 80) {
                  TextField("", text: $emoji)
                     .textFieldStyle(.roundedBorder)
                     .frame(maxWidth: 80)
               }
               labeledField(localized("Name", locale: locale)) {
                  TextField("", text: $name)
                     .textFieldStyle(.roundedBorder)
               }
            }

            labeledField(localized("App bundle IDs (one per line)", locale: locale)) {
               TextEditor(text: $appBundleIDs)
                  .font(.system(.body, design: .monospaced))
                  .frame(minHeight: 70)
                  .scrollContentBackground(.hidden)
                  .padding(6)
                  .background(AppColors.surfaceBackground, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                  .overlay(
                     RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .stroke(AppColors.border.opacity(0.6), lineWidth: 1)
                  )
            }

            Text(localized("Example: com.tinyspeck.slackmacgap, com.microsoft.VSCode", locale: locale))
               .font(AppTypography.caption)
               .foregroundStyle(AppColors.textTertiary)

            labeledField(localized("URL patterns (substring match, one per line)", locale: locale)) {
               TextEditor(text: $urlPatterns)
                  .font(.system(.body, design: .monospaced))
                  .frame(minHeight: 60)
                  .scrollContentBackground(.hidden)
                  .padding(6)
                  .background(AppColors.surfaceBackground, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                  .overlay(
                     RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .stroke(AppColors.border.opacity(0.6), lineWidth: 1)
                  )
            }

            Text(localized("Example: github.com, twitter.com — case-insensitive contains match", locale: locale))
               .font(AppTypography.caption)
               .foregroundStyle(AppColors.textTertiary)

            Toggle(isOn: $isDefault) {
               VStack(alignment: .leading, spacing: 2) {
                  Text(localized("Default profile", locale: locale))
                     .font(AppTypography.body)
                  Text(localized("Used when no app or URL match. Only one profile can be default.", locale: locale))
                     .font(AppTypography.caption)
                     .foregroundStyle(AppColors.textSecondary)
               }
            }
            .toggleStyle(.switch)
         }

         Divider().background(AppColors.divider)

         HStack {
            Spacer()
            Button(localized("Cancel", locale: locale), role: .cancel) {
               onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Button {
               saveAndDismiss()
            } label: {
               Text(isNew ? localized("Add", locale: locale) : localized("Save", locale: locale))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
         }
      }
      .padding(AppTheme.Spacing.xl)
      .frame(minWidth: 480)
   }

   @ViewBuilder
   private func labeledField<Content: View>(
      _ label: String,
      width: CGFloat? = nil,
      @ViewBuilder content: () -> Content
   ) -> some View {
      VStack(alignment: .leading, spacing: 4) {
         Text(label)
            .font(AppTypography.caption)
            .foregroundStyle(AppColors.textSecondary)
         content()
      }
      .frame(maxWidth: width ?? .infinity, alignment: .leading)
   }

   private func saveAndDismiss() {
      let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedName.isEmpty else { return }

      let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)

      let appsList = appBundleIDs
         .split(whereSeparator: { $0.isNewline })
         .map { $0.trimmingCharacters(in: .whitespaces) }
         .filter { !$0.isEmpty }

      let urlsList = urlPatterns
         .split(whereSeparator: { $0.isNewline })
         .map { $0.trimmingCharacters(in: .whitespaces) }
         .filter { !$0.isEmpty }

      let result = PowerModeConfig(
         id: originalID,
         name: trimmedName,
         emoji: trimmedEmoji.isEmpty ? "✨" : trimmedEmoji,
         appBundleIDs: appsList,
         urlPatterns: urlsList,
         isDefault: isDefault
      )

      onSave(result)
   }
}

// MARK: - Unavailable placeholder

struct PowerModeUnavailableView: View {
   @Environment(\.locale) private var locale

   var body: some View {
      VStack(spacing: AppTheme.Spacing.lg) {
         Image(systemName: "bolt.slash")
            .font(.system(size: 32, weight: .light))
            .foregroundStyle(AppColors.textTertiary)
         Text(localized("Power Mode service unavailable", locale: locale))
            .font(AppTypography.body)
            .foregroundStyle(AppColors.textSecondary)
         Text(localized("This usually appears in previews or test fixtures where the manager is not wired in.", locale: locale))
            .font(AppTypography.caption)
            .foregroundStyle(AppColors.textTertiary)
            .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(AppTheme.Spacing.xxl)
   }
}
