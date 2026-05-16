//
//  PowerModeConfig.swift
//  Pindrop
//
//  Created on 2026-05-01.
//
//  Power Mode profile data model. A PowerModeConfig binds context (app bundle IDs,
//  URL substrings) to a behavioral override (prompt preset, model assignment, language,
//  auto-send key). When a profile is active, its values overlay SettingsStore for the
//  current dictation session — never written through.
//
//  Persisted as a JSON-encoded [PowerModeConfig] in AppStorage under
//  `powerModeConfigurationsV2` (see PowerModeManager).
//

import Foundation

// MARK: - PowerModeConfig

struct PowerModeConfig: Codable, Identifiable, Equatable, Hashable {
   let id: UUID
   var name: String
   var emoji: String
   /// App bundle identifiers this profile applies to. Empty = no app match.
   var appBundleIDs: [String]
   /// URL substrings this profile applies to (case-insensitive contains match against
   /// the frontmost browser tab URL). Empty = no URL match. Wildcards are not supported;
   /// `"github.com"` matches both `https://github.com/foo` and `https://www.github.com/foo`.
   var urlPatterns: [String]
   /// Stable identifier of a PromptPreset (built-in or user). Resolved through
   /// PromptPresetStore. `nil` means "use the global cleanup default".
   var promptPresetID: String?
   /// Optional override of the V2 model assignment for `transcriptionEnhancement`.
   /// `nil` means "use the user's global assignment for that purpose".
   var modelAssignment: ModelAssignment?
   /// AppLanguage rawValue. `nil` means "use the global selectedLanguage".
   var language: String?
   /// What to type after pasting. `.none` matches Pindrop's default behavior.
   var autoSendKey: AutoSendKey
   /// Exactly one config in the list should have `isDefault == true`. The default applies
   /// when no app/URL match resolves. PowerModeManager enforces uniqueness on save.
   var isDefault: Bool

   init(
      id: UUID = UUID(),
      name: String,
      emoji: String = "✨",
      appBundleIDs: [String] = [],
      urlPatterns: [String] = [],
      promptPresetID: String? = nil,
      modelAssignment: ModelAssignment? = nil,
      language: String? = nil,
      autoSendKey: AutoSendKey = .none,
      isDefault: Bool = false
   ) {
      self.id = id
      self.name = name
      self.emoji = emoji
      self.appBundleIDs = appBundleIDs
      self.urlPatterns = urlPatterns
      self.promptPresetID = promptPresetID
      self.modelAssignment = modelAssignment
      self.language = language
      self.autoSendKey = autoSendKey
      self.isDefault = isDefault
   }

   // MARK: Codable

   enum CodingKeys: String, CodingKey {
      case id
      case name
      case emoji
      case appBundleIDs
      case urlPatterns
      case promptPresetID
      case modelAssignment
      case language
      case autoSendKey
      case isDefault
   }

   init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.id = try container.decode(UUID.self, forKey: .id)
      self.name = try container.decode(String.self, forKey: .name)
      self.emoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? "✨"
      self.appBundleIDs = try container.decodeIfPresent([String].self, forKey: .appBundleIDs) ?? []
      self.urlPatterns = try container.decodeIfPresent([String].self, forKey: .urlPatterns) ?? []
      self.promptPresetID = try container.decodeIfPresent(String.self, forKey: .promptPresetID)
      self.modelAssignment = try container.decodeIfPresent(ModelAssignment.self, forKey: .modelAssignment)
      self.language = try container.decodeIfPresent(String.self, forKey: .language)
      if let raw = try container.decodeIfPresent(String.self, forKey: .autoSendKey) {
         self.autoSendKey = AutoSendKey(rawValue: raw) ?? .none
      } else {
         self.autoSendKey = .none
      }
      self.isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
   }

   func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(id, forKey: .id)
      try container.encode(name, forKey: .name)
      try container.encode(emoji, forKey: .emoji)
      try container.encode(appBundleIDs, forKey: .appBundleIDs)
      try container.encode(urlPatterns, forKey: .urlPatterns)
      try container.encodeIfPresent(promptPresetID, forKey: .promptPresetID)
      try container.encodeIfPresent(modelAssignment, forKey: .modelAssignment)
      try container.encodeIfPresent(language, forKey: .language)
      try container.encode(autoSendKey.rawValue, forKey: .autoSendKey)
      try container.encode(isDefault, forKey: .isDefault)
   }
}

// MARK: - AutoSendKey

/// Key event to dispatch after the transcription is pasted into the focused text field.
/// Used to implement "press to dictate, auto-send" UX in chat-style apps.
enum AutoSendKey: String, Codable, CaseIterable, Hashable {
   case none
   case enter
   case shiftEnter
   case cmdEnter

   var displayName: String {
      switch self {
      case .none: return "None"
      case .enter: return "Enter"
      case .shiftEnter: return "Shift+Enter"
      case .cmdEnter: return "Cmd+Enter"
      }
   }
}

// MARK: - Resolution

extension PowerModeConfig {
   /// Returns true if this config matches the given context.
   /// Match precedence (caller's responsibility) is URL > app > default.
   func matches(bundleID: String?, url: String?) -> Bool {
      if let url, !urlPatterns.isEmpty {
         let lower = url.lowercased()
         if urlPatterns.contains(where: { lower.contains($0.lowercased()) }) {
            return true
         }
      }
      if let bundleID, appBundleIDs.contains(bundleID) {
         return true
      }
      return false
   }
}
