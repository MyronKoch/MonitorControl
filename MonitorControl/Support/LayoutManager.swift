//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import CoreGraphics
import Foundation
import os.log

/// Manages display layout presets — saving and restoring display arrangements.
///
/// A layout preset captures:
/// - Display positions (origins)
/// - Resolutions and refresh rates
/// - Rotation angles
/// - Mirroring configuration
/// - Brightness and volume levels (for DDC displays)
///
/// Presets are stored in UserDefaults under "MonitorControl.Layouts".
class LayoutManager {
  static let shared = LayoutManager()

  private let prefsKey = "MonitorControl.Layouts"

  // MARK: - Layout Preset Model

  struct DisplayLayout: Codable {
    let displayID: UInt32
    let vendorID: UInt32
    let modelID: UInt32
    let originX: Int
    let originY: Int
    let width: Int
    let height: Int
    let refreshRate: Double
    let rotation: Int
    let mirrorOf: UInt32
    let brightness: Float?
    let volume: Float?
  }

  struct LayoutPreset: Codable {
    let name: String
    let createdAt: Date
    let displays: [DisplayLayout]
  }

  // MARK: - Save Layout

  /// Save the current display arrangement as a named preset
  func saveLayout(name: String) -> Bool {
    var displays: [DisplayLayout] = []

    let activeDisplays = VirtualDisplayManager.shared.getAllActiveDisplays()
    for displayID in activeDisplays {
      let bounds = CGDisplayBounds(displayID)
      let rotation = Int(CGDisplayRotation(displayID))
      let mirrorOf = CGDisplayMirrorsDisplay(displayID)
      let vendorID = CGDisplayVendorNumber(displayID)
      let modelID = CGDisplayModelNumber(displayID)

      // Try to get current mode info
      var refreshRate: Double = 0
      if let mode = CGDisplayCopyDisplayMode(displayID) {
        refreshRate = mode.refreshRate
      }

      // Try to get brightness/volume from MonitorControl's display model
      var brightness: Float?
      var volume: Float?
      if let display = DisplayManager.shared.getAllDisplays().first(where: { $0.identifier == displayID }) as? OtherDisplay {
        brightness = display.readPrefAsFloat(for: .brightness)
        volume = display.readPrefAsFloat(for: .audioSpeakerVolume)
      }

      displays.append(DisplayLayout(
        displayID: displayID,
        vendorID: vendorID,
        modelID: modelID,
        originX: Int(bounds.origin.x),
        originY: Int(bounds.origin.y),
        width: Int(bounds.width),
        height: Int(bounds.height),
        refreshRate: refreshRate,
        rotation: rotation,
        mirrorOf: mirrorOf,
        brightness: brightness,
        volume: volume
      ))
    }

    let preset = LayoutPreset(name: name, createdAt: Date(), displays: displays)

    // Load existing presets, add/update this one
    var presets = loadAllPresets()
    presets.removeAll { $0.name == name }
    presets.append(preset)

    return saveAllPresets(presets)
  }

  // MARK: - Restore Layout

  /// Restore a saved layout by name.
  /// Matches displays by vendor+model ID (since display IDs can change between sessions).
  func restoreLayout(name: String) -> Bool {
    guard let preset = loadPreset(name: name) else {
      os_log("LayoutManager: preset '%{public}@' not found", type: .error, name)
      return false
    }

    let activeDisplays = VirtualDisplayManager.shared.getAllActiveDisplays()

    // Build a mapping from saved display IDs to current display IDs (via vendor+model)
    var savedToCurrentID: [UInt32: CGDirectDisplayID] = [:]
    for savedDisplay in preset.displays {
      if let currentID = activeDisplays.first(where: {
        CGDisplayVendorNumber($0) == savedDisplay.vendorID && CGDisplayModelNumber($0) == savedDisplay.modelID
      }) {
        savedToCurrentID[savedDisplay.displayID] = currentID
      }
    }

    // Match saved displays to current displays by vendor+model
    for savedDisplay in preset.displays {
      guard let currentDisplayID = savedToCurrentID[savedDisplay.displayID] else {
        os_log("LayoutManager: display vendor=%{public}@ model=%{public}@ not found, skipping",
               type: .info, String(savedDisplay.vendorID), String(savedDisplay.modelID))
        continue
      }

      // Restore position
      _ = DisplayConnectionManager.shared.setDisplayOrigin(
        displayID: currentDisplayID,
        x: Int32(savedDisplay.originX),
        y: Int32(savedDisplay.originY)
      )

      // Restore resolution and refresh rate
      _ = DisplayModes.shared.setMode(
        for: currentDisplayID,
        width: savedDisplay.width,
        height: savedDisplay.height,
        refreshRate: savedDisplay.refreshRate > 0 ? savedDisplay.refreshRate : nil
      )

      // Restore mirroring — remap the saved mirrorOf ID to current ID
      if savedDisplay.mirrorOf != 0 {
        let remappedMirrorTarget = savedToCurrentID[savedDisplay.mirrorOf] ?? savedDisplay.mirrorOf
        _ = DisplayConnectionManager.shared.setMirror(displayID: currentDisplayID, mirrorOf: remappedMirrorTarget)
      }

      // Restore brightness/volume via DDC
      if let display = DisplayManager.shared.getAllDisplays().first(where: { $0.identifier == currentDisplayID }) as? OtherDisplay {
        if let brightness = savedDisplay.brightness {
          display.writeDDCValues(command: .brightness, value: display.convValueToDDC(for: .brightness, from: brightness))
        }
        if let volume = savedDisplay.volume {
          display.writeDDCValues(command: .audioSpeakerVolume, value: display.convValueToDDC(for: .audioSpeakerVolume, from: volume))
        }
      }
    }

    os_log("LayoutManager: restored layout '%{public}@'", type: .info, name)
    return true
  }

  // MARK: - Preset Management

  /// List all saved layout presets
  func listPresets() -> [LayoutPreset] {
    return loadAllPresets()
  }

  /// Delete a saved layout preset
  func deletePreset(name: String) -> Bool {
    var presets = loadAllPresets()
    let count = presets.count
    presets.removeAll { $0.name == name }
    guard presets.count < count else {
      os_log("LayoutManager: preset '%{public}@' not found for deletion", type: .error, name)
      return false
    }
    return saveAllPresets(presets)
  }

  /// Load a specific preset by name
  func loadPreset(name: String) -> LayoutPreset? {
    return loadAllPresets().first { $0.name == name }
  }

  // MARK: - Persistence

  private func loadAllPresets() -> [LayoutPreset] {
    guard let data = UserDefaults.standard.data(forKey: prefsKey) else { return [] }
    do {
      return try JSONDecoder().decode([LayoutPreset].self, from: data)
    } catch {
      os_log("LayoutManager: failed to decode presets: %{public}@", type: .error, error.localizedDescription)
      return []
    }
  }

  private func saveAllPresets(_ presets: [LayoutPreset]) -> Bool {
    do {
      let data = try JSONEncoder().encode(presets)
      UserDefaults.standard.set(data, forKey: prefsKey)
      return true
    } catch {
      os_log("LayoutManager: failed to encode presets: %{public}@", type: .error, error.localizedDescription)
      return false
    }
  }
}
