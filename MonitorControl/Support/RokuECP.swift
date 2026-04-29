//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation
import os.log

/// Roku External Control Protocol (ECP) client for controlling Roku TVs.
/// Supports power toggle, volume control, input switching, and device discovery.
///
/// Roku ECP runs on port 8060 over HTTP (no auth required).
/// API Reference: https://developer.roku.com/docs/developer-program/dev-tools/external-control-api.md
class RokuDevice: Identifiable {
  let id: String
  var name: String
  let host: String
  let port: Int
  var model: String
  var serialNumber: String

  private let session: URLSession

  init(id: String = UUID().uuidString, name: String, host: String, port: Int = 8060, model: String = "", serialNumber: String = "") {
    self.id = id
    self.name = name
    self.host = host
    self.port = port
    self.model = model
    self.serialNumber = serialNumber
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 5
    config.timeoutIntervalForResource = 10
    self.session = URLSession(configuration: config)
  }

  var baseURL: String { "http://\(host):\(port)" }

  // MARK: - Key Press (POST /keypress/<key>)

  /// Send a keypress command to the Roku device
  func keypress(_ key: String, completion: ((Bool) -> Void)? = nil) {
    guard let url = URL(string: "\(baseURL)/keypress/\(key)") else {
      completion?(false)
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    os_log("Roku ECP keypress: %{public}@ → %{public}@", type: .info, key, host)
    session.dataTask(with: request) { _, response, error in
      let success = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
      if !success {
        os_log("Roku ECP keypress failed: %{public}@", type: .error, error?.localizedDescription ?? "HTTP error")
      }
      completion?(success)
    }.resume()
  }

  // MARK: - Power

  /// Toggle power on/off
  func powerToggle(completion: ((Bool) -> Void)? = nil) {
    keypress("Power", completion: completion)
  }

  /// Power on via keypress (same as toggle, Roku doesn't have explicit on/off)
  func powerOn(completion: ((Bool) -> Void)? = nil) {
    keypress("PowerOn", completion: completion)
  }

  /// Power off via keypress
  func powerOff(completion: ((Bool) -> Void)? = nil) {
    keypress("PowerOff", completion: completion)
  }

  // MARK: - Volume

  func volumeUp(completion: ((Bool) -> Void)? = nil) {
    keypress("VolumeUp", completion: completion)
  }

  func volumeDown(completion: ((Bool) -> Void)? = nil) {
    keypress("VolumeDown", completion: completion)
  }

  func volumeMute(completion: ((Bool) -> Void)? = nil) {
    keypress("VolumeMute", completion: completion)
  }

  /// Set volume to a specific level by sending multiple up/down keypresses.
  /// Roku ECP doesn't support absolute volume, only relative changes.
  /// This is a best-effort approximation: mutes first, then sends `level` VolumeUp presses.
  func setVolume(_ level: Int, completion: ((Bool) -> Void)? = nil) {
    let clamped = max(0, min(level, 100))
    // First mute to ensure consistent state, then set volume
    keypress("VolumeMute") { [weak self] _ in
      guard let self = self else { return }
      // Unmute
      self.keypress("VolumeMute") { _ in
        // Sequentially send VolumeDown 50 times then VolumeUp to target
        // Use recursive dispatch to avoid Thread.sleep blocking
        self.sendRepeatedKeypress("VolumeDown", count: 50) {
          self.sendRepeatedKeypress("VolumeUp", count: clamped) {
            DispatchQueue.main.async { completion?(true) }
          }
        }
      }
    }
  }

  /// Send a keypress N times with 50ms spacing, without blocking the thread
  private func sendRepeatedKeypress(_ key: String, count: Int, completion: @escaping () -> Void) {
    guard count > 0 else {
      completion()
      return
    }
    keypress(key) { [weak self] _ in
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
        self?.sendRepeatedKeypress(key, count: count - 1, completion: completion)
      }
    }
  }

  // MARK: - Input Switching

  /// Switch to HDMI input (1-4)
  func switchToHDMI(_ port: Int, completion: ((Bool) -> Void)? = nil) {
    keypress("InputHDMI\(port)", completion: completion)
  }

