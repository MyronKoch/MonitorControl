//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation

// MARK: - Helpers (available to all code including URLSchemeHandler)

/// Find a single display by name (shared between App Intents and URL scheme).
/// Returns nil if a non-empty name is provided but no display matches.
func findDisplay(name: String) -> OtherDisplay? {
  let displays = DisplayManager.shared.getOtherDisplays()
  if name.isEmpty {
    return displays.first
  }
  return displays.first { display in
    let friendlyName = display.readPrefAsString(key: .friendlyName)
    let displayName = friendlyName.isEmpty ? display.name : friendlyName
    return displayName.lowercased().contains(name.lowercased())
  }
}

/// Find displays by name — supports "all" to target every connected display.
/// Returns empty array if a specific name is given but no display matches.
func findDisplays(name: String) -> [OtherDisplay] {
  let displays = DisplayManager.shared.getOtherDisplays()
  let lowered = name.lowercased().trimmingCharacters(in: .whitespaces)
  if lowered == "all" || lowered == "all displays" || lowered == "every display" {
    return displays
  }
  if name.isEmpty {
    return Array(displays.prefix(1))
  }
  return displays.filter { display in
    let friendlyName = display.readPrefAsString(key: .friendlyName)
    let displayName = friendlyName.isEmpty ? display.name : friendlyName
    return displayName.lowercased().contains(lowered)
  }
}

// MARK: - App Intents for macOS Shortcuts (requires macOS 13.0+)
// AppIntents framework requires macOS 13.0+ and its transitive dependencies
// (ExtensionFoundation, Network) are unavailable when targeting macOS 10.15.
// Enable by adding ENABLE_APP_INTENTS to Swift Active Compilation Conditions
// in Xcode build settings when the deployment target is raised to macOS 13.0+.

#if ENABLE_APP_INTENTS
import AppIntents
import os.log

// MARK: - Intent Errors

@available(macOS 13.0, *)
enum MonitorControlIntentError: Error, CustomLocalizedStringResourceConvertible {
  case displayNotFound(String)
  case noDisplaysConnected
  case invalidCommand(String)

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .displayNotFound(let name):
      return "Display '\(name)' not found"
    case .noDisplaysConnected:
      return "No external displays connected"
    case .invalidCommand(let reason):
      return "Command failed: \(reason)"
    }
  }
}

// MARK: - Shared Display Helpers

/// Shared logic for applying display adjustments, reducing duplication across intents.
@available(macOS 13.0, *)
enum DisplayActions {

  @MainActor
  static func setBrightness(_ value: Float, on displays: [OtherDisplay]) {
    if prefs.bool(forKey: PrefKey.masterBrightnessLocked.rawValue) {
      prefs.set(value, forKey: PrefKey.masterBrightnessValue.rawValue)
      menu.masterBrightnessSliderHandler?.setValue(value)
      menu.applyMasterBrightness(value: value)
      return
    }
    for display in displays {
      _ = display.setBrightness(value)
      display.savePref(value, for: .brightness)
      if let slider = display.sliderHandler[.brightness] {
        slider.setValue(value, displayID: display.identifier)
      }
    }
  }

  @MainActor
  static func setVolume(_ value: Float, on displays: [OtherDisplay]) {
    for display in displays where !display.isSw() && !display.readPrefAsBool(key: .unavailableDDC, for: .audioSpeakerVolume) {
      display.writeDDCValues(command: .audioSpeakerVolume, value: display.convValueToDDC(for: .audioSpeakerVolume, from: value))
      display.savePref(value, for: .audioSpeakerVolume)
      if let slider = display.sliderHandler[.audioSpeakerVolume] {
        slider.setValue(value, displayID: display.identifier)
      }
    }
  }

  @MainActor
  static func setContrast(_ value: Float, on displays: [OtherDisplay]) {
    for display in displays where !display.isSw() && !display.readPrefAsBool(key: .unavailableDDC, for: .contrast) {
      display.writeDDCValues(command: .contrast, value: display.convValueToDDC(for: .contrast, from: value))
      display.savePref(value, for: .contrast)
      if let slider = display.sliderHandler[.contrast] {
        slider.setValue(value, displayID: display.identifier)
      }
    }
  }

