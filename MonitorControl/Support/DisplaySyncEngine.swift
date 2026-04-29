//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import CoreGraphics
import Foundation
import os.log

/// Advanced display synchronization engine.
///
/// Goes beyond basic brightness sync to provide:
/// - Multi-property sync (brightness, contrast, volume, color temperature)
/// - Sync groups (pair specific displays together)
/// - Ratio-based sync (e.g., external at 80% of laptop brightness)
/// - Resolution sync (match resolutions proportionally)
/// - Scheduled sync (time-based brightness curves)
class DisplaySyncEngine {
  static let shared = DisplaySyncEngine()

  private let prefsKey = "MonitorControl.SyncGroups"
  private var syncTimers: [String: Timer] = [:]

  // MARK: - Sync Group Model

  struct SyncGroup: Codable {
    let name: String
    let sourceDisplayID: UInt32
    let targetDisplayIDs: [UInt32]
    let properties: [SyncProperty]
    let ratios: [String: Float]  // property name → ratio (1.0 = exact match)
    var enabled: Bool
  }

  enum SyncProperty: String, Codable, CaseIterable {
    case brightness
    case contrast
    case volume
    case colorTemperature
  }

  // MARK: - Immediate Sync

  /// Sync a specific property from source to all targets in a group
  func syncProperty(_ property: SyncProperty, from sourceDisplay: OtherDisplay, to targetDisplays: [OtherDisplay], ratio: Float = 1.0) {
    let command: Command
    switch property {
    case .brightness: command = .brightness
    case .contrast: command = .contrast
    case .volume: command = .audioSpeakerVolume
    case .colorTemperature: command = .colorTemperatureRequest
    }

    let sourceValue = sourceDisplay.readPrefAsFloat(for: command)
    let targetValue = min(1.0, max(0.0, sourceValue * ratio))

    for target in targetDisplays {
      guard !target.isSw(), !target.readPrefAsBool(key: .unavailableDDC, for: command) else { continue }
      target.writeDDCValues(command: command, value: target.convValueToDDC(for: command, from: targetValue))
      target.savePref(targetValue, for: command)
      os_log("SyncEngine: synced %{public}@ = %.2f (ratio %.2f) from %{public}@ to %{public}@",
             type: .info, property.rawValue, targetValue, ratio, sourceDisplay.name, target.name)
    }
  }

  /// Sync all properties in a sync group
  func syncGroup(_ group: SyncGroup) {
    guard group.enabled else { return }

    let allDisplays = DisplayManager.shared.getOtherDisplays()
    guard let source = allDisplays.first(where: { $0.identifier == group.sourceDisplayID }) else {
      os_log("SyncEngine: source display %{public}@ not found for group '%{public}@'",
             type: .error, String(group.sourceDisplayID), group.name)
      return
    }

    let targets = allDisplays.filter { group.targetDisplayIDs.contains($0.identifier) }
    guard !targets.isEmpty else {
      os_log("SyncEngine: no target displays found for group '%{public}@'", type: .error, group.name)
      return
    }

    for property in group.properties {
      let ratio = group.ratios[property.rawValue] ?? 1.0
      syncProperty(property, from: source, to: targets, ratio: ratio)
    }
  }

  /// Sync all enabled groups
  func syncAllGroups() {
    for group in loadGroups() where group.enabled {
      syncGroup(group)
    }
  }

  // MARK: - Resolution Sync

  /// Match resolution proportionally between displays.
  /// If the source is at its native resolution, set targets to their native.
  /// If the source is at a scaled resolution, find the closest proportional match on targets.
  func syncResolution(from sourceID: CGDirectDisplayID, to targetIDs: [CGDirectDisplayID]) {
    guard let sourceMode = CGDisplayCopyDisplayMode(sourceID) else { return }
    let sourceWidth = sourceMode.width
    let sourceHeight = sourceMode.height

    // Get source native resolution
    let sourceModes = DisplayModes.shared.getAvailableModes(for: sourceID)
    let sourceNative = sourceModes.max(by: { $0.width * $0.height < $1.width * $1.height })

    guard let sourceNative = sourceNative else { return }
    let scaleRatio = Float(sourceWidth) / Float(sourceNative.width)

    for targetID in targetIDs {
      let targetModes = DisplayModes.shared.getAvailableModes(for: targetID)
      guard let targetNative = targetModes.max(by: { $0.width * $0.height < $1.width * $1.height }) else { continue }

      let desiredWidth = Int(Float(targetNative.width) * scaleRatio)
      let desiredHeight = Int(Float(targetNative.height) * scaleRatio)

      // Find closest available mode
      let closest = targetModes.min(by: {
        abs($0.width - desiredWidth) + abs($0.height - desiredHeight) <
          abs($1.width - desiredWidth) + abs($1.height - desiredHeight)
      })

      if let closest = closest {
        _ = DisplayModes.shared.setMode(for: targetID, width: closest.width, height: closest.height)
        os_log("SyncEngine: synced resolution to %{public}@x%{public}@ on display %{public}@",
               type: .info, String(closest.width), String(closest.height), String(targetID))
      }
    }
  }

