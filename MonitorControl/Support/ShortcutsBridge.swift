//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation
import os.log

/// Bridge to macOS Shortcuts app for executing HomeKit and automation actions.
///
/// Since macOS hides TV accessories from third-party HomeKit APIs, this bridge
/// invokes user-created Shortcuts by name via the `shortcuts` CLI.
///
/// Users create Shortcuts in the Shortcuts app with matching names:
/// - "MC_TV_Power_On" → HomeKit scene/action to power on TV
/// - "MC_TV_Power_Off" → HomeKit scene/action to power off TV
/// - etc.
///
/// MonitorControl can then trigger these via CLI, URL scheme, or menu.
class ShortcutsBridge {
  static let shared = ShortcutsBridge()

  /// Run a named Shortcut asynchronously
  /// - Parameters:
  ///   - name: The name of the Shortcut in the Shortcuts app
  ///   - input: Optional input text to pass to the Shortcut
  ///   - completion: Called with (success, output) when complete
  func runShortcut(name: String, input: String? = nil, completion: ((Bool, String) -> Void)? = nil) {
    var args = ["/usr/bin/shortcuts", "run", name]
    if let input = input {
      args += ["-i", input]
    }

    os_log("ShortcutsBridge: running shortcut '%{public}@'", type: .info, name)

    DispatchQueue.global(qos: .userInitiated).async {
      let process = Process()
      let pipe = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
      process.arguments = Array(args.dropFirst())
      process.standardOutput = pipe
      process.standardError = pipe

      do {
        try process.run()
        // Read BEFORE waitUntilExit to avoid deadlock if pipe buffer fills
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let success = process.terminationStatus == 0

        if !success {
          os_log("ShortcutsBridge: shortcut '%{public}@' failed (exit %{public}@): %{public}@",
                 type: .error, name, String(process.terminationStatus), output)
        }

        DispatchQueue.main.async {
          completion?(success, output)
        }
      } catch {
        os_log("ShortcutsBridge: failed to launch shortcut '%{public}@': %{public}@",
               type: .error, name, error.localizedDescription)
        DispatchQueue.main.async {
          completion?(false, error.localizedDescription)
        }
      }
    }
  }

  /// List all available Shortcuts
  func listShortcuts(completion: @escaping ([String]) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      let process = Process()
      let pipe = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
      process.arguments = ["list"]
      process.standardOutput = pipe

      do {
        try process.run()
        // Read BEFORE waitUntilExit to avoid deadlock if pipe buffer fills
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let shortcuts = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        DispatchQueue.main.async {
          completion(shortcuts)
        }
      } catch {
        os_log("ShortcutsBridge: failed to list shortcuts: %{public}@", type: .error, error.localizedDescription)
        DispatchQueue.main.async {
          completion([])
        }
      }
    }
  }

  /// Predefined shortcut name conventions for MonitorControl integration
  enum PredefinedShortcut: String, CaseIterable {
    case tvPowerOn = "MC_TV_Power_On"
    case tvPowerOff = "MC_TV_Power_Off"
    case tvVolumeUp = "MC_TV_Volume_Up"
    case tvVolumeDown = "MC_TV_Volume_Down"
    case tvMute = "MC_TV_Mute"
    case tvInputHDMI1 = "MC_TV_Input_HDMI1"
    case tvInputHDMI2 = "MC_TV_Input_HDMI2"
    case tvInputHDMI3 = "MC_TV_Input_HDMI3"
    case goodMorning = "MC_Good_Morning"
    case goodNight = "MC_Good_Night"
    case movieMode = "MC_Movie_Mode"
    case workMode = "MC_Work_Mode"

    var displayName: String {
      switch self {
      case .tvPowerOn: return "TV Power On"
      case .tvPowerOff: return "TV Power Off"
      case .tvVolumeUp: return "TV Volume Up"
      case .tvVolumeDown: return "TV Volume Down"
      case .tvMute: return "TV Mute"
      case .tvInputHDMI1: return "TV Input HDMI 1"
      case .tvInputHDMI2: return "TV Input HDMI 2"
      case .tvInputHDMI3: return "TV Input HDMI 3"
      case .goodMorning: return "Good Morning"
      case .goodNight: return "Good Night"
      case .movieMode: return "Movie Mode"
      case .workMode: return "Work Mode"
      }
    }
  }
}