  /// Resolve displays from a name parameter, throwing descriptive errors on failure.
  static func resolveDisplays(name: String) throws -> [OtherDisplay] {
    let displays = findDisplays(name: name)
    if displays.isEmpty {
      if name.isEmpty {
        throw MonitorControlIntentError.noDisplaysConnected
      } else {
        throw MonitorControlIntentError.displayNotFound(name)
      }
    }
    return displays
  }

  /// Resolve a single display from a name parameter.
  static func resolveDisplay(name: String) throws -> OtherDisplay {
    if let display = findDisplay(name: name) {
      return display
    }
    if name.isEmpty {
      throw MonitorControlIntentError.noDisplaysConnected
    }
    throw MonitorControlIntentError.displayNotFound(name)
  }

  /// Clamp a user-provided 0-100 integer and convert to 0.0-1.0 float.
  static func clampAndNormalize(_ rawValue: Int) -> (clamped: Int, normalized: Float) {
    let clamped = max(0, min(rawValue, 100))
    return (clamped, Float(clamped) / 100.0)
  }
}

// MARK: - All-Displays Intents (optimized for Siri voice control)

@available(macOS 13.0, *)
struct SetAllDisplaysBrightnessIntent: AppIntent {
  static var title: LocalizedStringResource = "Set All Displays Brightness"
  static var description = IntentDescription("Set the brightness of all connected external displays at once")

  @Parameter(title: "Brightness", description: "Brightness level (0-100)")
  var brightness: Int

  func perform() async throws -> some IntentResult & ReturnsValue<Int> {
    let (clamped, value) = DisplayActions.clampAndNormalize(brightness)
    let displays = DisplayManager.shared.getOtherDisplays()
    guard !displays.isEmpty else { throw MonitorControlIntentError.noDisplaysConnected }
    await MainActor.run { DisplayActions.setBrightness(value, on: displays) }
    os_log("Siri: set all displays brightness to %{public}d%%", type: .info, clamped)
    return .result(value: clamped)
  }
}

@available(macOS 13.0, *)
struct SetAllDisplaysVolumeIntent: AppIntent {
  static var title: LocalizedStringResource = "Set All Displays Volume"
  static var description = IntentDescription("Set the volume of all connected external displays at once")

  @Parameter(title: "Volume", description: "Volume level (0-100)")
  var volume: Int

  func perform() async throws -> some IntentResult & ReturnsValue<Int> {
    let (clamped, value) = DisplayActions.clampAndNormalize(volume)
    let displays = DisplayManager.shared.getOtherDisplays()
    guard !displays.isEmpty else { throw MonitorControlIntentError.noDisplaysConnected }
    await MainActor.run { DisplayActions.setVolume(value, on: displays) }
    os_log("Siri: set all displays volume to %{public}d%%", type: .info, clamped)
    return .result(value: clamped)
  }
}

@available(macOS 13.0, *)
struct PowerOffAllDisplaysIntent: AppIntent {
  static var title: LocalizedStringResource = "Turn Off All Displays"
  static var description = IntentDescription("Power off all connected external displays via DDC")

  func perform() async throws -> some IntentResult {
    let displays = DisplayManager.shared.getOtherDisplays()
    guard !displays.isEmpty else { throw MonitorControlIntentError.noDisplaysConnected }
    await MainActor.run {
      for display in displays where !display.isSw() {
        display.setPowerMode(.off)
      }
    }
    os_log("Siri: powered off all displays", type: .info)
    return .result()
  }
}

@available(macOS 13.0, *)
struct PowerOnAllDisplaysIntent: AppIntent {
  static var title: LocalizedStringResource = "Turn On All Displays"
  static var description = IntentDescription("Power on all connected external displays via DDC")

  func perform() async throws -> some IntentResult {
    let displays = DisplayManager.shared.getOtherDisplays()
    guard !displays.isEmpty else { throw MonitorControlIntentError.noDisplaysConnected }
    await MainActor.run {
      for display in displays where !display.isSw() {
        display.setPowerMode(.on)
      }
    }
    os_log("Siri: powered on all displays", type: .info)
    return .result()
  }
}

// MARK: - Single-Display Intents

@available(macOS 13.0, *)
struct SetBrightnessIntent: AppIntent {
  static var title: LocalizedStringResource = "Set Display Brightness"
  static var description = IntentDescription("Set the brightness of an external display (use 'all' for all displays)")

  @Parameter(title: "Brightness", description: "Brightness level (0-100)")
  var brightness: Int

