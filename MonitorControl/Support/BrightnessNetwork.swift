//  Copyright MonitorControl. Cross-Mac brightness sync via Bonjour + TCP.

import Cocoa
import Foundation
import os.log

let BRIGHTNESS_NETWORK_PORT: UInt16 = 30217
let BRIGHTNESS_SERVICE_TYPE = "_monitorcontrol._tcp"
let BRIGHTNESS_SERVICE_DOMAIN = "local."

class BrightnessNetworkManager: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, StreamDelegate {
  static let shared = BrightnessNetworkManager()

  private var serverSocket: Int32 = -1
  private var netService: NetService?
  private var browser: NetServiceBrowser?
  private var resolving: [NetService] = []
  private var peerStreams: [String: (input: InputStream, output: OutputStream)] = [:]
  private var incomingStreams: [String: (input: InputStream, output: OutputStream)] = [:]
  private let hostID = ProcessInfo.processInfo.hostName + "-" + String(ProcessInfo.processInfo.processIdentifier)
  private var suppressBroadcast = false
  private var inputBuffers: [String: Data] = [:]

  private var knownPeerNames: Set<String> = []

  func start() {
    startServer()
    startDiscovery()
    startReconnectTimer()
    os_log("BrightnessNetwork: started (hostID=%{public}@, port=%{public}d)", type: .info, hostID, BRIGHTNESS_NETWORK_PORT)
  }

