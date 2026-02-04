//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation
import IOKit
import os.log

/// Reads and parses EDID (Extended Display Identification Data) from connected displays.
/// EDID contains manufacturer info, supported resolutions, serial numbers, and timing data.
class EDIDReader {
  static let shared = EDIDReader()

  /// Parsed EDID data structure
  struct EDIDInfo {
    let rawData: Data
    let manufacturerID: String
    let productCode: UInt16
    let serialNumber: UInt32
    let weekOfManufacture: UInt8
    let yearOfManufacture: Int
    let edidVersion: String
    let displayName: String
    let maxHorizontalSize: Int // cm
    let maxVerticalSize: Int   // cm
    let gamma: Float
    let supportedResolutions: [String]
    let detailedTimings: [DetailedTiming]
    let serialString: String

    var diagonalInches: Float {
      let h = Float(maxHorizontalSize)
      let v = Float(maxVerticalSize)
      return sqrt(h * h + v * v) / 2.54
    }
  }

  struct DetailedTiming {
    let pixelClock: Int // kHz
    let hActive: Int
    let vActive: Int
    let hBlanking: Int
    let vBlanking: Int
    let refreshRate: Double
  }

  /// Read EDID for a display by its CGDirectDisplayID
  func readEDID(for displayID: CGDirectDisplayID) -> EDIDInfo? {
    guard let edidData = getEDIDData(for: displayID) else {
      os_log("EDIDReader: failed to read EDID for display %{public}@", type: .error, String(displayID))
      return nil
    }
    return parseEDID(edidData)
  }

  /// Get raw EDID bytes from IOKit
  private func getEDIDData(for displayID: CGDirectDisplayID) -> Data? {
    var iterator: io_iterator_t = 0
    let matching = IOServiceMatching("IODisplayConnect")
    guard IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator) == KERN_SUCCESS else {
      return nil
    }

    defer { IOObjectRelease(iterator) }