  @Parameter(title: "Display Name", description: "Display name, or 'all' for all displays", default: "")
  var displayName: String

  func perform() async throws -> some IntentResult & ReturnsValue<Int> {
    let (clamped, value) = DisplayActions.clampAndNormalize(brightness)
    let displays = try DisplayActions.resolveDisplays(name: displayName)
    await MainActor.run { DisplayActions.setBrightness(value, on: displays) }
    return .result(value: clamped)
  }
}

@available(macOS 13.0, *)
struct GetBrightnessIntent: AppIntent {
  static var title: LocalizedStringResource = "Get Display Brightness"
  static var description = IntentDescription("Get the current brightness of an external display")

  @Parameter(title: "Display Name", default: "")
  var displayName: String

  func perform() async throws -> some IntentResult & ReturnsValue<Int> {
    let display = try DisplayActions.resolveDisplay(name: displayName)
    let result: Int = await MainActor.run {
      Int(display.readPrefAsFloat(for: .brightness) * 100)
    }
    return .result(value: result)
  }
}

@available(macOS 13.0, *)
struct SetVolumeIntent: AppIntent {
  static var title: LocalizedStringResource = "Set Display Volume"
  static var description = IntentDescription("Set the volume of an external display (use 'all' for all displays)")

  @Parameter(title: "Volume", description: "Volume level (0-100)")
  var volume: Int

  @Parameter(title: "Display Name", description: "Display name, or 'all' for all displays", default: "")
  var displayName: String

  func perform() async throws -> some IntentResult & ReturnsValue<Int> {
    let (clamped, value) = DisplayActions.clampAndNormalize(volume)
    let displays = try DisplayActions.resolveDisplays(name: displayName)
    await MainActor.run { DisplayActions.setVolume(value, on: displays) }
    return .result(value: clamped)
  }
}

@available(macOS 13.0, *)
struct SetContrastIntent: AppIntent {
  static var title: LocalizedStringResource = "Set Display Contrast"
  static var description = IntentDescription("Set the contrast of an external display (use 'all' for all displays)")

  @Parameter(title: "Contrast", description: "Contrast level (0-100)")
  var contrast: Int

  @Parameter(title: "Display Name", description: "Display name, or 'all' for all displays", default: "")
  var displayName: String

  func perform() async throws -> some IntentResult & ReturnsValue<Int> {
    let (clamped, value) = DisplayActions.clampAndNormalize(contrast)
    let displays = try DisplayActions.resolveDisplays(name: displayName)
    await MainActor.run { DisplayActions.setContrast(value, on: displays) }
    return .result(value: clamped)
  }
}

@available(macOS 13.0, *)
struct SwitchInputIntent: AppIntent {
  static var title: LocalizedStringResource = "Switch Display Input"
  static var description = IntentDescription("Switch the input source of an external display")

  @Parameter(title: "Input Source")
  var inputSource: InputSourceEntity

  @Parameter(title: "Display Name", default: "")
  var displayName: String

  func perform() async throws -> some IntentResult {
    let display = try DisplayActions.resolveDisplay(name: displayName)
    guard let source = Command.InputSource(rawValue: UInt16(inputSource.rawValue)) else {
      throw MonitorControlIntentError.invalidCommand("Unknown input source value \(inputSource.rawValue)")
    }
    await MainActor.run { display.setInputSource(source) }
    return .result()
  }
}

@available(macOS 13.0, *)
struct SetPowerModeIntent: AppIntent {
  static var title: LocalizedStringResource = "Set Display Power"
  static var description = IntentDescription("Control the power state of an external display")

  @Parameter(title: "Power Mode")
  var powerMode: PowerModeEntity

  @Parameter(title: "Display Name", default: "")
  var displayName: String

  func perform() async throws -> some IntentResult {
    let displays = try DisplayActions.resolveDisplays(name: displayName)
    guard let mode = Command.PowerMode(rawValue: UInt16(powerMode.rawValue)) else {
      throw MonitorControlIntentError.invalidCommand("Unknown power mode value \(powerMode.rawValue)")
    }
    await MainActor.run {
      for display in displays where !display.isSw() {
        display.setPowerMode(mode)
      }
    }
    return .result()
  }
}

@available(macOS 13.0, *)
struct ListDisplaysIntent: AppIntent {
  static var title: LocalizedStringResource = "List Displays"
  static var description = IntentDescription("List all displays connected to this Mac")

