//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import CoreGraphics
import Foundation
import IOKit
import os.log

/// Manages display connections: mirroring, rotation, and display enable/disable.
///
/// macOS does not provide a public API to electrically "disconnect" a display,
/// but we can achieve similar effects through:
/// - Mirroring a display onto the main display (effectively hiding it)
/// - Setting brightness to 0 + disabling the display via DPMS (power off via DDC)
/// - Capturing a display (blanks it, takes exclusive control)
///
/// For true disconnect/reconnect of external displays, DDC power control
/// is the most reliable approach (VCP 0xD6).
class DisplayConnectionManager {
  static let shared = DisplayConnectionManager()

  // MARK: - Display Mirroring

  /// Mirror a display to another display
  /// - Parameters:
  ///   - displayID: The display to be mirrored (slave)
  ///   - targetID: The display to mirror onto (master). Use kCGNullDirectDisplay to unmirror.
  func setMirror(displayID: CGDirectDisplayID, mirrorOf targetID: CGDirectDisplayID) -> Bool {
    var config: CGDisplayConfigRef?
    let beginErr = CGBeginDisplayConfiguration(&config)
    guard beginErr == .success, let config = config else {
      os_log("DisplayConnectionManager: failed to begin display configuration: %{public}@",
             type: .error, String(beginErr.rawValue))
      return false
    }

    CGConfigureDisplayMirrorOfDisplay(config, displayID, targetID)

    let completeErr = CGCompleteDisplayConfiguration(config, .permanently)
    // Note: config ref is consumed by CGCompleteDisplayConfiguration — do NOT call Cancel after
    guard completeErr == .success else {
      os_log("DisplayConnectionManager: failed to complete mirror configuration: %{public}@",
             type: .error, String(completeErr.rawValue))
      return false
    }

    let action = targetID == kCGNullDirectDisplay ? "unmirrored" : "mirrored to \(targetID)"
    os_log("DisplayConnectionManager: display %{public}@ %{public}@",
           type: .info, String(displayID), action)
    return true
  }

  /// Unmirror a display (restore to independent)
  func unmirror(displayID: CGDirectDisplayID) -> Bool {
    return setMirror(displayID: displayID, mirrorOf: kCGNullDirectDisplay)
  }

  /// Check if a display is currently mirrored
  func isMirrored(displayID: CGDirectDisplayID) -> Bool {
    return CGDisplayIsInMirrorSet(displayID) != 0
  }

  /// Get the display that a mirrored display is mirroring
  func getMirrorTarget(displayID: CGDirectDisplayID) -> CGDirectDisplayID {
    return CGDisplayMirrorsDisplay(displayID)
  }

  // MARK: - Display Capture (Blank/Exclusive)

  /// Capture a display (blanks it, takes exclusive control)
  /// This effectively "disables" the display visually.
  func captureDisplay(_ displayID: CGDirectDisplayID) -> Bool {
    let err = CGDisplayCapture(displayID)
    guard err == .success else {
      os_log("DisplayConnectionManager: failed to capture display %{public}@: %{public}@",
             type: .error, String(displayID), String(err.rawValue))
      return false
    }
    os_log("DisplayConnectionManager: captured display %{public}@", type: .info, String(displayID))
    capturedDisplays.insert(displayID)
    return true
  }

  /// Release a captured display (restore normal rendering)
  func releaseDisplay(_ displayID: CGDirectDisplayID) -> Bool {
    let err = CGDisplayRelease(displayID)
    guard err == .success else {
      os_log("DisplayConnectionManager: failed to release display %{public}@: %{public}@",
             type: .error, String(displayID), String(err.rawValue))
      return false
    }
    os_log("DisplayConnectionManager: released display %{public}@", type: .info, String(displayID))
    capturedDisplays.remove(displayID)
    return true
  }

  /// Track captured displays ourselves since CGDisplayIsCaptured was removed
  private var capturedDisplays: Set<CGDirectDisplayID> = []

  /// Check if a display is captured (by us)
  func isCaptured(_ displayID: CGDirectDisplayID) -> Bool {
    return capturedDisplays.contains(displayID)
  }

  // MARK: - Display Rotation

