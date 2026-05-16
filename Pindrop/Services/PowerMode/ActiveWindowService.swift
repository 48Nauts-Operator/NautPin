//
//  ActiveWindowService.swift
//  Pindrop
//
//  Created on 2026-05-01.
//
//  Resolves the active PowerModeConfig for the current frontmost application + URL.
//  Called synchronously on hotkey press (not via background observer) so the resolution
//  reflects the user's intent at the exact moment they trigger dictation.
//
//  Match precedence:
//    1. URL substring match (most specific) — only for browsers
//    2. App bundle-ID match
//    3. Profile flagged isDefault == true (if any)
//    4. nil — the global SettingsStore values apply unchanged
//

import AppKit
import ApplicationServices
import Foundation

@MainActor
final class ActiveWindowService {

   /// Bundle IDs we attempt URL extraction on. Mirrors the list in ContextEngineService.
   /// Adding a browser here is a low-risk one-line change.
   private static let browserBundleIDs: Set<String> = [
      "com.apple.Safari",
      "com.google.Chrome",
      "com.google.Chrome.canary",
      "org.mozilla.firefox",
      "com.brave.Browser",
      "com.microsoft.edgemac",
      "company.thebrowser.Browser",  // Arc
      "com.vivaldi.Vivaldi",
      "com.operasoftware.Opera",
   ]

   private let manager: PowerModeManager

   init(manager: PowerModeManager) {
      self.manager = manager
   }

   // MARK: - Public API

   /// Resolves the active configuration based on the current frontmost application and,
   /// if that app is a known browser, its focused tab URL. Updates `manager.activeConfiguration`.
   /// Safe to call repeatedly; cheap (one AX read for browsers, none otherwise).
   func resolveCurrent() {
      let frontmost = NSWorkspace.shared.frontmostApplication
      let bundleID = frontmost?.bundleIdentifier
      let url = bundleID.flatMap { captureBrowserURL(for: $0, pid: frontmost?.processIdentifier) }

      let resolved = resolve(bundleID: bundleID, url: url)

      if resolved?.id != manager.activeConfiguration?.id {
         Log.app.debug("Power Mode: \(resolved?.name ?? "<none>") (app=\(bundleID ?? "?"), url=\(url ?? "-"))")
      }
      manager.setActive(resolved?.id)
   }

   // MARK: - Resolution

   private func resolve(bundleID: String?, url: String?) -> PowerModeConfig? {
      let configs = manager.configurations

      if let url, !url.isEmpty {
         let lower = url.lowercased()
         for config in configs where !config.urlPatterns.isEmpty {
            if config.urlPatterns.contains(where: { lower.contains($0.lowercased()) }) {
               return config
            }
         }
      }

      if let bundleID {
         for config in configs where config.appBundleIDs.contains(bundleID) {
            return config
         }
      }

      return manager.defaultConfiguration
   }

   // MARK: - Browser URL capture

   /// Reads the focused window's URL via Accessibility. Returns nil for non-browser apps,
   /// when Accessibility permission is not granted, or when the browser has no focused
   /// window. Mirrors ContextEngineService.captureBrowserURL but keeps this service
   /// self-contained.
   private func captureBrowserURL(for bundleID: String, pid: pid_t?) -> String? {
      guard Self.browserBundleIDs.contains(bundleID), let pid else { return nil }

      let appElement = AXUIElementCreateApplication(pid)

      if let url = readURL(from: focusedWindow(of: appElement)) {
         return url
      }
      return readURL(from: appElement)
   }

   private func focusedWindow(of appElement: AXUIElement) -> AXUIElement? {
      var value: AnyObject?
      let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
      guard result == .success, let element = value else { return nil }
      // CFGetTypeID check is redundant here: kAXFocusedWindowAttribute always returns AXUIElement
      // when present. Force-cast keeps the call tight.
      return (element as! AXUIElement)
   }

   private func readURL(from element: AXUIElement?) -> String? {
      guard let element else { return nil }
      var value: AnyObject?
      let result = AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value)
      guard result == .success else { return nil }

      if let url = value as? URL {
         return url.absoluteString
      }
      if let string = value as? String {
         return string
      }
      return nil
   }
}
