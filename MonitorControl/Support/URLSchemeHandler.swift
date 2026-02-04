//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import os.log

/// Handles monitorcontrol:// URL scheme commands
///
/// URL format: monitorcontrol://<command>?<params>
///
/// Examples:
///   monitorcontrol://set?property=brightness&value=80&display=Dell
///   monitorcontrol://get?property=brightness
///   monitorcontrol://input?source=hdmi1&display=Dell
///   monitorcontrol://power?mode=off&display=2
///   monitorcontrol://list
///
class URLSchemeHandler {
  static let shared = URLSchemeHandler()

  func handle(url: URL) {
    guard let host = url.host else {
      os_log("URL scheme: no command specified", type: .error)
      return
    }

    let params = URLSchemeHandler.parseQueryParams(url: url)
    let displayName = params["display"] ?? ""

    os_log("URL scheme command: %{public}@, params: %{public}@", type: .info, host, params.description)

    switch host.lowercased() {
    case "set":
      handleSet(params: params, displayName: displayName)
    case "get":
      handleGet(params: params, displayName: displayName)
    case "input":
      handleInput(params: params, displayName: displayName)
    case "power":
      handlePower(params: params, displayName: displayName)
    case "list":
      handleList()
    case "roku":
      handleRoku(params: params)
    case "shortcut":
      handleShortcut(params: params)
    case "virtual":
      handleVirtual(params: params)
    case "display":
      handleDisplayConnection(params: params)
    default:
      os_log("URL scheme: unknown command '%{public}@'", type: .error, host)
    }
  }

  private func handleSet(params: [String: String], displayName: String) {
    guard let property = params["property"],
          let valueStr = params["value"],
          let intValue = Int(valueStr) else {
      os_log("URL scheme set: missing property or value parameter", type: .error)
      return
    }

    guard let display = findDisplay(name: displayName) else {
      os_log("URL scheme set: no display found", type: .error)
      return
    }

    let floatValue = Float(max(0, min(intValue, 100))) / 100.0

    switch property.lowercased() {
    case "brightness":
      _ = display.setBrightness(floatValue)
      display.savePref(floatValue, for: .brightness)
      if let slider = display.sliderHandler[.brightness] {
        slider.setValue(floatValue, displayID: display.identifier)
      }
    case "volume":
      display.writeDDCValues(command: .audioSpeakerVolume, value: display.convValueToDDC(for: .audioSpeakerVolume, from: floatValue))
      display.savePref(floatValue, for: .audioSpeakerVolume)
      if let slider = display.sliderHandler[.audioSpeakerVolume] {
        slider.setValue(floatValue, displayID: display.identifier)
      }
    case "contrast":
      display.writeDDCValues(command: .contrast, value: display.convValueToDDC(for: .contrast, from: floatValue))
      display.savePref(floatValue, for: .contrast)
      if let slider = display.sliderHandler[.contrast] {
        slider.setValue(floatValue, displayID: display.identifier)
      }
    case "colortemp", "color-temp", "temperature":
      display.setColorTemperature(floatValue)
      if let slider = display.sliderHandler[.colorTemperatureRequest] {
        slider.setValue(floatValue, displayID: display.identifier)
      }
    default:
      os_log("URL scheme set: unknown property '%{public}@'", type: .error, property)
    }
  }

  private func handleGet(params: [String: String], displayName: String) {
    guard let property = params["property"] else {
      os_log("URL scheme get: missing property parameter", type: .error)
      return
    }

    guard let display = findDisplay(name: displayName) else {
      os_log("URL scheme get: no display found", type: .error)
      return
    }

    switch property.lowercased() {
    case "brightness":
      let value = Int(display.readPrefAsFloat(for: .brightness) * 100)
      os_log("URL scheme get brightness: %{public}@", type: .info, String(value))
    case "volume":
      let value = Int(display.readPrefAsFloat(for: .audioSpeakerVolume) * 100)
      os_log("URL scheme get volume: %{public}@", type: .info, String(value))
    case "contrast":
      let value = Int(display.readPrefAsFloat(for: .contrast) * 100)
      os_log("URL scheme get contrast: %{public}@", type: .info, String(value))
    case "colortemp", "color-temp", "temperature":
      let value = Int(display.readPrefAsFloat(for: .colorTemperatureRequest) * 100)
      os_log("URL scheme get color temperature: %{public}@", type: .info, String(value))
    default:
      os_log("URL scheme get: unknown property '%{public}@'", type: .error, property)
    }
  }