  /// Set the rotation of a display.
  ///
  /// macOS does not provide a public API for setting display rotation.
  /// `CGDisplayRotation()` only reads rotation; setting requires private IOKit
  /// framebuffer APIs (`IOFBSetTransform`) which are not stable across macOS versions.
  /// If `displayplacer` is installed (brew install displayplacer), we use that instead.
  func setRotation(displayID: CGDirectDisplayID, angle: Int) -> Bool {
    guard [0, 90, 180, 270].contains(angle) else {
      os_log("DisplayConnectionManager: invalid rotation angle %{public}@", type: .error, String(angle))
      return false
    }

    // Try displayplacer CLI if available
    if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/displayplacer") ||
       FileManager.default.fileExists(atPath: "/usr/local/bin/displayplacer") {
      let path = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/displayplacer")
        ? "/opt/homebrew/bin/displayplacer"
        : "/usr/local/bin/displayplacer"
      let process = Process()
      process.executableURL = URL(fileURLWithPath: path)
      process.arguments = ["\"id:\(displayID) degree:\(angle)\""]
      do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
          os_log("DisplayConnectionManager: set rotation to %{public}@ via displayplacer", type: .info, String(angle))
          return true
        }
      } catch {
        os_log("DisplayConnectionManager: displayplacer failed: %{public}@", type: .error, error.localizedDescription)
      }
    }

    os_log("DisplayConnectionManager: rotation requires 'displayplacer' CLI (brew install displayplacer)", type: .info)
    return false
  }

  /// Get current rotation of a display
  func getRotation(displayID: CGDirectDisplayID) -> Int {
    return Int(CGDisplayRotation(displayID))
  }

  // MARK: - DDC Power Control (True Disconnect Equivalent)

  /// Power off a display via DDC (VCP 0xD6) - the closest to "disconnecting" an external monitor
  func powerOffDisplay(_ display: OtherDisplay) {
    display.setPowerMode(.off)
    os_log("DisplayConnectionManager: powered off display %{public}@ via DDC", type: .info, display.name)
  }

  /// Power on a display via DDC (VCP 0xD6)
  func powerOnDisplay(_ display: OtherDisplay) {
    display.setPowerMode(.on)
    os_log("DisplayConnectionManager: powered on display %{public}@ via DDC", type: .info, display.name)
  }

  // MARK: - Display Origin/Position

  /// Move a display to a specific position in the display arrangement
  func setDisplayOrigin(displayID: CGDirectDisplayID, x: Int32, y: Int32) -> Bool {
    var config: CGDisplayConfigRef?
    let beginErr = CGBeginDisplayConfiguration(&config)
    guard beginErr == .success, let config = config else {
      os_log("DisplayConnectionManager: failed to begin config for origin change: %{public}@",
             type: .error, String(beginErr.rawValue))
      return false
    }

    CGConfigureDisplayOrigin(config, displayID, x, y)

    let completeErr = CGCompleteDisplayConfiguration(config, .permanently)
    // Note: config ref is consumed by CGCompleteDisplayConfiguration — do NOT call Cancel after
    guard completeErr == .success else {
      os_log("DisplayConnectionManager: failed to complete origin change: %{public}@",
             type: .error, String(completeErr.rawValue))
      return false
    }

    os_log("DisplayConnectionManager: moved display %{public}@ to (%{public}@, %{public}@)",
           type: .info, String(displayID), String(x), String(y))
    return true
  }

  /// Get current display bounds (position + size)
  func getDisplayBounds(displayID: CGDirectDisplayID) -> CGRect {
    return CGDisplayBounds(displayID)
  }

  // MARK: - Convenience

  /// Get a summary of the current display arrangement
  func getArrangementSummary() -> String {
    let allDisplays = VirtualDisplayManager.shared.getAllActiveDisplays()
    var lines: [String] = ["Display Arrangement:"]
    for displayID in allDisplays {
      let bounds = getDisplayBounds(displayID: displayID)
      let mirrored = isMirrored(displayID: displayID) ? " [Mirrored → \(getMirrorTarget(displayID: displayID))]" : ""
      let rotation = getRotation(displayID: displayID)
      let rotStr = rotation != 0 ? " [Rotated \(rotation)°]" : ""
      let name = DisplayManager.getDisplayRawNameByID(displayID: displayID)
      lines.append("  \(displayID) (\(name)): \(Int(bounds.width))x\(Int(bounds.height)) at (\(Int(bounds.origin.x)),\(Int(bounds.origin.y)))\(mirrored)\(rotStr)")
    }
    return lines.joined(separator: "\n")
  }
}
