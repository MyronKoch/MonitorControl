//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation
import os.log

/// Manages EDID override files for external displays.
///
/// macOS allows overriding display EDID data by placing files in:
///   /System/Volumes/Data/Library/Displays/Contents/Resources/Overrides/
/// or the user-writable:
///   ~/Library/Displays/Contents/Resources/Overrides/
///
/// Override directories are named "DisplayVendorID-<hex>" containing files
/// named "DisplayProductID-<hex>".
///
/// EDID overrides can force:
/// - Custom resolutions not in the display's native EDID
/// - Scaled resolutions (HiDPI/Retina on non-Apple displays)
/// - Custom refresh rates
/// - Color depth and pixel encoding overrides
class EDIDOverride {
  static let shared = EDIDOverride()

  /// Base directories for display overrides
  let systemOverridePath = "/System/Volumes/Data/Library/Displays/Contents/Resources/Overrides"
  let userOverridePath: String = {
    let home = NSHomeDirectory()
    return "\(home)/Library/Displays/Contents/Resources/Overrides"
  }()

  // MARK: - Override Directory Management

  /// Get the override directory path for a display
  func overrideDir(vendorID: UInt32) -> String {
    let vendorHex = String(format: "%x", vendorID)
    return "\(userOverridePath)/DisplayVendorID-\(vendorHex)"
  }

  /// Get the override file path for a display
  func overrideFile(vendorID: UInt32, productID: UInt32) -> String {
    let productHex = String(format: "%x", productID)
    return "\(overrideDir(vendorID: vendorID))/DisplayProductID-\(productHex)"
  }

  /// Check if an override exists for a display
  func hasOverride(vendorID: UInt32, productID: UInt32) -> Bool {
    return FileManager.default.fileExists(atPath: overrideFile(vendorID: vendorID, productID: productID))
  }

  // MARK: - HiDPI Resolution Injection

  /// Generate a display override plist that enables HiDPI/Retina scaling
  /// on non-Apple displays (the most common use case for EDID overrides).
  ///
  /// - Parameters:
  ///   - vendorID: Display vendor ID from CGDisplayVendorNumber
  ///   - productID: Display product ID from CGDisplayModelNumber
  ///   - resolutions: Array of (width, height) tuples for HiDPI resolutions to add
  /// - Returns: The plist data, or nil on failure
  func generateHiDPIOverride(vendorID: UInt32, productID: UInt32, resolutions: [(Int, Int)]? = nil) -> Data? {
    var plist: [String: Any] = [
      "DisplayVendorID": vendorID,
      "DisplayProductID": productID,
    ]

    // Scale resolutions: each entry is a data blob with a 20-byte timing descriptor
    var scaleResolutions: [Data] = []

    let resToAdd = resolutions ?? [
      (3840, 2160), // 4K
      (3200, 1800),
      (2560, 1440),
      (1920, 1080),
      (1680, 1050),
      (1440, 900),
      (1280, 720),
    ]

    for (width, height) in resToAdd {
      // Each resolution is encoded as a packed struct:
      // 4 bytes width (big-endian), 4 bytes height (big-endian), 4 bytes flags
      var data = Data(count: 8)
      var w = UInt32(width).bigEndian
      var h = UInt32(height).bigEndian
      data.replaceSubrange(0 ..< 4, with: Data(bytes: &w, count: 4))
      data.replaceSubrange(4 ..< 8, with: Data(bytes: &h, count: 4))
      scaleResolutions.append(data)
    }

    plist["scale-resolutions"] = scaleResolutions

    do {
      let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      return data
    } catch {
      os_log("EDIDOverride: failed to serialize plist: %{public}@", type: .error, error.localizedDescription)
      return nil
    }
  }

  /// Install a HiDPI override for a display
  /// - Returns: true if the override was written successfully
  func installHiDPIOverride(vendorID: UInt32, productID: UInt32, resolutions: [(Int, Int)]? = nil) -> Bool {
    guard let data = generateHiDPIOverride(vendorID: vendorID, productID: productID, resolutions: resolutions) else {
      return false
    }

    let dir = overrideDir(vendorID: vendorID)
    let file = overrideFile(vendorID: vendorID, productID: productID)

    do {
      try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try data.write(to: URL(fileURLWithPath: file))
      os_log("EDIDOverride: installed HiDPI override at %{public}@", type: .info, file)
      os_log("EDIDOverride: restart required for changes to take effect", type: .info)
      return true
    } catch {
      os_log("EDIDOverride: failed to write override: %{public}@", type: .error, error.localizedDescription)
      return false
    }
  }

  /// Remove an EDID override for a display
  func removeOverride(vendorID: UInt32, productID: UInt32) -> Bool {
    let file = overrideFile(vendorID: vendorID, productID: productID)
    guard FileManager.default.fileExists(atPath: file) else {
      os_log("EDIDOverride: no override to remove for %{public}@", type: .info, file)
      return false
    }

    do {
      try FileManager.default.removeItem(atPath: file)
      os_log("EDIDOverride: removed override at %{public}@", type: .info, file)
      return true
    } catch {
      os_log("EDIDOverride: failed to remove override: %{public}@", type: .error, error.localizedDescription)
      return false
    }
  }

  // MARK: - Override Listing

  /// List all installed display overrides (both system and user)
  func listOverrides() -> [OverrideInfo] {
    var results: [OverrideInfo] = []
    for basePath in [userOverridePath, systemOverridePath] {
      guard let vendorDirs = try? FileManager.default.contentsOfDirectory(atPath: basePath) else { continue }
      for vendorDir in vendorDirs where vendorDir.hasPrefix("DisplayVendorID-") {
        let vendorHex = vendorDir.replacingOccurrences(of: "DisplayVendorID-", with: "")
        guard let vendorID = UInt32(vendorHex, radix: 16) else { continue }
        let fullVendorPath = "\(basePath)/\(vendorDir)"
        guard let productFiles = try? FileManager.default.contentsOfDirectory(atPath: fullVendorPath) else { continue }
        for productFile in productFiles where productFile.hasPrefix("DisplayProductID-") {
          let productHex = productFile.replacingOccurrences(of: "DisplayProductID-", with: "")
          guard let productID = UInt32(productHex, radix: 16) else { continue }
          let isSystem = basePath == systemOverridePath
          results.append(OverrideInfo(vendorID: vendorID, productID: productID, path: "\(fullVendorPath)/\(productFile)", isSystem: isSystem))
        }
      }
    }
    return results
  }

  struct OverrideInfo {
    let vendorID: UInt32
    let productID: UInt32
    let path: String
    let isSystem: Bool

    var summary: String {
      let location = isSystem ? "System" : "User"
      return "[\(location)] VendorID: \(String(format: "0x%04X", vendorID)), ProductID: \(String(format: "0x%04X", productID))"
    }
  }
}