  // MARK: - Scheduled Brightness Curve

  struct BrightnessSchedulePoint: Codable {
    let hour: Int      // 0-23
    let minute: Int    // 0-59
    let brightness: Float  // 0.0-1.0
  }

  /// Start a scheduled brightness curve that adjusts brightness throughout the day
  func startScheduledSync(displayIDs: [CGDirectDisplayID], schedule: [BrightnessSchedulePoint]) {
    // Ensure timer is scheduled on main thread (which has an active RunLoop)
    let schedule_block = { [weak self] in
      self?.stopScheduledSync()

      let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
        self?.applyScheduledBrightness(displayIDs: displayIDs, schedule: schedule)
      }
      self?.syncTimers["scheduled"] = timer

      // Apply immediately
      self?.applyScheduledBrightness(displayIDs: displayIDs, schedule: schedule)
      os_log("SyncEngine: started scheduled brightness sync for %{public}@ displays", type: .info, String(displayIDs.count))
    }

    if Thread.isMainThread {
      schedule_block()
    } else {
      DispatchQueue.main.async(execute: schedule_block)
    }
  }

  func stopScheduledSync() {
    syncTimers["scheduled"]?.invalidate()
    syncTimers.removeValue(forKey: "scheduled")
  }

  private func applyScheduledBrightness(displayIDs: [CGDirectDisplayID], schedule: [BrightnessSchedulePoint]) {
    guard schedule.count >= 2 else { return }

    let calendar = Calendar.current
    let now = Date()
    let currentMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)

    // Find the two surrounding schedule points
    let sorted = schedule.sorted { ($0.hour * 60 + $0.minute) < ($1.hour * 60 + $1.minute) }
    var before = sorted.last!
    var after = sorted.first!

    for i in 0 ..< sorted.count {
      let pointMinutes = sorted[i].hour * 60 + sorted[i].minute
      if pointMinutes <= currentMinutes {
        before = sorted[i]
        after = sorted[(i + 1) % sorted.count]
      }
    }

    // Interpolate brightness
    let beforeMinutes = before.hour * 60 + before.minute
    var afterMinutes = after.hour * 60 + after.minute
    if afterMinutes <= beforeMinutes { afterMinutes += 1440 }  // wrap around midnight

    var adjustedCurrent = currentMinutes
    if adjustedCurrent < beforeMinutes { adjustedCurrent += 1440 }

    let range = afterMinutes - beforeMinutes
    let progress = range > 0 ? Float(adjustedCurrent - beforeMinutes) / Float(range) : 0
    let brightness = before.brightness + (after.brightness - before.brightness) * progress

    // Apply to all displays
    let allDisplays = DisplayManager.shared.getOtherDisplays()
    for displayID in displayIDs {
      if let display = allDisplays.first(where: { $0.identifier == displayID }) {
        display.writeDDCValues(command: .brightness, value: display.convValueToDDC(for: .brightness, from: brightness))
        display.savePref(brightness, for: .brightness)
      }
    }
  }

  // MARK: - Group Persistence

  func loadGroups() -> [SyncGroup] {
    guard let data = UserDefaults.standard.data(forKey: prefsKey) else { return [] }
    do {
      return try JSONDecoder().decode([SyncGroup].self, from: data)
    } catch {
      os_log("SyncEngine: failed to decode groups: %{public}@", type: .error, error.localizedDescription)
      return []
    }
  }

  func saveGroups(_ groups: [SyncGroup]) {
    do {
      let data = try JSONEncoder().encode(groups)
      UserDefaults.standard.set(data, forKey: prefsKey)
    } catch {
      os_log("SyncEngine: failed to encode groups: %{public}@", type: .error, error.localizedDescription)
    }
  }

  func addGroup(_ group: SyncGroup) {
    var groups = loadGroups()
    groups.removeAll { $0.name == group.name }
    groups.append(group)
    saveGroups(groups)
  }

  func removeGroup(name: String) {
    var groups = loadGroups()
    groups.removeAll { $0.name == name }
    saveGroups(groups)
  }

  func toggleGroup(name: String, enabled: Bool) {
    var groups = loadGroups()
    if let index = groups.firstIndex(where: { $0.name == name }) {
      var group = groups[index]
      group = SyncGroup(name: group.name, sourceDisplayID: group.sourceDisplayID,
                        targetDisplayIDs: group.targetDisplayIDs, properties: group.properties,
                        ratios: group.ratios, enabled: enabled)
      groups[index] = group
      saveGroups(groups)
    }
  }
}