  func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
    let names: [String] = await MainActor.run {
      DisplayManager.shared.getAllDisplays().map { display in
        let friendly = display.readPrefAsString(key: .friendlyName)
        return friendly.isEmpty ? display.name : friendly
      }
    }
    return .result(value: names)
  }
}

// MARK: - App Intent Entity Types

@available(macOS 13.0, *)
struct InputSourceEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation = "Input Source"
  static var defaultQuery = InputSourceQuery()

  var id: String
  var rawValue: Int
  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
  var name: String

  static var allSources: [InputSourceEntity] {
    Command.InputSource.common.map { source in
      InputSourceEntity(id: String(source.rawValue), rawValue: Int(source.rawValue), name: source.displayName)
    }
  }
}

@available(macOS 13.0, *)
struct InputSourceQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [InputSourceEntity] {
    InputSourceEntity.allSources.filter { identifiers.contains($0.id) }
  }

  func suggestedEntities() async throws -> [InputSourceEntity] {
    InputSourceEntity.allSources
  }
}

@available(macOS 13.0, *)
struct PowerModeEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation = "Power Mode"
  static var defaultQuery = PowerModeQuery()

  var id: String
  var rawValue: Int
  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
  var name: String

  // Intentionally limited to the three most common MCCS power modes.
  // Omits .suspend (3) and .offHardButton (5) for UX simplicity.
  static let allModes: [PowerModeEntity] = [
    PowerModeEntity(id: "on", rawValue: 1, name: "On"),
    PowerModeEntity(id: "standby", rawValue: 2, name: "Standby"),
    PowerModeEntity(id: "off", rawValue: 4, name: "Off"),
  ]
}

@available(macOS 13.0, *)
struct PowerModeQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [PowerModeEntity] {
    PowerModeEntity.allModes.filter { identifiers.contains($0.id) }
  }

  func suggestedEntities() async throws -> [PowerModeEntity] {
    PowerModeEntity.allModes
  }
}

// MARK: - App Shortcuts Provider (Siri Phrases)
// Apple limits AppShortcutsProvider to 10 shortcuts max. Currently at 7/10.

@available(macOS 13.0, *)
struct MonitorControlShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    // All displays brightness — the primary voice use case
    AppShortcut(
      intent: SetAllDisplaysBrightnessIntent(),
      phrases: [
        "Set all displays brightness with \(.applicationName)",
        "All displays brightness in \(.applicationName)",
        "Change all displays brightness with \(.applicationName)",
      ],
      shortTitle: "All Displays Brightness",
      systemImageName: "sun.max"
    )
    // All displays volume
    AppShortcut(
      intent: SetAllDisplaysVolumeIntent(),
      phrases: [
        "Set all displays volume with \(.applicationName)",
        "All displays volume in \(.applicationName)",
      ],
      shortTitle: "All Displays Volume",
      systemImageName: "speaker.wave.3"
    )
    // Single display brightness
    AppShortcut(
      intent: SetBrightnessIntent(),
      phrases: [
        "Set display brightness with \(.applicationName)",
        "Change brightness in \(.applicationName)",
      ],
      shortTitle: "Set Brightness",
      systemImageName: "sun.max"
    )
    // Input switching
    AppShortcut(
      intent: SwitchInputIntent(),
      phrases: [
        "Switch display input with \(.applicationName)",
        "Change input source in \(.applicationName)",
      ],
      shortTitle: "Switch Input",
      systemImageName: "rectangle.connected.to.line.below"
    )
    // Power control
    AppShortcut(
      intent: SetPowerModeIntent(),
      phrases: [
        "Control display power with \(.applicationName)",
      ],
      shortTitle: "Display Power",
      systemImageName: "power"
    )
    // Turn off all
    AppShortcut(
      intent: PowerOffAllDisplaysIntent(),
      phrases: [
        "Turn off all displays with \(.applicationName)",
        "Power off all displays with \(.applicationName)",
      ],
      shortTitle: "Turn Off All Displays",
      systemImageName: "power"
    )
    // Turn on all
    AppShortcut(
      intent: PowerOnAllDisplaysIntent(),
      phrases: [
        "Turn on all displays with \(.applicationName)",
        "Power on all displays with \(.applicationName)",
      ],
      shortTitle: "Turn On All Displays",
      systemImageName: "power"
    )
  }
}

#endif
