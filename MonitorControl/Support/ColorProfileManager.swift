//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import CoreGraphics
import Foundation
import os.log

/// Manages color profiles for connected displays.
/// Lists ICC profiles from system and user directories and can set them on displays.
class ColorProfileManager {
  static let shared = ColorProfileManager()

  /// Represents a color profile
  struct Profile: CustomStringConvertible {
    let url: URL
    let name: String

    var fileName: String { url.lastPathComponent }
    var description: String { "\(name) (\(fileName))" }
  }

  /// List all available color profiles in the system
  func listAvailableProfiles() -> [Profile] {
    var profiles: [Profile] = []
    let profileDirs = [
      "/System/Library/ColorSync/Profiles",
      "/Library/ColorSync/Profiles",
      NSHomeDirectory() + "/Library/ColorSync/Profiles",
    ]

    for dir in profileDirs {
      let dirURL = URL(fileURLWithPath: dir)
      guard let enumerator = FileManager.default.enumerator(at: dirURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }

      while let fileURL = enumerator.nextObject() as? URL {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "icc" || ext == "icm" || ext == "colorprofile" {
          let name = fileURL.deletingPathExtension().lastPathComponent
          profiles.append(Profile(url: fileURL, name: name))
        }
      }
    }

    return profiles.sorted { $0.name < $1.name }
  }

  /// Install a color profile for a display.
  ///
  /// Copies the ICC profile to `~/Library/ColorSync/Profiles/` so it becomes available
  /// in System Preferences > Displays > Color. macOS does not provide a stable public API
  /// to programmatically assign a profile to a specific display, so the user may need to
  /// select it manually in Display settings after installation.
  @discardableResult
  func setProfile(for displayID: CGDirectDisplayID, profilePath: String) -> Bool {
    guard FileManager.default.fileExists(atPath: profilePath) else {
      os_log("ColorProfileManager: profile not found at %{public}@", type: .error, profilePath)
      return false
    }

    os_log("ColorProfileManager: installing profile %{public}@ for display %{public}@",
           type: .info, profilePath, String(displayID))

    let userProfileDir = NSHomeDirectory() + "/Library/ColorSync/Profiles"
    let fm = FileManager.default
    if !fm.fileExists(atPath: userProfileDir) {
      try? fm.createDirectory(atPath: userProfileDir, withIntermediateDirectories: true)
    }

    let sourceURL = URL(fileURLWithPath: profilePath)
    let destURL = URL(fileURLWithPath: userProfileDir).appendingPathComponent(sourceURL.lastPathComponent)
    do {
      if fm.fileExists(atPath: destURL.path) {
        try fm.removeItem(at: destURL)
      }
      try fm.copyItem(at: sourceURL, to: destURL)
      os_log("ColorProfileManager: profile installed to %{public}@", type: .info, destURL.path)
      os_log("ColorProfileManager: select in System Preferences > Displays > Color", type: .info)
      return true
    } catch {
      os_log("ColorProfileManager: failed to copy profile: %{public}@", type: .error, error.localizedDescription)
      return false
    }
  }

  /// Get profile names that match common display profile naming conventions
  func findProfilesForDisplay(name: String) -> [Profile] {
    let all = listAvailableProfiles()
    let lowered = name.lowercased()
    return all.filter { $0.name.lowercased().contains(lowered) }
  }
}