  /// Switch to AV input
  func switchToAV(completion: ((Bool) -> Void)? = nil) {
    keypress("InputAV1", completion: completion)
  }

  /// Switch to Tuner
  func switchToTuner(completion: ((Bool) -> Void)? = nil) {
    keypress("InputTuner", completion: completion)
  }

  // MARK: - Navigation Keys

  func home(completion: ((Bool) -> Void)? = nil) { keypress("Home", completion: completion) }
  func back(completion: ((Bool) -> Void)? = nil) { keypress("Back", completion: completion) }
  func select(completion: ((Bool) -> Void)? = nil) { keypress("Select", completion: completion) }
  func up(completion: ((Bool) -> Void)? = nil) { keypress("Up", completion: completion) }
  func down(completion: ((Bool) -> Void)? = nil) { keypress("Down", completion: completion) }
  func left(completion: ((Bool) -> Void)? = nil) { keypress("Left", completion: completion) }
  func right(completion: ((Bool) -> Void)? = nil) { keypress("Right", completion: completion) }

  // MARK: - Device Info

  /// Query device info (name, model, power state, etc.)
  func queryDeviceInfo(completion: @escaping ([String: String]) -> Void) {
    guard let url = URL(string: "\(baseURL)/query/device-info") else {
      completion([:])
      return
    }
    session.dataTask(with: url) { data, _, error in
      guard let data = data, error == nil else {
        os_log("Roku ECP device-info query failed: %{public}@", type: .error, error?.localizedDescription ?? "unknown")
        completion([:])
        return
      }
      let parser = RokuXMLParser(data: data)
      completion(parser.parse())
    }.resume()
  }

  /// Check if the device is reachable
  func isReachable(completion: @escaping (Bool) -> Void) {
    guard let url = URL(string: "\(baseURL)/query/device-info") else {
      completion(false)
      return
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 3
    session.dataTask(with: request) { _, response, _ in
      completion((response as? HTTPURLResponse)?.statusCode == 200)
    }.resume()
  }
}

// MARK: - SSDP Discovery

class RokuDiscovery {
  static let shared = RokuDiscovery()

  private(set) var devices: [RokuDevice] = []
  private var discoverySocket: Int32 = -1

  /// Discover Roku devices on the local network via SSDP
  func discover(timeout: TimeInterval = 3.0, completion: @escaping ([RokuDevice]) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }
      var found: [RokuDevice] = []

      let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
      guard sock >= 0 else {
        os_log("Roku SSDP: failed to create socket", type: .error)
        DispatchQueue.main.async { completion([]) }
        return
      }

      // Set socket timeout
      var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
      setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

      // SSDP multicast address
      var addr = sockaddr_in()
      addr.sin_family = sa_family_t(AF_INET)
      addr.sin_port = UInt16(1900).bigEndian
      addr.sin_addr.s_addr = inet_addr("239.255.255.250")

      // M-SEARCH message for Roku ECP — no leading whitespace allowed in SSDP
      let searchMessage = "M-SEARCH * HTTP/1.1\r\nHost: 239.255.255.250:1900\r\nMan: \"ssdp:discover\"\r\nST: roku:ecp\r\nMX: 3\r\n\r\n"

      let messageData = searchMessage.data(using: .utf8)!
      _ = messageData.withUnsafeBytes { ptr in
        withUnsafePointer(to: &addr) { addrPtr in
          addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            sendto(sock, ptr.baseAddress, messageData.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
          }
        }
      }

      // Receive responses
      var buffer = [UInt8](repeating: 0, count: 2048)
      var seenHosts = Set<String>()

      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        let bytesRead = recv(sock, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { break }
        let response = String(bytes: buffer[0 ..< bytesRead], encoding: .utf8) ?? ""

        // Extract LOCATION header to get the device IP
        if let locationRange = response.range(of: "LOCATION: ", options: .caseInsensitive) {
          let locationStart = locationRange.upperBound
          if let lineEnd = response[locationStart...].firstIndex(of: "\r") ?? response[locationStart...].firstIndex(of: "\n") {
            let location = String(response[locationStart ..< lineEnd]).trimmingCharacters(in: .whitespaces)
            if let url = URL(string: location), let host = url.host, !seenHosts.contains(host) {
              seenHosts.insert(host)
              let port = url.port ?? 8060
              let device = RokuDevice(name: "Roku (\(host))", host: host, port: port)
              found.append(device)
            }
          }
        }
      }

