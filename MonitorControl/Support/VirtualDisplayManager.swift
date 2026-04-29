//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import CoreGraphics
import Foundation
import os.log

/// Manages virtual (dummy) displays for headless Macs and display emulation.
///
/// Virtual displays are useful for:
/// - Headless Mac setups (Mac Mini servers) that need a display for screen sharing
/// - Testing multi-monitor configurations
/// - Creating mirror targets for AirPlay or Sidecar testing
///
/// Virtual display creation uses NSAppleScript to call the `system_profiler` or
/// the `displayplacer` approach. For actual creation of headless virtual screens,
/// macOS 14+ CGVirtualDisplay APIs are needed, but they aren't in the public SDK
/// for deployment targets < macOS 14.
///
/// This class provides display enumeration, info, and management utilities
/// that work across all supported macOS versions.
class VirtualDisplayManager {
  static let shared = VirtualDisplayManager()

  /// Track active virtual display IDs that we're managing
  private var managedDisplayIDs: Set<CGDirectDisplayID> = []

  // MARK: - Display Enumeration

  /// Get all currently online displays (physical + virtual)
  func getAllOnlineDisplays() -> [CGDirectDisplayID] {
    var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
    var displayCount: UInt32 = 0
    CGGetOnlineDisplayList(16, &displayIDs, &displayCount)
    return Array(displayIDs.prefix(Int(displayCount)))
  }

  /// Get all currently active displays (those with frame buffers)
  func getAllActiveDisplays() -> [CGDirectDisplayID] {
    var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
    var displayCount: UInt32 = 0
    CGGetActiveDisplayList(16, &displayIDs, &displayCount)
    return Array(displayIDs.prefix(Int(displayCount)))
  }

  /// Get only external displays (non-builtin)
  func getExternalDisplays() -> [CGDirectDisplayID] {
    return getAllActiveDisplays().filter { CGDisplayIsBuiltin($0) == 0 }
  }

  /// Check if a specific display is virtual/dummy
  func isVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
    return DisplayManager.isVirtual(displayID: displayID)
  }

  /// Check if a specific display is a dummy plug
  func isDummyDisplay(_ displayID: CGDirectDisplayID) -> Bool {
    return DisplayManager.isDummy(displayID: displayID)
  }

  // MARK: - Display Info

  /// Get display info summary for a display ID
  func getDisplayInfo(displayID: CGDirectDisplayID) -> DisplayInfo {
    let width = CGDisplayPixelsWide(displayID)
    let height = CGDisplayPixelsHigh(displayID)
    let isActive = CGDisplayIsActive(displayID) != 0
    let isOnline = CGDisplayIsOnline(displayID) != 0
    let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
    let isMirrored = CGDisplayIsInMirrorSet(displayID) != 0
    let mirrorOf = CGDisplayMirrorsDisplay(displayID)
    let rotation = CGDisplayRotation(displayID)
    let vendorID = CGDisplayVendorNumber(displayID)
    let modelID = CGDisplayModelNumber(displayID)
    let serialNumber = CGDisplaySerialNumber(displayID)

    return DisplayInfo(
      displayID: displayID,
      width: width,
      height: height,
      isActive: isActive,
      isOnline: isOnline,
      isBuiltin: isBuiltin,
      isVirtual: DisplayManager.isVirtual(displayID: displayID),
      isDummy: DisplayManager.isDummy(displayID: displayID),
      isMirrored: isMirrored,
      mirrorOf: mirrorOf,
      rotation: rotation,
      vendorID: vendorID,
      modelID: modelID,
      serialNumber: serialNumber
    )
  }

  struct DisplayInfo {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    let isActive: Bool
    let isOnline: Bool
    let isBuiltin: Bool
    let isVirtual: Bool
    let isDummy: Bool
    let isMirrored: Bool
    let mirrorOf: CGDirectDisplayID
    let rotation: Double
    let vendorID: UInt32
    let modelID: UInt32
    let serialNumber: UInt32

    var summary: String {
      var parts: [String] = []
      parts.append("Display \(displayID): \(width)x\(height)")
      if isBuiltin { parts.append("(Built-in)") }
      if isVirtual { parts.append("(Virtual)") }
      if isDummy { parts.append("(Dummy)") }
      if isMirrored { parts.append("(Mirrored → \(mirrorOf))") }
      if rotation != 0 { parts.append("(Rotated \(Int(rotation))°)") }
      parts.append(isActive ? "[Active]" : "[Inactive]")
      parts.append(isOnline ? "[Online]" : "[Offline]")
      return parts.joined(separator: " ")
    }
  }

  // MARK: - Virtual Display via displayplacer (if available)

  /// Create a virtual display using the `displayplacer` tool (Homebrew)
  /// Returns true if displayplacer is available and the command succeeded
  func createViaDisplayplacer(width: Int, height: Int, hz: Int = 60) -> Bool {
    let path = "/opt/homebrew/bin/displayplacer"
    guard FileManager.default.fileExists(atPath: path) else {
      os_log("VirtualDisplayManager: displayplacer not found at %{public}@", type: .info, path)
      return false
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["res:\(width)x\(height) hz:\(hz) scaling:on"]

    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      os_log("VirtualDisplayManager: displayplacer failed: %{public}@", type: .error, error.localizedDescription)
      return false
    }
  }

  // MARK: - Display Count Tracking

  /// Get count of connected displays by type
  func getDisplayCounts() -> (total: Int, external: Int, builtin: Int, virtual: Int, dummy: Int) {
    let all = getAllActiveDisplays()
    var external = 0, builtin = 0, virtual = 0, dummy = 0
    for displayID in all {
      if CGDisplayIsBuiltin(displayID) != 0 {
        builtin += 1
      } else {
        external += 1
      }
      if DisplayManager.isVirtual(displayID: displayID) { virtual += 1 }
      if DisplayManager.isDummy(displayID: displayID) { dummy += 1 }
    }
    return (all.count, external, builtin, virtual, dummy)
  }
}