  private func handleInput(params: [String: String], displayName: String) {
    guard let sourceName = params["source"] else {
      os_log("URL scheme input: missing source parameter", type: .error)
      return
    }

    guard let display = findDisplay(name: displayName) else {
      os_log("URL scheme input: no display found", type: .error)
      return
    }

    guard let inputSource = parseInputSource(sourceName) else {
      os_log("URL scheme input: unknown source '%{public}@'", type: .error, sourceName)
      return
    }

    display.setInputSource(inputSource)
  }

  private func handlePower(params: [String: String], displayName: String) {
    guard let modeName = params["mode"] else {
      os_log("URL scheme power: missing mode parameter", type: .error)
      return
    }

    guard let display = findDisplay(name: displayName) else {
      os_log("URL scheme power: no display found", type: .error)
      return
    }

    let mode: Command.PowerMode
    switch modeName.lowercased() {
    case "on": mode = .on
    case "standby": mode = .standby
    case "off": mode = .off
    default:
      os_log("URL scheme power: unknown mode '%{public}@'", type: .error, modeName)
      return
    }

    display.setPowerMode(mode)
  }

  private func handleList() {
    for display in DisplayManager.shared.getAllDisplays() {
      let friendly = display.readPrefAsString(key: .friendlyName)
      let name = friendly.isEmpty ? display.name : friendly
      os_log("URL scheme list: [%{public}@] %{public}@", type: .info, String(display.identifier), name)
    }
  }

  private func parseInputSource(_ name: String) -> Command.InputSource? {
    switch name.lowercased() {
    case "hdmi1": return .hdmi1
    case "hdmi2": return .hdmi2
    case "dp1", "displayport1": return .displayPort1
    case "dp2", "displayport2": return .displayPort2
    case "usbc1", "usb-c1": return .usbC1
    case "usbc2", "usb-c2": return .usbC2
    case "dvi1": return .dvi1
    case "dvi2": return .dvi2
    case "vga1": return .vga1
    case "vga2": return .vga2
    default:
      if let raw = UInt16(name) {
        return Command.InputSource(rawValue: raw)
      }
      return nil
    }
  }

  private func handleRoku(params: [String: String]) {
    guard let action = params["action"] else {
      os_log("URL scheme roku: missing action parameter", type: .error)
      return
    }
    let deviceName = params["device"] ?? ""
    RokuDeviceManager.shared.loadSavedDevices()
    guard let device = RokuDeviceManager.shared.findDevice(name: deviceName) else {
      os_log("URL scheme roku: no device found", type: .error)
      return
    }

    switch action.lowercased() {
    case "power": device.powerToggle()
    case "power-on": device.powerOn()
    case "power-off": device.powerOff()
    case "volume-up": device.volumeUp()
    case "volume-down": device.volumeDown()
    case "mute": device.volumeMute()
    case "input":
      if let input = params["source"] {
        switch input.lowercased() {
        case "hdmi1": device.switchToHDMI(1)
        case "hdmi2": device.switchToHDMI(2)
        case "hdmi3": device.switchToHDMI(3)
        case "hdmi4": device.switchToHDMI(4)
        case "av": device.switchToAV()
        case "tuner": device.switchToTuner()
        default: os_log("URL scheme roku: unknown input '%{public}@'", type: .error, input)
        }
      }
    case "home": device.home()
    default:
      os_log("URL scheme roku: unknown action '%{public}@'", type: .error, action)
    }
  }

