//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation
import os.log

/// DDC-based color adjustment controls for external monitors.
/// Uses standard VCP codes for video gain (RGB), hue, saturation, and color preset.
///
/// VCP Codes used:
/// - 0x16 (videoGainRed), 0x18 (videoGainGreen), 0x1A (videoGainBlue) - RGB gain
/// - 0x9B-0xA0 (sixAxisHueControl*) - Hue per channel
/// - 0x59-0x5E (sixAxisSaturationControl*) - Saturation per channel
/// - 0x14 (selectColorPreset) - Color preset (sRGB, 5000K, 6500K, 9300K, etc.)
/// - 0x90 (hue) - Global hue
/// - 0x8A (colorSaturation) - Global saturation
class ColorAdjustments {
  static let shared = ColorAdjustments()

  /// Standard color preset values for VCP 0x14
  enum ColorPreset: UInt16, CaseIterable {
    case sRGB = 1
    case displayNative = 2
    case temperature4000K = 3
    case temperature5000K = 4
    case temperature6500K = 5
    case temperature7500K = 6
    case temperature8200K = 7
    case temperature9300K = 8
    case temperature10000K = 9
    case temperature11500K = 10
    case userDefined1 = 11
    case userDefined2 = 12
    case userDefined3 = 13

    var displayName: String {
      switch self {
      case .sRGB: return "sRGB"
      case .displayNative: return "Display Native"
      case .temperature4000K: return "4000K"
      case .temperature5000K: return "5000K"
      case .temperature6500K: return "6500K (D65)"
      case .temperature7500K: return "7500K"
      case .temperature8200K: return "8200K"
      case .temperature9300K: return "9300K"
      case .temperature10000K: return "10000K"
      case .temperature11500K: return "11500K"
      case .userDefined1: return "User 1"
      case .userDefined2: return "User 2"
      case .userDefined3: return "User 3"
      }
    }
  }

  // MARK: - RGB Gain Controls

  /// Set the red video gain (0.0-1.0)
  func setRedGain(_ value: Float, for display: OtherDisplay) {
    guard !display.isSw() else { return }
    display.writeDDCValues(command: .videoGainRed, value: display.convValueToDDC(for: .videoGainRed, from: value))
    display.savePref(value, for: .videoGainRed)
  }

  /// Set the green video gain (0.0-1.0)
  func setGreenGain(_ value: Float, for display: OtherDisplay) {
    guard !display.isSw() else { return }
    display.writeDDCValues(command: .videoGainGreen, value: display.convValueToDDC(for: .videoGainGreen, from: value))
    display.savePref(value, for: .videoGainGreen)
  }

  /// Set the blue video gain (0.0-1.0)
  func setBlueGain(_ value: Float, for display: OtherDisplay) {
    guard !display.isSw() else { return }
    display.writeDDCValues(command: .videoGainBlue, value: display.convValueToDDC(for: .videoGainBlue, from: value))
    display.savePref(value, for: .videoGainBlue)
  }

  /// Set all RGB gains at once
  func setRGBGain(red: Float, green: Float, blue: Float, for display: OtherDisplay) {
    setRedGain(red, for: display)
    setGreenGain(green, for: display)
    setBlueGain(blue, for: display)
  }

  // MARK: - Global Hue and Saturation

  /// Set global hue (VCP 0x90)
  func setHue(_ value: Float, for display: OtherDisplay) {
    guard !display.isSw() else { return }
    display.writeDDCValues(command: .hue, value: display.convValueToDDC(for: .hue, from: value))
    display.savePref(value, for: .hue)
  }

  /// Set global color saturation (VCP 0x8A)
  func setSaturation(_ value: Float, for display: OtherDisplay) {
    guard !display.isSw() else { return }
    display.writeDDCValues(command: .colorSaturation, value: display.convValueToDDC(for: .colorSaturation, from: value))
    display.savePref(value, for: .colorSaturation)
  }

  // MARK: - Color Preset

  /// Set a color preset (VCP 0x14)
  func setColorPreset(_ preset: ColorPreset, for display: OtherDisplay) {
    guard !display.isSw() else { return }
    display.writeDDCValues(command: .selectColorPreset, value: preset.rawValue)
    os_log("Set color preset to %{public}@ for %{public}@", type: .info, preset.displayName, display.name)
  }

  // MARK: - Sharpness

  /// Set display sharpness (VCP 0x87)
  func setSharpness(_ value: Float, for display: OtherDisplay) {
    guard !display.isSw() else { return }
    display.writeDDCValues(command: .sharpness, value: display.convValueToDDC(for: .sharpness, from: value))
    display.savePref(value, for: .sharpness)
  }

  // MARK: - Factory Reset

  /// Reset display color to factory defaults (VCP 0x08)
  func resetToFactory(for display: OtherDisplay) {
    guard !display.isSw() else { return }
    display.writeDDCValues(command: .restoreFactoryColorDefaults, value: 1)
    os_log("Reset color to factory defaults for %{public}@", type: .info, display.name)
  }
}
