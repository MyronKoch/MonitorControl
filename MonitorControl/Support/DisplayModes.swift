//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import CoreGraphics
import Foundation
import os.log

/// Manages display modes (resolution, refresh rate, HiDPI) for connected displays.
/// Uses CoreGraphics private APIs (CGSGetNumberOfDisplayModes, CGSGetDisplayModeDescriptionOfLength)
/// to enumerate all available modes, including HiDPI modes.
class DisplayModes {
  static let shared = DisplayModes()

  /// Represents a single display mode
  struct Mode: CustomStringConvertible {
    let modeNumber: Int32
    let width: Int
    let height: Int
    let refreshRate: Double
    let bitDepth: Int
    let isHiDPI: Bool
    let ioFlags: UInt32

    var description: String {
      let hiDPISuffix = isHiDPI ? " (HiDPI)" : ""
      return "\(width)x\(height) @ \(String(format: "%.0f", refreshRate))Hz \(bitDepth)bit\(hiDPISuffix)"
    }

    var resolution: String {
      "\(width)x\(height)"
    }
  }

  // MARK: - CoreGraphics Private API Declarations

  /// Get all available modes for a display
  func getAvailableModes(for displayID: CGDirectDisplayID) -> [Mode] {
    var modes: [Mode] = []

    // Use public CGDisplayCopyAllDisplayModes with kCGDisplayShowDuplicateLowResolutionModes
    let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    guard let modeList = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
      return modes
    }

    for (index, mode) in modeList.enumerated() {
      let displayMode = Mode(
        modeNumber: Int32(index),
        width: mode.width,
        height: mode.height,
        refreshRate: mode.refreshRate,
        bitDepth: 32,
        isHiDPI: mode.pixelWidth > mode.width,
        ioFlags: mode.ioFlags
      )
      modes.append(displayMode)
    }

    return modes.sorted { ($0.width, $0.height, $0.refreshRate) > ($1.width, $1.height, $1.refreshRate) }
  }

  /// Get unique resolutions available for a display
  func getAvailableResolutions(for displayID: CGDirectDisplayID) -> [(width: Int, height: Int, isHiDPI: Bool)] {
    let modes = getAvailableModes(for: displayID)
    var seen = Set<String>()
    var resolutions: [(width: Int, height: Int, isHiDPI: Bool)] = []

    for mode in modes {
      let key = "\(mode.width)x\(mode.height)_\(mode.isHiDPI)"
      if !seen.contains(key) {
        seen.insert(key)
        resolutions.append((mode.width, mode.height, mode.isHiDPI))
      }
    }

    return resolutions.sorted { ($0.width, $0.height) > ($1.width, $1.height) }
  }

  /// Get available refresh rates for a specific resolution
  func getAvailableRefreshRates(for displayID: CGDirectDisplayID, width: Int, height: Int) -> [Double] {
    let modes = getAvailableModes(for: displayID)
    let rates = Set(modes.filter { $0.width == width && $0.height == height }.map { $0.refreshRate })
    return rates.sorted(by: >)
  }

  /// Get the current display mode
  func getCurrentMode(for displayID: CGDirectDisplayID) -> Mode? {
    guard let currentMode = CGDisplayCopyDisplayMode(displayID) else { return nil }
    return Mode(
      modeNumber: 0,
      width: currentMode.width,
      height: currentMode.height,
      refreshRate: currentMode.refreshRate,
      bitDepth: 32,
      isHiDPI: currentMode.pixelWidth > currentMode.width,
      ioFlags: currentMode.ioFlags
    )
  }

  /// Set a display to a specific mode
  /// - Returns: true if the mode was set successfully
  @discardableResult
  func setMode(for displayID: CGDirectDisplayID, width: Int, height: Int, refreshRate: Double? = nil, hiDPI: Bool? = nil) -> Bool {
    let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    guard let modeList = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
      os_log("DisplayModes: failed to get mode list for display %{public}@", type: .error, String(displayID))
      return false
    }

    // Find matching mode
    let targetMode = modeList.first { mode in
      guard mode.width == width, mode.height == height else { return false }
      if let targetRate = refreshRate, abs(mode.refreshRate - targetRate) > 0.5 { return false }
      if let targetHiDPI = hiDPI, (mode.pixelWidth > mode.width) != targetHiDPI { return false }
      return true
    }

    guard let mode = targetMode else {
      os_log("DisplayModes: no matching mode found for %{public}@x%{public}@ @ %{public}@Hz",
             type: .error, String(width), String(height), String(refreshRate ?? 0))
      return false
    }

    var config: CGDisplayConfigRef?
    let beginErr = CGBeginDisplayConfiguration(&config)
    guard beginErr == .success, let config = config else {
      os_log("DisplayModes: failed to begin display configuration", type: .error)
      return false
    }

    let configErr = CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
    guard configErr == .success else {
      os_log("DisplayModes: failed to configure display mode", type: .error)
      CGCancelDisplayConfiguration(config)
      return false
    }

    let completeErr = CGCompleteDisplayConfiguration(config, .permanently)
    if completeErr == .success {
      os_log("DisplayModes: set display %{public}@ to %{public}@x%{public}@ @ %{public}@Hz",
             type: .info, String(displayID), String(width), String(height), String(format: "%.0f", mode.refreshRate))
      return true
    } else {
      os_log("DisplayModes: failed to complete display configuration", type: .error)
      return false
    }
  }

  /// Set only the refresh rate for a display (keeping current resolution)
  @discardableResult
  func setRefreshRate(for displayID: CGDirectDisplayID, refreshRate: Double) -> Bool {
    guard let current = getCurrentMode(for: displayID) else { return false }
    return setMode(for: displayID, width: current.width, height: current.height, refreshRate: refreshRate)
  }
}
