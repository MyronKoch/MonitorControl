//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import CoreGraphics
import Foundation
import os.log

/// Manages XDR/HDR brightness for displays that support it.
/// Apple XDR displays can exceed 500 nits (standard SDR max) up to ~1600 nits.
/// Uses CoreGraphics private APIs to control the extended brightness range.
///
/// For non-Apple displays, this class provides a software-based "HDR boost"
/// by temporarily increasing the gamma output curve.
class HDRBrightness {
  static let shared = HDRBrightness()

  /// Whether XDR brightness is currently enabled for any display
  private(set) var isXDREnabled: Bool = false

  /// The current XDR brightness multiplier (1.0 = SDR max, >1.0 = HDR)
  private(set) var xdrMultiplier: Float = 1.0

  // MARK: - Native XDR (Apple Displays)

  /// Check if a display supports native XDR
  func supportsNativeXDR(displayID: CGDirectDisplayID) -> Bool {
    // XDR displays have a potentialEDR headroom > 1.0
    if #available(macOS 12.0, *) {
      let screen = NSScreen.screens.first { $0.displayID == displayID }
      if let maxEDR = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue, maxEDR > 1.0 {
        return true
      }
    }
    return false
  }

  /// Get the maximum XDR brightness multiplier for a display
  func maxXDRMultiplier(displayID: CGDirectDisplayID) -> Float {
    if #available(macOS 12.0, *) {
      let screen = NSScreen.screens.first { $0.displayID == displayID }
      return Float(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0)
    }
    return 1.0
  }

  // MARK: - Software HDR Boost (External Displays)

  /// Apply a software brightness boost by modifying the gamma curve.
  /// Values > 1.0 create an "overdriven" gamma that appears brighter.
  /// This doesn't actually increase backlight brightness but can make
  /// the image appear brighter on displays with good panel brightness.
  func setSoftwareHDRBoost(displayID: CGDirectDisplayID, multiplier: Float) {
    let clamped = max(1.0, min(multiplier, 2.0))

    guard let display = DisplayManager.shared.getAllDisplays().first(where: { $0.identifier == displayID }) else {
      return
    }

    guard !display.isVirtual, !display.readPrefAsBool(key: .avoidGamma) else { return }

    let sampleCount = display.defaultGammaTableSampleCount
    guard sampleCount > 0 else { return }

    // Boost gamma by multiplier (clamped to 0-1 range per channel)
    let gammaRed = display.defaultGammaTableRed.map { min(1.0, $0 * CGGammaValue(clamped)) }
    let gammaGreen = display.defaultGammaTableGreen.map { min(1.0, $0 * CGGammaValue(clamped)) }
    let gammaBlue = display.defaultGammaTableBlue.map { min(1.0, $0 * CGGammaValue(clamped)) }

    CGSetDisplayTransferByTable(displayID, sampleCount, gammaRed, gammaGreen, gammaBlue)
    xdrMultiplier = clamped
    isXDREnabled = clamped > 1.0

    os_log("HDR boost: set multiplier %{public}@ for display %{public}@",
           type: .info, String(format: "%.2f", clamped), String(displayID))
  }

  /// Reset HDR boost to normal (restore per-display gamma, not global)
  func resetHDRBoost(displayID: CGDirectDisplayID) {
    guard let display = DisplayManager.shared.getAllDisplays().first(where: { $0.identifier == displayID }) else {
      return
    }
    let sampleCount = display.defaultGammaTableSampleCount
    guard sampleCount > 0 else { return }
    CGSetDisplayTransferByTable(displayID, sampleCount,
                               display.defaultGammaTableRed,
                               display.defaultGammaTableGreen,
                               display.defaultGammaTableBlue)
    xdrMultiplier = 1.0
    isXDREnabled = false
  }
}