  private func startReconnectTimer() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
      self?.reconnectDroppedPeers()
      self?.startReconnectTimer()
    }
  }

  private func reconnectDroppedPeers() {
    for name in knownPeerNames where peerStreams["peer-\(name)"] == nil {
      os_log("BrightnessNetwork: attempting reconnect to %{public}@", type: .info, name)
      let service = NetService(domain: BRIGHTNESS_SERVICE_DOMAIN, type: BRIGHTNESS_SERVICE_TYPE, name: name)
      resolving.append(service)
      service.delegate = self
      service.resolve(withTimeout: 5.0)
    }
  }

  // MARK: - Server (POSIX socket)

  private func startServer() {
    serverSocket = socket(AF_INET, SOCK_STREAM, 0)
    guard serverSocket >= 0 else {
      os_log("BrightnessNetwork: failed to create socket", type: .error)
      return
    }
    var reuse: Int32 = 1
    setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(BRIGHTNESS_NETWORK_PORT).bigEndian
    addr.sin_addr.s_addr = INADDR_ANY.bigEndian
    let bindResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        Darwin.bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      os_log("BrightnessNetwork: bind failed (errno %{public}d) - port %{public}d may be in use", type: .error, errno, BRIGHTNESS_NETWORK_PORT)
      close(serverSocket)
      serverSocket = -1
      return
    }
    guard listen(serverSocket, 5) == 0 else {
      os_log("BrightnessNetwork: listen failed", type: .error)
      close(serverSocket)
      serverSocket = -1
      return
    }
    os_log("BrightnessNetwork: server listening on port %{public}d", type: .info, BRIGHTNESS_NETWORK_PORT)

    netService = NetService(domain: BRIGHTNESS_SERVICE_DOMAIN, type: BRIGHTNESS_SERVICE_TYPE, name: Host.current().localizedName ?? "Mac", port: Int32(BRIGHTNESS_NETWORK_PORT))
    netService?.delegate = self
    netService?.publish()

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.acceptLoop()
    }
  }

  private func acceptLoop() {
    while serverSocket >= 0 {
      var clientAddr = sockaddr_in()
      var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
      let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
          accept(serverSocket, sockaddrPtr, &addrLen)
        }
      }
      guard clientSocket >= 0 else { continue }

      var readStream: Unmanaged<CFReadStream>?
      var writeStream: Unmanaged<CFWriteStream>?
      CFStreamCreatePairWithSocket(kCFAllocatorDefault, clientSocket, &readStream, &writeStream)

      guard let inputCF = readStream?.takeRetainedValue(), let outputCF = writeStream?.takeRetainedValue() else {
        close(clientSocket)
        continue
      }
      let input = inputCF as InputStream
      let output = outputCF as OutputStream

      CFReadStreamSetProperty(inputCF, CFStreamPropertyKey(rawValue: kCFStreamPropertyShouldCloseNativeSocket), kCFBooleanTrue)
      CFWriteStreamSetProperty(outputCF, CFStreamPropertyKey(rawValue: kCFStreamPropertyShouldCloseNativeSocket), kCFBooleanTrue)

      let connID = "incoming-\(clientSocket)"
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.incomingStreams[connID] = (input, output)
        input.delegate = self
        output.delegate = self
        input.schedule(in: .main, forMode: .common)
        output.schedule(in: .main, forMode: .common)
        input.open()
        output.open()
        os_log("BrightnessNetwork: accepted incoming connection %{public}@", type: .info, connID)
      }
    }
  }

  // MARK: - Client / Discovery

  private func startDiscovery() {
    browser = NetServiceBrowser()
    browser?.delegate = self
    browser?.searchForServices(ofType: BRIGHTNESS_SERVICE_TYPE, inDomain: BRIGHTNESS_SERVICE_DOMAIN)
    os_log("BrightnessNetwork: browsing for peers", type: .info)
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    if service.name == (Host.current().localizedName ?? "Mac") { return }
    os_log("BrightnessNetwork: found peer %{public}@", type: .info, service.name)
    knownPeerNames.insert(service.name)
    guard peerStreams["peer-\(service.name)"] == nil else { return }
    resolving.append(service)
    service.delegate = self
    service.resolve(withTimeout: 5.0)
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
    os_log("BrightnessNetwork: peer removed %{public}@", type: .info, service.name)
    let peerID = "peer-\(service.name)"
    peerStreams[peerID]?.input.close()
    peerStreams[peerID]?.output.close()
    peerStreams.removeValue(forKey: peerID)
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    os_log("BrightnessNetwork: resolved peer %{public}@ on port %{public}d", type: .info, sender.name, sender.port)
    resolving.removeAll { $0 === sender }

    guard let hostName = sender.hostName else {
      os_log("BrightnessNetwork: no hostname for %{public}@", type: .error, sender.name)
      return
    }
    var inputStream: InputStream?
    var outputStream: OutputStream?
    Stream.getStreamsToHost(withName: hostName, port: sender.port, inputStream: &inputStream, outputStream: &outputStream)

    guard let input = inputStream, let output = outputStream else {
      os_log("BrightnessNetwork: failed to create streams to %{public}@", type: .error, sender.name)
      return
    }

    let peerID = "peer-\(sender.name)"
    peerStreams[peerID] = (input, output)
    input.delegate = self
    output.delegate = self
    input.schedule(in: .main, forMode: .common)
    output.schedule(in: .main, forMode: .common)
    input.open()
    output.open()
    os_log("BrightnessNetwork: connected to peer %{public}@", type: .info, sender.name)
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    os_log("BrightnessNetwork: failed to resolve %{public}@", type: .error, sender.name)
    resolving.removeAll { $0 === sender }
  }

  // MARK: - Stream Delegate

  func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
    if eventCode.contains(.hasBytesAvailable), let input = aStream as? InputStream {
      readFromStream(input)
    }
    if eventCode.contains(.errorOccurred) || eventCode.contains(.endEncountered) {
      let streamID = findStreamID(for: aStream)
      if let id = streamID {
        peerStreams[id]?.input.close()
        peerStreams[id]?.output.close()
        peerStreams.removeValue(forKey: id)
        incomingStreams[id]?.input.close()
        incomingStreams[id]?.output.close()
        incomingStreams.removeValue(forKey: id)
        inputBuffers.removeValue(forKey: id)
      }
    }
  }

  private func findStreamID(for stream: Stream) -> String? {
    for (id, pair) in peerStreams where pair.input === stream || pair.output === stream { return id }
    for (id, pair) in incomingStreams where pair.input === stream || pair.output === stream { return id }
    return nil
  }

  private func readFromStream(_ input: InputStream) {
    let streamID = findStreamID(for: input) ?? "unknown"
    var buffer = [UInt8](repeating: 0, count: 4096)
    while input.hasBytesAvailable {
      let bytesRead = input.read(&buffer, maxLength: buffer.count)
      guard bytesRead > 0 else { break }
      if inputBuffers[streamID] == nil { inputBuffers[streamID] = Data() }
      inputBuffers[streamID]?.append(contentsOf: buffer[0..<bytesRead])
    }

    guard var accumulated = inputBuffers[streamID],
          let text = String(data: accumulated, encoding: .utf8) else { return }

    let lines = text.components(separatedBy: "\n")
    for (i, line) in lines.enumerated() {
      if i == lines.count - 1 {
        inputBuffers[streamID] = line.data(using: .utf8) ?? Data()
        break
      }
      guard !line.isEmpty,
            let msgData = line.data(using: .utf8),
            let msg = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any],
            let type = msg["type"] as? String else { continue }
      handleMessage(type: type, msg: msg, streamID: streamID)
    }
  }

  private func handleMessage(type: String, msg: [String: Any], streamID: String) {
    switch type {
    case "masterBrightness":
      guard let value = (msg["value"] as? NSNumber)?.floatValue,
            let sourceID = msg["sourceID"] as? String,
            sourceID != hostID else { return }
      os_log("BrightnessNetwork: received master brightness %{public}@ from %{public}@", type: .info, String(value), sourceID)
      applyRemoteMasterBrightness(value)

    default: break
    }
  }

  // MARK: - Broadcasting

  func broadcastMasterBrightness(_ value: Float) {
    guard !suppressBroadcast else { return }
    let msg: [String: Any] = [
      "type": "masterBrightness",
      "value": value,
      "sourceID": hostID,
    ]
    for (_, pair) in peerStreams { sendJSON(msg, to: pair.output) }
    for (_, pair) in incomingStreams { sendJSON(msg, to: pair.output) }
  }

  // MARK: - Receiving

  private func applyRemoteMasterBrightness(_ value: Float) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.suppressBroadcast = true
      prefs.set(value, forKey: PrefKey.masterBrightnessValue.rawValue)
      if prefs.bool(forKey: PrefKey.masterBrightnessLocked.rawValue) {
        menu.masterBrightnessSliderHandler?.setValue(value)
        menu.applyMasterBrightness(value: value)
      }
      self.suppressBroadcast = false
    }
  }

  // MARK: - Helpers

  private func sendJSON(_ dict: [String: Any], to output: OutputStream) {
    guard output.streamStatus == .open,
          let data = try? JSONSerialization.data(withJSONObject: dict),
          var text = String(data: data, encoding: .utf8) else { return }
    text += "\n"
    if let bytes = text.data(using: .utf8) {
      _ = bytes.withUnsafeBytes { ptr in
        output.write(ptr.bindMemory(to: UInt8.self).baseAddress!, maxLength: bytes.count)
      }
    }
  }

  // MARK: - NetService Delegate (publishing)

  func netServiceDidPublish(_ sender: NetService) {
    os_log("BrightnessNetwork: published Bonjour service '%{public}@'", type: .info, sender.name)
  }

  func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
    os_log("BrightnessNetwork: failed to publish Bonjour service", type: .error)
  }
}
