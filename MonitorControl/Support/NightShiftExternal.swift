//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import CoreGraphics
import Foundation
import os.log

/// Night Shift simulation for external displays via gamma table manipulation.
/// Applies a warm color temperature shift by reducing blue and slightly reducing green channels.
///
/// This works on any display where MonitorControl can manipulate gamma tables,
/// providing a software-based Night Shift for TVs and external monitors that
/// macOS Night Shift doesn't support natively.
class NightShiftExternal {
  static let shared = NightShiftExternal()

  /// Color temperature in Kelvin (1000K = very warm/orange, 6500K = neutral, 9000K = cool/blue)
  private(set) var colorTemperatureK: Int = 6500
  private(set) var isEnabled: Bool = false
  private(set) var intensity: Float = 0.0 // 0.0 = neutral, 1.0 = maximum warmth

  /// Enable Night Shift for all external displays
  /// - Parameter intensity: 0.0 (neutral) to 1.0 (maximum warmth, ~2700K)
  func enable(intensity: Float = 0.5) {
    let clamped = max(0.0, min(1.0, intensity))
    self.intensity = clamped
    self.isEnabled = true
    self.colorTemperatureK = Int(6500 - clamped * 3800) // Maps 0.0→6500K, 1.0→2700K

    os_log("Night Shift: enabled at intensity %{public}@ (%{public}@K)", type: .info, String(format: "%.0f%%", clamped * 100), String(colorTemperatureK))

    applyToAllDisplays()
  }

  /// Disable Night Shift (restore neutral gamma)
  func disable() {
    self.isEnabled = false
    self.intensity = 0.0
    self.colorTemperatureK = 6500

    os_log("Night Shift: disabled", type: .info)

    // Restore each display's default gamma individually
    // (CGDisplayRestoreColorSyncSettings is global — would clobber all displays)
    for display in DisplayManager.shared.getAllDisplays() {
      if !display.isVirtual, !display.readPrefAsBool(key: .avoidGamma), !(display is AppleDisplay) {
        let sampleCount = display.defaultGammaTableSampleCount
        guard sampleCount > 0 else { continue }
        CGSetDisplayTransferByTable(display.identifier, sampleCount,
                                   display.defaultGammaTableRed,
                                   display.defaultGammaTableGreen,
                                   display.defaultGammaTableBlue)
      }
    }
  }

  /// Apply the current Night Shift settings to all displays
  func applyToAllDisplays() {
    guard isEnabled else { return }

    let (redMultiplier, greenMultiplier, blueMultiplier) = colorMultipliers(for: intensity)

    for display in DisplayManager.shared.getAllDisplays() {
      // Skip virtual displays and those set to avoid gamma manipulation
      guard !display.isVirtual, !display.readPrefAsBool(key: .avoidGamma) else { continue }

      // Only apply to external displays (not built-in, which has native Night Shift)
      if display is AppleDisplay {
        // Skip Apple displays - they have native Night Shift
        continue
      }

      applyGamma(to: display.identifier, red: redMultiplier, green: greenMultiplier, blue: blueMultiplier, defaultRed: display.defaultGammaTableRed, defaultGreen: display.defaultGammaTableGreen, defaultBlue: display.defaultGammaTableBlue, sampleCount: display.defaultGammaTableSampleCount)
    }
  }

  /// Calculate RGB multipliers for a given warmth intensity
  /// Based on color temperature approximation from ~6500K (neutral) to ~2700K (warm)
  private func colorMultipliers(for intensity: Float) -> (red: Float, green: Float, blue: Float) {
    // At intensity 0: all channels at 1.0 (neutral)
    // At intensity 1: red stays ~1.0, green drops to ~0.85, blue drops to ~0.55
    let red: Float = 1.0
    let green: Float = 1.0 - (intensity * 0.15)
    let blue: Float = 1.0 - (intensity * 0.45)
    return (red, green, blue)
  }

  /// Apply gamma multipliers to a specific display
  private func applyGamma(to displayID: CGDirectDisplayID, red: Float, green: Float, blue: Float, defaultRed: [CGGammaValue], defaultGreen: [CGGammaValue], defaultBlue: [CGGammaValue], sampleCount: UInt32) {
    guard sampleCount > 0 else { return }

    let gammaRed = defaultRed.map { $0 * CGGammaValue(red) }
    let gammaGreen = defaultGreen.map { $0 * CGGammaValue(green) }
    let gammaBlue = defaultBlue.map { $0 * CGGammaValue(blue) }

    CGSetDisplayTransferByTable(displayID, sampleCount, gammaRed, gammaGreen, gammaBlue)
  }

  /// Toggle Night Shift on/off
  func toggle(intensity: Float = 0.5) {
    if isEnabled {
      disable()
    } else {
      enable(intensity: intensity)
    }
  }
}
