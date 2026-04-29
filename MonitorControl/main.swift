//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import Foundation

// Debug
let DEBUG_SW = false
let DEBUG_VIRTUAL = false
let DEBUG_MACOS10 = false
let DEBUG_GAMMA_ENFORCER = false
let DDC_MAX_DETECT_LIMIT: Int = 100

// Version
let MIN_PREVIOUS_BUILD_NUMBER = 6262

// App
var app: AppDelegate!
var menu: MenuHandler!

let prefs = UserDefaults.standard

// Views
private let storyboard = NSStoryboard(name: "Main", bundle: Bundle.main)
let mainPrefsVc = storyboard.instantiateController(withIdentifier: "MainPrefsVC") as? MainPrefsViewController
let displaysPrefsVc = storyboard.instantiateController(withIdentifier: "DisplaysPrefsVC") as? DisplaysPrefsViewController
let menuslidersPrefsVc = storyboard.instantiateController(withIdentifier: "MenuslidersPrefsVC") as? MenuslidersPrefsViewController
let keyboardPrefsVc = storyboard.instantiateController(withIdentifier: "KeyboardPrefsVC") as? KeyboardPrefsViewController
let aboutPrefsVc = storyboard.instantiateController(withIdentifier: "AboutPrefsVC") as? AboutPrefsViewController
let onboardingVc = storyboard.instantiateController(withIdentifier: "onboardingViewController") as? NSWindowController

// MARK: - CLI Support

