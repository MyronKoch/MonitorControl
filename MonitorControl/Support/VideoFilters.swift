//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import CoreGraphics
import Foundation
import os.log

/// Software-based video filters for external displays.
///
/// Uses CoreGraphics gamma tables to apply color correction filters
/// without requiring monitor DDC support. Filters are composable.
///
/// Available filters:
/// - Blue light reduction (warm tint, like Night Shift)
/// - Grayscale (accessibility feature)
/// - Color inversion (accessibility feature)
/// - Custom color tint (overlay a color)
/// - Brightness boost/reduction via gamma
/// - Contrast adjustment via gamma curve
class VideoFilters {
  static let shared = VideoFilters()

  /// Active filters per display
  private var activeFilters: [CGDirectDisplayID: [Filter]] = [:]

  // MARK: - Filter Types

  enum Filter: Equatable {
    case blueLightReduction(intensity: Float)   // 0.0-1.0
    case grayscale
    case invertColors
    case colorTint(red: Float, green: Float, blue: Float)  // multipliers 0.0-2.0
    case gammaAdjust(red: Float, green: Float, blue: Float)  // gamma values
    case contrastBoost(factor: Float)  // 0.5 = low contrast, 2.0 = high

    static func == (lhs: Filter, rhs: Filter) -> Bool {
      switch (lhs, rhs) {
      case (.grayscale, .grayscale): return true
      case (.invertColors, .invertColors): return true
      case let (.blueLightReduction(a), .blueLightReduction(b)): return a == b
      case let (.colorTint(r1, g1, b1), .colorTint(r2, g2, b2)): return r1 == r2 && g1 == g2 && b1 == b2
      case let (.gammaAdjust(r1, g1, b1), .gammaAdjust(r2, g2, b2)): return r1 == r2 && g1 == g2 && b1 == b2
      case let (.contrastBoost(a), .contrastBoost(b)): return a == b
      default: return false
      }
    }
  }

  // MARK: - Apply Filters

  /// Apply a filter to a display (additive — can have multiple)
  func applyFilter(_ filter: Filter, to displayID: CGDirectDisplayID) {
    if activeFilters[displayID] == nil {
      activeFilters[displayID] = []
    }
    activeFilters[displayID]?.append(filter)
    updateGamma(for: displayID)
    os_log("VideoFilters: applied filter to display %{public}@", type: .info, String(displayID))
  }

  /// Remove all filters from a display (restore per-display gamma)
  func removeAllFilters(from displayID: CGDirectDisplayID) {
    activeFilters.removeValue(forKey: displayID)
    restoreDefaultGamma(for: displayID)
    os_log("VideoFilters: removed all filters from display %{public}@", type: .info, String(displayID))
  }

  /// Remove a specific filter type from a display
  func removeFilter(_ filter: Filter, from displayID: CGDirectDisplayID) {
    activeFilters[displayID]?.removeAll { $0 == filter }
    if activeFilters[displayID]?.isEmpty == true {
      activeFilters.removeValue(forKey: displayID)
      restoreDefaultGamma(for: displayID)
    } else {
      updateGamma(for: displayID)
    }
  }

  /// Restore a single display's gamma to its default (avoids global CGDisplayRestoreColorSyncSettings)
  private func restoreDefaultGamma(for displayID: CGDirectDisplayID) {
    if let display = DisplayManager.shared.getAllDisplays().first(where: { $0.identifier == displayID }) {
      let sampleCount = display.defaultGammaTableSampleCount
      guard sampleCount > 0 else { return }
      CGSetDisplayTransferByTable(displayID, sampleCount,
                                 display.defaultGammaTableRed,
                                 display.defaultGammaTableGreen,
                                 display.defaultGammaTableBlue)
    }
  }

  /// Get active filters for a display
  func getFilters(for displayID: CGDirectDisplayID) -> [Filter] {
    return activeFilters[displayID] ?? []
  }

  // MARK: - Gamma Computation

  private func updateGamma(for displayID: CGDirectDisplayID) {
    let filters = activeFilters[displayID] ?? []
    guard !filters.isEmpty else { return }

    // Avoid touching displays with gamma avoidance preference
    if let display = DisplayManager.shared.getAllDisplays().first(where: { $0.identifier == displayID }),
       display.readPrefAsBool(key: .avoidGamma) {
      os_log("VideoFilters: skipping display %{public}@ (avoidGamma)", type: .info, String(displayID))
      return
    }

    let sampleCount: UInt32 = 256
    var red = (0 ..< Int(sampleCount)).map { CGGammaValue($0) / CGGammaValue(sampleCount - 1) }
    var green = red
    var blue = red

    // Compose all filters onto the gamma tables
    for filter in filters {
      switch filter {
      case let .blueLightReduction(intensity):
        for i in 0 ..< Int(sampleCount) {
          green[i] *= CGGammaValue(1.0 - intensity * 0.15)
          blue[i] *= CGGammaValue(1.0 - intensity * 0.45)
        }

      case .grayscale:
        for i in 0 ..< Int(sampleCount) {
          let luminance = 0.299 * red[i] + 0.587 * green[i] + 0.114 * blue[i]
          red[i] = luminance
          green[i] = luminance
          blue[i] = luminance
        }

      case .invertColors:
        for i in 0 ..< Int(sampleCount) {
          red[i] = 1.0 - red[i]
          green[i] = 1.0 - green[i]
          blue[i] = 1.0 - blue[i]
        }

      case let .colorTint(rMul, gMul, bMul):
        for i in 0 ..< Int(sampleCount) {
          red[i] = min(1.0, red[i] * CGGammaValue(rMul))
          green[i] = min(1.0, green[i] * CGGammaValue(gMul))
          blue[i] = min(1.0, blue[i] * CGGammaValue(bMul))
        }

      case let .gammaAdjust(rGamma, gGamma, bGamma):
        // Compose gamma onto existing curve (apply power to accumulated values, not a fresh ramp)
        for i in 0 ..< Int(sampleCount) {
          red[i] = pow(max(0, red[i]), 1.0 / CGGammaValue(rGamma))
          green[i] = pow(max(0, green[i]), 1.0 / CGGammaValue(gGamma))
          blue[i] = pow(max(0, blue[i]), 1.0 / CGGammaValue(bGamma))
        }

      case let .contrastBoost(factor):
        for i in 0 ..< Int(sampleCount) {
          red[i] = min(1.0, max(0.0, (red[i] - 0.5) * CGGammaValue(factor) + 0.5))
          green[i] = min(1.0, max(0.0, (green[i] - 0.5) * CGGammaValue(factor) + 0.5))
          blue[i] = min(1.0, max(0.0, (blue[i] - 0.5) * CGGammaValue(factor) + 0.5))
        }
      }
    }

    CGSetDisplayTransferByTable(displayID, sampleCount, red, green, blue)
  }
}
