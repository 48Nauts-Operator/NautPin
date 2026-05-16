//
//  PindropMigrationService.swift
//  Pindrop
//
//  Created on 2026-05-16.
//
//  One-shot migration from upstream Pindrop (tech.watzon.pindrop) to NautPin
//  (com.48nauts.nautpin). Copies UserDefaults and the Application Support
//  folder so a freshly installed NautPin lights up with the user's existing
//  Pindrop state (settings, history, downloaded models, power-mode profiles)
//  instead of an empty cold start.
//
//  Copy semantics — not move. Upstream Pindrop continues to work as a
//  fallback / parallel install.
//

import Foundation

enum AppPaths {
    /// Subfolder of `~/Library/Application Support/` used by NautPin.
    static let applicationSupportFolderName = "NautPin"

    /// Subfolder previously used by upstream Pindrop (pre-rebrand and ongoing
    /// upstream installs). Only read for one-shot migration.
    static let upstreamPindropFolderName = "Pindrop"
}

@MainActor
enum PindropMigrationService {

    private static let upstreamBundleIdentifier = "tech.watzon.pindrop"
    private static let migrationSentinelKey = "nautpin.migratedFromUpstreamPindrop"

    /// Run once on app launch, before any `@AppStorage` reads or SwiftData
    /// container construction. Idempotent — sentinel in `UserDefaults.standard`
    /// prevents re-running.
    static func runMigrationIfNeeded(fileManager: FileManager = .default) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationSentinelKey) else {
            Log.boot.info("Pindrop→NautPin migration: already complete; skipping")
            return
        }

        var copiedKeys = 0
        var copiedFolder = false

        copiedKeys = migrateUserDefaults(into: defaults)
        copiedFolder = migrateApplicationSupportFolder(fileManager: fileManager)

        defaults.set(true, forKey: migrationSentinelKey)

        Log.boot.info("Pindrop→NautPin migration complete: userDefaults_keys=\(copiedKeys) app_support_folder_copied=\(copiedFolder)")
    }

    // MARK: - UserDefaults

    private static func migrateUserDefaults(into destination: UserDefaults) -> Int {
        guard let source = UserDefaults(suiteName: upstreamBundleIdentifier) else {
            Log.boot.info("Pindrop→NautPin migration: no upstream UserDefaults suite present")
            return 0
        }

        let sourceDict = source.persistentDomain(forName: upstreamBundleIdentifier) ?? source.dictionaryRepresentation()

        // Never overwrite a key the user has already set in NautPin (they may
        // have used the app before the migration check fired in a prior build).
        let existing = Set(destination.dictionaryRepresentation().keys)
        var copied = 0
        for (key, value) in sourceDict where !existing.contains(key) {
            destination.set(value, forKey: key)
            copied += 1
        }
        return copied
    }

    // MARK: - Application Support

    private static func migrateApplicationSupportFolder(fileManager: FileManager) -> Bool {
        guard let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        let source = supportRoot.appendingPathComponent(AppPaths.upstreamPindropFolderName, isDirectory: true)
        let destination = supportRoot.appendingPathComponent(AppPaths.applicationSupportFolderName, isDirectory: true)

        guard fileManager.fileExists(atPath: source.path) else {
            Log.boot.info("Pindrop→NautPin migration: no upstream Application Support folder at \(source.path)")
            return false
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            Log.boot.info("Pindrop→NautPin migration: NautPin folder already exists at \(destination.path); leaving as-is")
            return false
        }

        do {
            try fileManager.copyItem(at: source, to: destination)
            Log.boot.info("Pindrop→NautPin migration: copied \(source.lastPathComponent) → \(destination.lastPathComponent)")
            return true
        } catch {
            Log.boot.error("Pindrop→NautPin migration: failed to copy Application Support folder: \(error.localizedDescription)")
            return false
        }
    }
}