/// Process command-line arguments and return true if handled (app should exit)
func handleCLI() -> Bool {
  let args = CommandLine.arguments
  guard args.count > 1 else { return false }

  // Initialize displays for CLI use
  func initDisplaysForCLI() {
    DisplayManager.shared.configureDisplays()
    DisplayManager.shared.addDisplayCounterSuffixes()
    DisplayManager.shared.updateArm64AVServices()
  }

  func findDisplay(identifier: String?) -> OtherDisplay? {
    let displays = DisplayManager.shared.getOtherDisplays()
    guard let identifier = identifier else {
      return displays.first
    }
    // Match by display ID number
    if let id = UInt32(identifier) {
      return displays.first { $0.identifier == CGDirectDisplayID(id) }
    }
    // Match by name (case-insensitive partial match)
    return displays.first { $0.name.lowercased().contains(identifier.lowercased()) }
  }

  func printHelp() {
    let help = """
    MonitorControl CLI

    Usage: MonitorControl <command> [options]

    Commands:
      list                          List all displays
      get <property> [-d <display>] Get a display property
      set <property> <value> [-d <display>]  Set a display property
      input <source> [-d <display>] Switch input source
      power <mode> [-d <display>]   Set power mode

    Properties:
      brightness  Display brightness (0-100)
      volume      Speaker volume (0-100)
      contrast    Display contrast (0-100)
      colortemp   Color temperature (0-100)

    Input Sources:
      hdmi1, hdmi2, dp1, dp2, usbc1, usbc2, dvi1, vga1

    Power Modes:
      on, standby, off

    Roku Commands:
      roku discover              Find Roku devices on network
      roku list                  List configured devices
      roku power [-r <device>]   Toggle power
      roku volume-up/down/mute   Volume control
      roku input <hdmi1-4>       Switch input

    Shortcuts Commands:
      shortcut run <name>        Run a macOS Shortcut
      shortcut list              List available Shortcuts

    Options:
      -d, --display <id|name>  Target display (ID number or name)
      -r, --device <name>      Target Roku device
      -h, --help               Show this help

    Examples:
      MonitorControl list
      MonitorControl set brightness 80
      MonitorControl set brightness 50 -d "Dell"
      MonitorControl get brightness -d 1
      MonitorControl input hdmi1
      MonitorControl power off -d 2
      MonitorControl roku discover
      MonitorControl roku power -r "Living Room"
      MonitorControl shortcut run "MC_Good_Morning"
    """
    print(help)
  }

  func parseDisplayArg(_ args: [String], startIndex: Int) -> String? {
    for i in startIndex ..< args.count - 1 {
      if args[i] == "-d" || args[i] == "--display" {
        return args[i + 1]
      }
    }
    return nil
  }

  func parseInputSource(_ name: String) -> Command.InputSource? {
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

  let command = args[1].lowercased()

  if command == "-h" || command == "--help" || command == "help" {
    printHelp()
    return true
  }

  initDisplaysForCLI()

  switch command {
  case "list":
    let displays = DisplayManager.shared.getAllDisplays()
    if displays.isEmpty {
      print("No displays found.")
    } else {
      for display in displays {
        let type: String
        if display is AppleDisplay {
          type = "Apple"
        } else if let other = display as? OtherDisplay {
          type = other.isSw() ? "Software" : "DDC"
        } else {
          type = "Unknown"
        }
        let friendlyName = display.readPrefAsString(key: .friendlyName)
        let displayName = friendlyName.isEmpty ? display.name : "\(friendlyName) (\(display.name))"
        print("  [\(display.identifier)] \(displayName) - \(type)")
      }
    }
    return true

  case "get":
    guard args.count >= 3 else {
      print("Error: Missing property name. Use: get <brightness|volume|contrast>")
      return true
    }
    let displayId = parseDisplayArg(args, startIndex: 3)
    guard let display = findDisplay(identifier: displayId) else {
      print("Error: No DDC display found.")
      return true
    }
    let property = args[2].lowercased()
    switch property {
    case "brightness":
      let value = display.readPrefAsFloat(for: .brightness)
      print(Int(value * 100))
    case "volume":
      let value = display.readPrefAsFloat(for: .audioSpeakerVolume)
      print(Int(value * 100))
    case "contrast":
      let value = display.readPrefAsFloat(for: .contrast)
      print(Int(value * 100))
    case "colortemp", "color-temp", "temperature":
      let value = display.readPrefAsFloat(for: .colorTemperatureRequest)
      print(Int(value * 100))
    default:
      print("Error: Unknown property '\(property)'. Use: brightness, volume, contrast, colortemp")
    }
    return true

  case "set":
    guard args.count >= 4 else {
      print("Error: Usage: set <brightness|volume|contrast> <0-100>")
      return true
    }
    let displayId = parseDisplayArg(args, startIndex: 4)
    guard let display = findDisplay(identifier: displayId) else {
      print("Error: No DDC display found.")
      return true
    }
    let property = args[2].lowercased()
    guard let intValue = Int(args[3]), intValue >= 0, intValue <= 100 else {
      print("Error: Value must be between 0 and 100.")
      return true
    }
    let floatValue = Float(intValue) / 100.0

    switch property {
    case "brightness":
      _ = display.setBrightness(floatValue)
      display.savePref(floatValue, for: .brightness)
      print("Brightness set to \(intValue)%")
    case "volume":
      display.writeDDCValues(command: .audioSpeakerVolume, value: display.convValueToDDC(for: .audioSpeakerVolume, from: floatValue))
      display.savePref(floatValue, for: .audioSpeakerVolume)
      print("Volume set to \(intValue)%")
    case "contrast":
      display.writeDDCValues(command: .contrast, value: display.convValueToDDC(for: .contrast, from: floatValue))
      display.savePref(floatValue, for: .contrast)
      print("Contrast set to \(intValue)%")
    case "colortemp", "color-temp", "temperature":
      display.setColorTemperature(floatValue)
      print("Color temperature set to \(intValue)%")
    default:
      print("Error: Unknown property '\(property)'. Use: brightness, volume, contrast, colortemp")
    }
    // Small delay to let DDC write complete
    Thread.sleep(forTimeInterval: 0.1)
    return true

  case "input":
    guard args.count >= 3 else {
      print("Error: Usage: input <hdmi1|hdmi2|dp1|dp2|usbc1|usbc2|dvi1|vga1>")
      return true
    }
    let displayId = parseDisplayArg(args, startIndex: 3)
    guard let display = findDisplay(identifier: displayId) else {
      print("Error: No DDC display found.")
      return true
    }
    guard let inputSource = parseInputSource(args[2]) else {
      print("Error: Unknown input source '\(args[2])'.")
      print("Valid sources: hdmi1, hdmi2, dp1, dp2, usbc1, usbc2, dvi1, dvi2, vga1, vga2")
      return true
    }
    display.setInputSource(inputSource)
    print("Input switched to \(inputSource.displayName)")
    Thread.sleep(forTimeInterval: 0.1)
    return true

  case "power":
    guard args.count >= 3 else {
      print("Error: Usage: power <on|standby|off>")
      return true
    }
    let displayId = parseDisplayArg(args, startIndex: 3)
    guard let display = findDisplay(identifier: displayId) else {
      print("Error: No DDC display found.")
      return true
    }
    let mode: Command.PowerMode
    switch args[2].lowercased() {
    case "on": mode = .on
    case "standby": mode = .standby
    case "off": mode = .off
    default:
      print("Error: Unknown power mode '\(args[2])'. Use: on, standby, off")
      return true
    }
    display.setPowerMode(mode)
    print("Power mode set to \(mode.displayName)")
    Thread.sleep(forTimeInterval: 0.1)
    return true

  case "roku":
    guard args.count >= 3 else {
      print("Roku commands:")
      print("  roku discover                    - Find Roku devices on the network")
      print("  roku list                        - List configured Roku devices")
      print("  roku power [--device <name>]     - Toggle power")
      print("  roku power-on [--device <name>]  - Power on")
      print("  roku power-off [--device <name>] - Power off")
      print("  roku volume-up [--device <name>] - Volume up")
      print("  roku volume-down [--device <name>] - Volume down")
      print("  roku mute [--device <name>]      - Toggle mute")
      print("  roku input <hdmi1-4> [--device <name>] - Switch input")
      return true
    }
    let subcommand = args[2].lowercased()
    let deviceName = parseRokuDeviceArg(args)
    let semaphore = DispatchSemaphore(value: 0)

    switch subcommand {
    case "discover":
      RokuDiscovery.shared.discover { devices in
        if devices.isEmpty {
          print("No Roku devices found on the network.")
        } else {
          for device in devices {
            print("\(device.name) - \(device.host):\(device.port)")
            RokuDeviceManager.shared.addDevice(device)
          }
          print("Found \(devices.count) device(s). Saved to configuration.")
        }
        semaphore.signal()
      }
      _ = semaphore.wait(timeout: .now() + 5.0)

    case "list":
      RokuDeviceManager.shared.loadSavedDevices()
      let devices = RokuDeviceManager.shared.configuredDevices
      if devices.isEmpty {
        print("No Roku devices configured. Run 'roku discover' first.")
      } else {
        for device in devices {
          print("\(device.name) - \(device.host):\(device.port)")
        }
      }

    case "power":
      RokuDeviceManager.shared.loadSavedDevices()
      guard let device = RokuDeviceManager.shared.findDevice(name: deviceName) else {
        print("Error: No Roku device found. Run 'roku discover' first.")
        return true
      }
      device.powerToggle { success in
        print(success ? "Power toggled on \(device.name)" : "Failed to toggle power")
        semaphore.signal()
      }
      _ = semaphore.wait(timeout: .now() + 5.0)

    case "power-on":
      RokuDeviceManager.shared.loadSavedDevices()
      guard let device = RokuDeviceManager.shared.findDevice(name: deviceName) else {
        print("Error: No Roku device found.")
        return true
      }
      device.powerOn { success in
        print(success ? "Powered on \(device.name)" : "Failed to power on")
        semaphore.signal()
      }
      _ = semaphore.wait(timeout: .now() + 5.0)

    case "power-off":
      RokuDeviceManager.shared.loadSavedDevices()
      guard let device = RokuDeviceManager.shared.findDevice(name: deviceName) else {
        print("Error: No Roku device found.")
        return true
      }
      device.powerOff { success in
        print(success ? "Powered off \(device.name)" : "Failed to power off")
        semaphore.signal()
      }
      _ = semaphore.wait(timeout: .now() + 5.0)

    case "volume-up":
      RokuDeviceManager.shared.loadSavedDevices()
      guard let device = RokuDeviceManager.shared.findDevice(name: deviceName) else {
        print("Error: No Roku device found.")
        return true
      }
      device.volumeUp { success in
        print(success ? "Volume up on \(device.name)" : "Failed")
        semaphore.signal()
      }
      _ = semaphore.wait(timeout: .now() + 5.0)

    case "volume-down":
      RokuDeviceManager.shared.loadSavedDevices()
      guard let device = RokuDeviceManager.shared.findDevice(name: deviceName) else {
        print("Error: No Roku device found.")
        return true
      }
      device.volumeDown { success in
        print(success ? "Volume down on \(device.name)" : "Failed")
        semaphore.signal()
      }
      _ = semaphore.wait(timeout: .now() + 5.0)

    case "mute":
      RokuDeviceManager.shared.loadSavedDevices()
      guard let device = RokuDeviceManager.shared.findDevice(name: deviceName) else {
        print("Error: No Roku device found.")
        return true
      }
      device.volumeMute { success in
        print(success ? "Mute toggled on \(device.name)" : "Failed")
        semaphore.signal()
      }
      _ = semaphore.wait(timeout: .now() + 5.0)

    case "input":
      guard args.count >= 4 else {
        print("Error: Usage: roku input <hdmi1|hdmi2|hdmi3|hdmi4|av|tuner>")
        return true
      }
      RokuDeviceManager.shared.loadSavedDevices()
      guard let device = RokuDeviceManager.shared.findDevice(name: deviceName) else {
        print("Error: No Roku device found.")
        return true
      }
      let inputArg = args[3].lowercased()
      switch inputArg {
      case "hdmi1": device.switchToHDMI(1) { _ in semaphore.signal() }
      case "hdmi2": device.switchToHDMI(2) { _ in semaphore.signal() }
      case "hdmi3": device.switchToHDMI(3) { _ in semaphore.signal() }
      case "hdmi4": device.switchToHDMI(4) { _ in semaphore.signal() }
      case "av": device.switchToAV { _ in semaphore.signal() }
      case "tuner": device.switchToTuner { _ in semaphore.signal() }
      default:
        print("Error: Unknown input '\(inputArg)'. Use: hdmi1, hdmi2, hdmi3, hdmi4, av, tuner")
        return true
      }
      print("Input switched to \(inputArg) on \(device.name)")
      _ = semaphore.wait(timeout: .now() + 5.0)

    default:
      print("Error: Unknown roku subcommand '\(subcommand)'. Use 'roku' for help.")
    }
    return true

  case "shortcut":
    guard args.count >= 3 else {
      print("Shortcut commands:")
      print("  shortcut run <name>    - Run a macOS Shortcut by name")
      print("  shortcut list          - List all available Shortcuts")
      print("")
      print("Predefined Shortcut names for MonitorControl:")
      for shortcut in ShortcutsBridge.PredefinedShortcut.allCases {
        print("  \(shortcut.rawValue)  - \(shortcut.displayName)")
      }
      return true
    }
    let subcommand = args[2].lowercased()
    let semaphore = DispatchSemaphore(value: 0)

    switch subcommand {
    case "run":
      guard args.count >= 4 else {
        print("Error: Usage: shortcut run <name>")
        return true
      }
      let shortcutName = args[3]
      ShortcutsBridge.shared.runShortcut(name: shortcutName) { success, output in
        if success {
          print("Shortcut '\(shortcutName)' completed successfully.")
          if !output.isEmpty { print(output) }
        } else {
          print("Shortcut '\(shortcutName)' failed.")
          if !output.isEmpty { print(output) }
        }
        semaphore.signal()
      }
      _ = semaphore.wait(timeout: .now() + 30.0)

    case "list":
      ShortcutsBridge.shared.listShortcuts { shortcuts in
        if shortcuts.isEmpty {
          print("No Shortcuts found.")
        } else {
          for name in shortcuts {
            print(name)
          }
        }
        semaphore.signal()
      }
      _ = semaphore.wait(timeout: .now() + 10.0)

    default:
      print("Error: Unknown shortcut subcommand '\(subcommand)'. Use 'shortcut' for help.")
    }
    return true

  case "virtual":
    guard args.count >= 3 else {
      print("Virtual display commands:")
      print("  virtual list                                 - List all displays with info")
      print("  virtual info <displayID>                     - Get detailed display info")
      print("  virtual counts                               - Show display counts by type")
      return true
    }
    let subcommand = args[2].lowercased()

    switch subcommand {
    case "list":
      let active = VirtualDisplayManager.shared.getAllActiveDisplays()
      for displayID in active {
        let info = VirtualDisplayManager.shared.getDisplayInfo(displayID: displayID)
        print(info.summary)
      }

    case "info":
      guard args.count >= 4, let displayID = UInt32(args[3]) else {
        print("Error: Usage: virtual info <displayID>")
        return true
      }
      let info = VirtualDisplayManager.shared.getDisplayInfo(displayID: CGDirectDisplayID(displayID))
      print(info.summary)

    case "counts":
      let counts = VirtualDisplayManager.shared.getDisplayCounts()
      print("Total: \(counts.total), External: \(counts.external), Built-in: \(counts.builtin), Virtual: \(counts.virtual), Dummy: \(counts.dummy)")

    default:
      print("Error: Unknown virtual subcommand '\(subcommand)'. Use 'virtual' for help.")
    }
    return true

  case "display":
    guard args.count >= 3 else {
      print("Display connection commands:")
      print("  display mirror <displayID> <targetID> - Mirror displayID to targetID")
      print("  display unmirror <displayID>          - Stop mirroring a display")
      print("  display rotate <displayID> <angle>    - Rotate (0, 90, 180, 270)")
      print("  display move <displayID> <x> <y>      - Move display origin")
      print("  display arrangement                    - Show display arrangement")
      print("  display power-off <name>               - DDC power off a display")
      print("  display power-on <name>                - DDC power on a display")
      return true
    }
    let subcommand = args[2].lowercased()

    switch subcommand {
    case "mirror":
      guard args.count >= 5, let displayID = UInt32(args[3]), let targetID = UInt32(args[4]) else {
        print("Error: Usage: display mirror <displayID> <targetID>")
        return true
      }
      if DisplayConnectionManager.shared.setMirror(displayID: CGDirectDisplayID(displayID), mirrorOf: CGDirectDisplayID(targetID)) {
        print("Display \(displayID) now mirrors \(targetID)")
      } else {
        print("Error: Failed to set mirroring.")
      }

    case "unmirror":
      guard args.count >= 4, let displayID = UInt32(args[3]) else {
        print("Error: Usage: display unmirror <displayID>")
        return true
      }
      if DisplayConnectionManager.shared.unmirror(displayID: CGDirectDisplayID(displayID)) {
        print("Display \(displayID) unmirrored")
      } else {
        print("Error: Failed to unmirror display.")
      }

    case "rotate":
      guard args.count >= 5, let displayID = UInt32(args[3]), let angle = Int(args[4]) else {
        print("Error: Usage: display rotate <displayID> <angle>")
        return true
      }
      if DisplayConnectionManager.shared.setRotation(displayID: CGDirectDisplayID(displayID), angle: angle) {
        print("Display \(displayID) rotated to \(angle)°")
      } else {
        print("Error: Failed to rotate display.")
      }

    case "move":
      guard args.count >= 6, let displayID = UInt32(args[3]), let x = Int32(args[4]), let y = Int32(args[5]) else {
        print("Error: Usage: display move <displayID> <x> <y>")
        return true
      }
      if DisplayConnectionManager.shared.setDisplayOrigin(displayID: CGDirectDisplayID(displayID), x: x, y: y) {
        print("Display \(displayID) moved to (\(x), \(y))")
      } else {
        print("Error: Failed to move display.")
      }

    case "arrangement":
      print(DisplayConnectionManager.shared.getArrangementSummary())

    case "power-off":
      guard args.count >= 4 else {
        print("Error: Usage: display power-off <name>")
        return true
      }
      let displayName = args[3]
      if let display = findDisplay(identifier: displayName) {
        DisplayConnectionManager.shared.powerOffDisplay(display)
        print("Powered off: \(display.name)")
      } else {
        print("Error: Display '\(displayName)' not found.")
      }

    case "power-on":
      guard args.count >= 4 else {
        print("Error: Usage: display power-on <name>")
        return true
      }
      let displayName = args[3]
      if let display = findDisplay(identifier: displayName) {
        DisplayConnectionManager.shared.powerOnDisplay(display)
        print("Powered on: \(display.name)")
      } else {
        print("Error: Display '\(displayName)' not found.")
      }

    default:
      print("Error: Unknown display subcommand '\(subcommand)'. Use 'display' for help.")
    }
    return true

  case "edid":
    guard args.count >= 3 else {
      print("EDID override commands:")
      print("  edid list                                   - List installed overrides")
      print("  edid hidpi <vendorID> <productID>           - Install HiDPI override")
      print("  edid remove <vendorID> <productID>          - Remove an override")
      print("  edid check <vendorID> <productID>           - Check if override exists")
      print("")
      print("Vendor/Product IDs are hex (e.g., 10ac 4097)")
      return true
    }
    let subcommand = args[2].lowercased()

    switch subcommand {
    case "list":
      let overrides = EDIDOverride.shared.listOverrides()
      if overrides.isEmpty {
        print("No EDID overrides installed.")
      } else {
        for override_ in overrides {
          print(override_.summary)
          print("  Path: \(override_.path)")
        }
      }

    case "hidpi":
      guard args.count >= 5,
            let vendorID = UInt32(args[3], radix: 16),
            let productID = UInt32(args[4], radix: 16) else {
        print("Error: Usage: edid hidpi <vendorID-hex> <productID-hex>")
        return true
      }
      if EDIDOverride.shared.installHiDPIOverride(vendorID: vendorID, productID: productID) {
        print("HiDPI override installed. Restart your Mac for changes to take effect.")
      } else {
        print("Error: Failed to install HiDPI override.")
      }

    case "remove":
      guard args.count >= 5,
            let vendorID = UInt32(args[3], radix: 16),
            let productID = UInt32(args[4], radix: 16) else {
        print("Error: Usage: edid remove <vendorID-hex> <productID-hex>")
        return true
      }
      if EDIDOverride.shared.removeOverride(vendorID: vendorID, productID: productID) {
        print("Override removed. Restart your Mac for changes to take effect.")
      } else {
        print("Error: No override found to remove.")
      }

    case "check":
      guard args.count >= 5,
            let vendorID = UInt32(args[3], radix: 16),
            let productID = UInt32(args[4], radix: 16) else {
        print("Error: Usage: edid check <vendorID-hex> <productID-hex>")
        return true
      }
      let exists = EDIDOverride.shared.hasOverride(vendorID: vendorID, productID: productID)
      print(exists ? "Override exists." : "No override installed.")

    default:
      print("Error: Unknown edid subcommand '\(subcommand)'. Use 'edid' for help.")
    }
    return true

  case "layout":
    guard args.count >= 3 else {
      print("Layout management commands:")
      print("  layout save <name>     - Save current display arrangement")
      print("  layout restore <name>  - Restore a saved arrangement")
      print("  layout list            - List saved layouts")
      print("  layout delete <name>   - Delete a saved layout")
      return true
    }
    let subcommand = args[2].lowercased()

    switch subcommand {
    case "save":
      guard args.count >= 4 else {
        print("Error: Usage: layout save <name>")
        return true
      }
      let name = args[3]
      if LayoutManager.shared.saveLayout(name: name) {
        print("Layout '\(name)' saved.")
      } else {
        print("Error: Failed to save layout.")
      }

    case "restore":
      guard args.count >= 4 else {
        print("Error: Usage: layout restore <name>")
        return true
      }
      let name = args[3]
      if LayoutManager.shared.restoreLayout(name: name) {
        print("Layout '\(name)' restored.")
      } else {
        print("Error: Layout '\(name)' not found or failed to restore.")
      }

    case "list":
      let presets = LayoutManager.shared.listPresets()
      if presets.isEmpty {
        print("No saved layouts.")
      } else {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        for preset in presets {
          print("\(preset.name) (\(df.string(from: preset.createdAt))) - \(preset.displays.count) displays")
        }
      }

    case "delete":
      guard args.count >= 4 else {
        print("Error: Usage: layout delete <name>")
        return true
      }
      let name = args[3]
      if LayoutManager.shared.deletePreset(name: name) {
        print("Layout '\(name)' deleted.")
      } else {
        print("Error: Layout '\(name)' not found.")
      }

    default:
      print("Error: Unknown layout subcommand '\(subcommand)'. Use 'layout' for help.")
    }
    return true

  case "sync":
    guard args.count >= 3 else {
      print("Sync commands:")
      print("  sync now                          - Sync all enabled groups now")
      print("  sync groups                       - List sync groups")
      print("  sync create <name> <sourceID> <targetID> [properties...] - Create group")
      print("  sync delete <name>                - Delete a sync group")
      print("  sync enable <name>                - Enable a sync group")
      print("  sync disable <name>               - Disable a sync group")
      print("  sync resolution <sourceID> <targetID> - Sync resolution proportionally")
      print("")
      print("Properties: brightness, contrast, volume, colorTemperature")
      return true
    }
    let subcommand = args[2].lowercased()

    switch subcommand {
    case "now":
      DisplaySyncEngine.shared.syncAllGroups()
      print("Synced all enabled groups.")

    case "groups":
      let groups = DisplaySyncEngine.shared.loadGroups()
      if groups.isEmpty {
        print("No sync groups configured.")
      } else {
        for group in groups {
          let status = group.enabled ? "enabled" : "disabled"
          let props = group.properties.map { $0.rawValue }.joined(separator: ", ")
          print("\(group.name) [\(status)]: \(group.sourceDisplayID) → \(group.targetDisplayIDs) (\(props))")
        }
      }

    case "create":
      guard args.count >= 6, let sourceID = UInt32(args[4]), let targetID = UInt32(args[5]) else {
        print("Error: Usage: sync create <name> <sourceID> <targetID> [properties...]")
        return true
      }
      let name = args[3]
      let propNames = args.count > 6 ? Array(args[6...]) : ["brightness"]
      let properties = propNames.compactMap { DisplaySyncEngine.SyncProperty(rawValue: $0) }
      if properties.isEmpty {
        print("Error: No valid properties specified. Options: brightness, contrast, volume, colorTemperature")
        return true
      }
      let group = DisplaySyncEngine.SyncGroup(
        name: name, sourceDisplayID: sourceID, targetDisplayIDs: [targetID],
        properties: properties, ratios: [:], enabled: true
      )
      DisplaySyncEngine.shared.addGroup(group)
      print("Created sync group '\(name)'.")

    case "delete":
      guard args.count >= 4 else { print("Error: Usage: sync delete <name>"); return true }
      DisplaySyncEngine.shared.removeGroup(name: args[3])
      print("Deleted sync group '\(args[3])'.")

    case "enable":
      guard args.count >= 4 else { print("Error: Usage: sync enable <name>"); return true }
      DisplaySyncEngine.shared.toggleGroup(name: args[3], enabled: true)
      print("Enabled sync group '\(args[3])'.")

    case "disable":
      guard args.count >= 4 else { print("Error: Usage: sync disable <name>"); return true }
      DisplaySyncEngine.shared.toggleGroup(name: args[3], enabled: false)
      print("Disabled sync group '\(args[3])'.")

    case "resolution":
      guard args.count >= 5, let sourceID = UInt32(args[3]), let targetID = UInt32(args[4]) else {
        print("Error: Usage: sync resolution <sourceID> <targetID>")
        return true
      }
      DisplaySyncEngine.shared.syncResolution(from: CGDirectDisplayID(sourceID), to: [CGDirectDisplayID(targetID)])
      print("Resolution synced from \(sourceID) to \(targetID).")

    default:
      print("Error: Unknown sync subcommand '\(subcommand)'. Use 'sync' for help.")
    }
    return true

  case "filter":
    guard args.count >= 3 else {
      print("Video filter commands:")
      print("  filter bluelight <displayID> <intensity> - Blue light reduction (0.0-1.0)")
      print("  filter grayscale <displayID>             - Toggle grayscale mode")
      print("  filter invert <displayID>                - Toggle color inversion")
      print("  filter tint <displayID> <r> <g> <b>      - Apply color tint (0.0-2.0)")
      print("  filter contrast <displayID> <factor>     - Contrast adjust (0.5-2.0)")
      print("  filter reset <displayID>                 - Remove all filters")
      return true
    }
    let subcommand = args[2].lowercased()
    guard args.count >= 4, let displayID = UInt32(args[3]) else {
      print("Error: Missing displayID parameter.")
      return true
    }
    let cgDisplayID = CGDirectDisplayID(displayID)

    switch subcommand {
    case "bluelight":
      let intensity = args.count >= 5 ? Float(args[4]) ?? 0.5 : 0.5
      VideoFilters.shared.applyFilter(.blueLightReduction(intensity: intensity), to: cgDisplayID)
      print("Blue light filter applied (intensity: \(intensity)).")

    case "grayscale":
      VideoFilters.shared.applyFilter(.grayscale, to: cgDisplayID)
      print("Grayscale filter applied.")

    case "invert":
      VideoFilters.shared.applyFilter(.invertColors, to: cgDisplayID)
      print("Color inversion filter applied.")

    case "tint":
      guard args.count >= 7,
            let r = Float(args[4]), let g = Float(args[5]), let b = Float(args[6]) else {
        print("Error: Usage: filter tint <displayID> <r> <g> <b>")
        return true
      }
      VideoFilters.shared.applyFilter(.colorTint(red: r, green: g, blue: b), to: cgDisplayID)
      print("Color tint applied (R:\(r), G:\(g), B:\(b)).")

    case "contrast":
      let factor = args.count >= 5 ? Float(args[4]) ?? 1.5 : 1.5
      VideoFilters.shared.applyFilter(.contrastBoost(factor: factor), to: cgDisplayID)
      print("Contrast filter applied (factor: \(factor)).")

    case "reset":
      VideoFilters.shared.removeAllFilters(from: cgDisplayID)
      print("All filters removed from display \(displayID).")

    default:
      print("Error: Unknown filter subcommand '\(subcommand)'. Use 'filter' for help.")
    }
    return true

  case "pip":
    guard args.count >= 3 else {
      print("Picture-in-Picture commands:")
      print("  pip start <sourceID> <targetID> [position] [scale] - Start software PIP")
      print("  pip stop                                            - Stop PIP")
      print("")
      print("Positions: topLeft, topRight, bottomLeft, bottomRight (default)")
      print("Scale: 0.1-0.5 (default: 0.25)")
      return true
    }
    let subcommand = args[2].lowercased()

    switch subcommand {
    case "start":
      guard args.count >= 5,
            let sourceID = UInt32(args[3]),
            let targetID = UInt32(args[4]) else {
        print("Error: Usage: pip start <sourceID> <targetID> [position] [scale]")
        return true
      }
      let position = args.count > 5 ? PictureInPicture.PIPPosition(rawValue: args[5]) ?? .bottomRight : .bottomRight
      let scale = args.count > 6 ? Float(args[6]) ?? 0.25 : 0.25
      PictureInPicture.shared.startSoftwarePIP(
        sourceDisplayID: CGDirectDisplayID(sourceID),
        targetDisplayID: CGDirectDisplayID(targetID),
        position: position,
        scale: scale
      )
      print("PIP started: display \(sourceID) → display \(targetID)")

    case "stop":
      PictureInPicture.shared.stopSoftwarePIP()
      print("PIP stopped.")

    default:
      print("Error: Unknown pip subcommand '\(subcommand)'. Use 'pip' for help.")
    }
    return true

  default:
    print("Error: Unknown command '\(command)'. Use --help for usage.")
    return true
  }
}

func parseRokuDeviceArg(_ args: [String]) -> String {
  for i in 0 ..< args.count - 1 {
    if args[i] == "--device" || args[i] == "-r" {
      return args[i + 1]
    }
  }
  return ""
}

// MARK: - Application Entry Point

autoreleasepool { () in
  if handleCLI() {
    exit(0)
  }
  let mc = NSApplication.shared
  let mcDelegate = AppDelegate()
  mc.delegate = mcDelegate
  mc.run()
}