      close(sock)

      // Query each device for its actual name
      let group = DispatchGroup()
      for device in found {
        group.enter()
        device.queryDeviceInfo { info in
          if let friendlyName = info["friendly-device-name"] ?? info["user-device-name"] {
            device.name = friendlyName
          }
          if let model = info["model-name"] {
            device.model = model
          }
          if let serial = info["serial-number"] {
            device.serialNumber = serial
          }
          group.leave()
        }
      }

      group.wait()
      self.devices = found

      DispatchQueue.main.async {
        os_log("Roku SSDP: discovered %{public}@ device(s)", type: .info, String(found.count))
        completion(found)
      }
    }
  }
}

// MARK: - Simple XML Parser for Roku device-info responses

private class RokuXMLParser: NSObject, XMLParserDelegate {
  private let data: Data
  private var result: [String: String] = [:]
  private var currentElement = ""
  private var currentValue = ""

  init(data: Data) {
    self.data = data
  }

  func parse() -> [String: String] {
    let parser = XMLParser(data: data)
    parser.delegate = self
    parser.parse()
    return result
  }

  func parser(_: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes _: [String: String] = [:]) {
    currentElement = elementName
    currentValue = ""
  }

  func parser(_: XMLParser, foundCharacters string: String) {
    currentValue += string
  }

  func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
    if !currentValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      result[elementName] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }
}

// MARK: - Roku Device Manager (integration with MonitorControl)

class RokuDeviceManager {
  static let shared = RokuDeviceManager()

  private(set) var configuredDevices: [RokuDevice] = []

  /// Load saved Roku device configurations from preferences
  func loadSavedDevices() {
    guard let savedData = prefs.array(forKey: "rokuDevices") as? [[String: String]] else { return }
    configuredDevices = savedData.compactMap { dict in
      guard let name = dict["name"], let host = dict["host"] else { return nil }
      return RokuDevice(
        id: dict["id"] ?? UUID().uuidString,
        name: name,
        host: host,
        port: Int(dict["port"] ?? "8060") ?? 8060,
        model: dict["model"] ?? "",
        serialNumber: dict["serialNumber"] ?? ""
      )
    }
    os_log("Roku: loaded %{public}@ saved device(s)", type: .info, String(configuredDevices.count))
  }

  /// Save Roku device configurations to preferences
  func saveDevices() {
    let data = configuredDevices.map { device -> [String: String] in
      [
        "id": device.id,
        "name": device.name,
        "host": device.host,
        "port": String(device.port),
        "model": device.model,
        "serialNumber": device.serialNumber,
      ]
    }
    prefs.set(data, forKey: "rokuDevices")
  }

  /// Add a discovered or manually configured device
  func addDevice(_ device: RokuDevice) {
    // Don't add duplicates by host
    if !configuredDevices.contains(where: { $0.host == device.host }) {
      configuredDevices.append(device)
      saveDevices()
    }
  }

  /// Remove a device by host
  func removeDevice(host: String) {
    configuredDevices.removeAll { $0.host == host }
    saveDevices()
  }

  /// Find a device by name (case-insensitive partial match)
  func findDevice(name: String) -> RokuDevice? {
    if name.isEmpty { return configuredDevices.first }
    return configuredDevices.first { $0.name.lowercased().contains(name.lowercased()) }
      ?? configuredDevices.first
  }

  /// Discover and auto-add Roku devices on the local network
  func discoverAndAdd(completion: @escaping ([RokuDevice]) -> Void) {
    RokuDiscovery.shared.discover { [weak self] devices in
      guard let self = self else { return }
      for device in devices {
        self.addDevice(device)
      }
      completion(self.configuredDevices)
    }
  }
}