    var service: io_service_t = IOIteratorNext(iterator)
    while service != 0 {
      defer {
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
      }

      let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName)).takeRetainedValue() as NSDictionary as? [String: Any]
      if let info = info, let edidData = info["IODisplayEDID"] as? Data {
        let vendorID = info["DisplayVendorID"] as? UInt32 ?? 0
        let productID = info["DisplayProductID"] as? UInt32 ?? 0

        if CGDisplayVendorNumber(displayID) == vendorID && CGDisplayModelNumber(displayID) == productID {
          return edidData
        }
      }
    }

    return nil
  }

  /// Parse EDID binary data into structured info
  func parseEDID(_ data: Data) -> EDIDInfo? {
    guard data.count >= 128 else { return nil }
    let bytes = [UInt8](data)

    // Verify EDID signature: 00 FF FF FF FF FF FF 00
    let signature: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
    guard Array(bytes[0 ..< 8]) == signature else { return nil }

    // Manufacturer ID (bytes 8-9): 5-bit compressed ASCII
    let mfgBits = (UInt16(bytes[8]) << 8) | UInt16(bytes[9])
    let char1 = Character(UnicodeScalar(((mfgBits >> 10) & 0x1F) + 64)!)
    let char2 = Character(UnicodeScalar(((mfgBits >> 5) & 0x1F) + 64)!)
    let char3 = Character(UnicodeScalar((mfgBits & 0x1F) + 64)!)
    let manufacturerID = String([char1, char2, char3])

    // Product code (bytes 10-11)
    let productCode = UInt16(bytes[10]) | (UInt16(bytes[11]) << 8)

    // Serial number (bytes 12-15)
    let serialNumber = UInt32(bytes[12]) | (UInt32(bytes[13]) << 8) | (UInt32(bytes[14]) << 16) | (UInt32(bytes[15]) << 24)

    // Week and year of manufacture (bytes 16-17)
    let weekOfManufacture = bytes[16]
    let yearOfManufacture = Int(bytes[17]) + 1990

    // EDID version (bytes 18-19)
    let edidVersion = "\(bytes[18]).\(bytes[19])"

    // Display size (bytes 21-22) in cm
    let maxHorizontalSize = Int(bytes[21])
    let maxVerticalSize = Int(bytes[22])

    // Gamma (byte 23)
    let gamma = Float(bytes[23] + 100) / 100.0

    // Standard timings (bytes 38-53)
    var supportedResolutions: [String] = []
    for i in stride(from: 38, to: 54, by: 2) {
      if bytes[i] != 0x01 || bytes[i + 1] != 0x01 {
        let hPixels = (Int(bytes[i]) + 31) * 8
        let aspect = (bytes[i + 1] >> 6) & 0x03
        let vPixels: Int
        switch aspect {
        case 0: vPixels = hPixels * 10 / 16
        case 1: vPixels = hPixels * 3 / 4
        case 2: vPixels = hPixels * 4 / 5
        case 3: vPixels = hPixels * 9 / 16
        default: vPixels = hPixels * 3 / 4
        }
        let refreshRate = Int(bytes[i + 1] & 0x3F) + 60
        supportedResolutions.append("\(hPixels)x\(vPixels)@\(refreshRate)Hz")
      }
    }

    // Detailed timing descriptors (bytes 54-125, 18 bytes each)
    var detailedTimings: [DetailedTiming] = []
    var displayName = ""
    var serialString = ""

    for block in 0 ..< 4 {
      let offset = 54 + block * 18
      guard offset + 17 < data.count else { break }

      let blockBytes = Array(bytes[offset ..< offset + 18])

      // Check if this is a detailed timing or a descriptor
      if blockBytes[0] == 0 && blockBytes[1] == 0 {
        // This is a descriptor block
        let tag = blockBytes[3]
        if tag == 0xFC {
          // Monitor name
          displayName = String(bytes: blockBytes[5 ..< 18], encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } else if tag == 0xFF {
          // Serial string
          serialString = String(bytes: blockBytes[5 ..< 18], encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
      } else {
        // Detailed timing
        let pixelClock = Int(UInt16(blockBytes[0]) | (UInt16(blockBytes[1]) << 8)) * 10 // kHz
        let hActive = Int(blockBytes[2]) | (Int(blockBytes[4] >> 4) << 8)
        let hBlanking = Int(blockBytes[3]) | (Int(blockBytes[4] & 0x0F) << 8)
        let vActive = Int(blockBytes[5]) | (Int(blockBytes[7] >> 4) << 8)
        let vBlanking = Int(blockBytes[6]) | (Int(blockBytes[7] & 0x0F) << 8)

        let totalPixels = (hActive + hBlanking) * (vActive + vBlanking)
        let refreshRate = totalPixels > 0 ? Double(pixelClock * 1000) / Double(totalPixels) : 0

        if pixelClock > 0 {
          detailedTimings.append(DetailedTiming(
            pixelClock: pixelClock,
            hActive: hActive,
            vActive: vActive,
            hBlanking: hBlanking,
            vBlanking: vBlanking,
            refreshRate: refreshRate
          ))
        }
      }
    }

    return EDIDInfo(
      rawData: data,
      manufacturerID: manufacturerID,
      productCode: productCode,
      serialNumber: serialNumber,
      weekOfManufacture: weekOfManufacture,
      yearOfManufacture: yearOfManufacture,
      edidVersion: edidVersion,
      displayName: displayName,
      maxHorizontalSize: maxHorizontalSize,
      maxVerticalSize: maxVerticalSize,
      gamma: gamma,
      supportedResolutions: supportedResolutions,
      detailedTimings: detailedTimings,
      serialString: serialString
    )
  }

  /// Get a hex dump of the raw EDID data
  func hexDump(_ data: Data) -> String {
    var result = ""
    let bytes = [UInt8](data)
    for (i, byte) in bytes.enumerated() {
      if i % 16 == 0 {
        if i > 0 { result += "\n" }
        result += String(format: "%04X: ", i)
      }
      result += String(format: "%02X ", byte)
    }
    return result
  }
}