  /// Handle monitorcontrol://shortcut?name=MC_Good_Morning
  private func handleShortcut(params: [String: String]) {
    guard let name = params["name"] else {
      os_log("URL scheme shortcut: missing name parameter", type: .error)
      return
    }
    let input = params["input"]
    ShortcutsBridge.shared.runShortcut(name: name, input: input) { success, output in
      os_log("URL scheme shortcut '%{public}@': %{public}@", type: .info, name, success ? "succeeded" : "failed")
      if !output.isEmpty {
        os_log("URL scheme shortcut output: %{public}@", type: .info, output)
      }
    }
  }

  /// Handle monitorcontrol://virtual?action=info&id=1
  private func handleVirtual(params: [String: String]) {
    guard let action = params["action"] else {
      os_log("URL scheme virtual: missing action parameter", type: .error)
      return
    }
    switch action {
    case "info":
      guard let idStr = params["id"], let displayID = UInt32(idStr) else {
        os_log("URL scheme virtual: missing id parameter", type: .error)
        return
      }
      let info = VirtualDisplayManager.shared.getDisplayInfo(displayID: CGDirectDisplayID(displayID))
      os_log("URL scheme virtual info: %{public}@", type: .info, info.summary)
    case "list":
      let displays = VirtualDisplayManager.shared.getAllActiveDisplays()
      for displayID in displays {
        let info = VirtualDisplayManager.shared.getDisplayInfo(displayID: displayID)
        os_log("URL scheme virtual list: %{public}@", type: .info, info.summary)
      }
    default:
      os_log("URL scheme virtual: unknown action '%{public}@'", type: .error, action)
    }
  }

  /// Handle monitorcontrol://display?action=mirror&id=2&target=1
  private func handleDisplayConnection(params: [String: String]) {
    guard let action = params["action"] else {
      os_log("URL scheme display: missing action parameter", type: .error)
      return
    }
    switch action {
    case "mirror":
      guard let idStr = params["id"], let displayID = UInt32(idStr),
            let targetStr = params["target"], let targetID = UInt32(targetStr) else {
        os_log("URL scheme display: missing id/target for mirror", type: .error)
        return
      }
      _ = DisplayConnectionManager.shared.setMirror(displayID: CGDirectDisplayID(displayID), mirrorOf: CGDirectDisplayID(targetID))
    case "unmirror":
      guard let idStr = params["id"], let displayID = UInt32(idStr) else {
        os_log("URL scheme display: missing id for unmirror", type: .error)
        return
      }
      _ = DisplayConnectionManager.shared.unmirror(displayID: CGDirectDisplayID(displayID))
    case "rotate":
      guard let idStr = params["id"], let displayID = UInt32(idStr),
            let angleStr = params["angle"], let angle = Int(angleStr) else {
        os_log("URL scheme display: missing id/angle for rotate", type: .error)
        return
      }
      _ = DisplayConnectionManager.shared.setRotation(displayID: CGDirectDisplayID(displayID), angle: angle)
    case "move":
      guard let idStr = params["id"], let displayID = UInt32(idStr),
            let xStr = params["x"], let x = Int32(xStr),
            let yStr = params["y"], let y = Int32(yStr) else {
        os_log("URL scheme display: missing id/x/y for move", type: .error)
        return
      }
      _ = DisplayConnectionManager.shared.setDisplayOrigin(displayID: CGDirectDisplayID(displayID), x: x, y: y)
    case "power-off":
      let displayName = params["name"] ?? ""
      if let display = findDisplay(name: displayName) {
        DisplayConnectionManager.shared.powerOffDisplay(display)
      }
    case "power-on":
      let displayName = params["name"] ?? ""
      if let display = findDisplay(name: displayName) {
        DisplayConnectionManager.shared.powerOnDisplay(display)
      }
    default:
      os_log("URL scheme display: unknown action '%{public}@'", type: .error, action)
    }
  }

  static func parseQueryParams(url: URL) -> [String: String] {
    var params: [String: String] = [:]
    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
       let queryItems = components.queryItems {
      for item in queryItems {
        params[item.name] = item.value ?? ""
      }
    }
    return params
  }
}
