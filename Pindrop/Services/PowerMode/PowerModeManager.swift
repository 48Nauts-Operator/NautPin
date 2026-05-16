//
//  PowerModeManager.swift
//  Pindrop
//
//  Created on 2026-05-01.
//
//  Owns the user's [PowerModeConfig] list and the currently active configuration.
//  Persists as JSON in UserDefaults under `powerModeConfigurationsV2`. Resolution from
//  (bundleID, url) → active config is performed by ActiveWindowService, which calls
//  setActive(:) on this manager.
//

import Foundation

@MainActor
@Observable
final class PowerModeManager {

   enum PowerModeManagerError: Error, LocalizedError {
      case persistenceFailed(String)
      case decodeFailed(String)
      case multipleDefaults

      var errorDescription: String? {
         switch self {
         case .persistenceFailed(let message):
            return "Failed to save Power Mode configurations: \(message)"
         case .decodeFailed(let message):
            return "Failed to read Power Mode configurations: \(message)"
         case .multipleDefaults:
            return "Only one Power Mode configuration can be marked default"
         }
      }
   }

   // MARK: - Storage

   static let storageKey = "powerModeConfigurationsV2"

   // MARK: - Observable state

   private(set) var configurations: [PowerModeConfig]
   private(set) var activeConfiguration: PowerModeConfig?

   // MARK: - Dependencies

   private let storage: UserDefaults
   private let encoder: JSONEncoder
   private let decoder: JSONDecoder

   // MARK: - Init

   init(storage: UserDefaults = .standard) {
      self.storage = storage
      self.encoder = JSONEncoder()
      self.decoder = JSONDecoder()
      self.configurations = Self.load(from: storage, decoder: decoder)
      self.activeConfiguration = nil
   }

   // MARK: - CRUD

   /// Add a new configuration. If `isDefault == true`, demotes any existing default.
   /// Throws if persistence fails.
   func add(_ config: PowerModeConfig) throws {
      var next = configurations
      if config.isDefault {
         next = next.map { var c = $0; c.isDefault = false; return c }
      }
      next.append(config)
      try commit(next)
   }

   /// Replace an existing configuration by id. If `isDefault == true`, demotes any other
   /// configuration that previously held the default flag.
   func update(_ config: PowerModeConfig) throws {
      var next = configurations
      guard let index = next.firstIndex(where: { $0.id == config.id }) else { return }
      if config.isDefault {
         next = next.map { var c = $0; if c.id != config.id { c.isDefault = false }; return c }
      }
      next[index] = config
      try commit(next)
   }

   /// Remove a configuration. If the removed configuration was the active one,
   /// `activeConfiguration` is cleared. Callers re-resolve through ActiveWindowService.
   func remove(id: UUID) throws {
      let next = configurations.filter { $0.id != id }
      if activeConfiguration?.id == id {
         activeConfiguration = nil
      }
      try commit(next)
   }

   /// Reorder the full list. Used by the settings UI when the user drags rows.
   func reorder(_ next: [PowerModeConfig]) throws {
      try commit(next)
   }

   // MARK: - Active selection

   /// Set the currently active configuration by id. Pass `nil` to clear (no profile applies).
   /// This does NOT persist — it's a runtime selection driven by ActiveWindowService.
   func setActive(_ id: UUID?) {
      guard let id else {
         activeConfiguration = nil
         return
      }
      activeConfiguration = configurations.first(where: { $0.id == id })
   }

   /// Convenience: returns the current default configuration if exactly one is marked.
   var defaultConfiguration: PowerModeConfig? {
      configurations.first(where: { $0.isDefault })
   }

   // MARK: - Persistence

   private func commit(_ next: [PowerModeConfig]) throws {
      do {
         let data = try encoder.encode(next)
         storage.set(data, forKey: Self.storageKey)
         configurations = next
         // Re-resolve active in case its underlying record changed.
         if let active = activeConfiguration {
            activeConfiguration = next.first(where: { $0.id == active.id })
         }
      } catch {
         throw PowerModeManagerError.persistenceFailed(error.localizedDescription)
      }
   }

   private static func load(from storage: UserDefaults, decoder: JSONDecoder) -> [PowerModeConfig] {
      guard let data = storage.data(forKey: storageKey) else { return [] }
      do {
         return try decoder.decode([PowerModeConfig].self, from: data)
      } catch {
         Log.app.warning("Failed to decode Power Mode configurations; resetting: \(error.localizedDescription)")
         return []
      }
   }
}
