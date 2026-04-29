//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import CoreGraphics
import Foundation
import os.log

/// PIP (Picture-in-Picture) and PBP (Picture-by-Picture) control for external monitors.
///
/// For monitors without DDC PIP support, this class provides a software-based
/// PIP overlay using NSPanel to display a secondary screen capture in a
/// floating window.
class PictureInPicture {
  static let shared = PictureInPicture()

  private var pipPanel: NSPanel?
  private var pipTimer: Timer?
  private var sourceDisplayID: CGDirectDisplayID = 0

  // MARK: - Software PIP Overlay

  /// Create a floating PIP window showing content from another display
  func startSoftwarePIP(
    sourceDisplayID: CGDirectDisplayID,
    targetDisplayID: CGDirectDisplayID,
    position: PIPPosition = .bottomRight,
    scale: Float = 0.25
  ) {
    // Must run on main thread for AppKit operations
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        self.startSoftwarePIP(sourceDisplayID: sourceDisplayID, targetDisplayID: targetDisplayID, position: position, scale: scale)
      }
      return
    }

    stopSoftwarePIP()
    self.sourceDisplayID = sourceDisplayID

    guard let targetScreen = NSScreen.screens.first(where: { $0.displayID == targetDisplayID }) else {
      os_log("PIP: target display not found", type: .error)
      return
    }

    let targetFrame = targetScreen.frame
    let pipWidth = CGFloat(scale) * targetFrame.width
    let pipHeight = CGFloat(scale) * targetFrame.height

    let pipOrigin: CGPoint
    let padding: CGFloat = 20
    switch position {
    case .topLeft:
      pipOrigin = CGPoint(x: targetFrame.minX + padding, y: targetFrame.maxY - pipHeight - padding)
    case .topRight:
      pipOrigin = CGPoint(x: targetFrame.maxX - pipWidth - padding, y: targetFrame.maxY - pipHeight - padding)
    case .bottomLeft:
      pipOrigin = CGPoint(x: targetFrame.minX + padding, y: targetFrame.minY + padding)
    case .bottomRight:
      pipOrigin = CGPoint(x: targetFrame.maxX - pipWidth - padding, y: targetFrame.minY + padding)
    }

    let pipFrame = CGRect(x: pipOrigin.x, y: pipOrigin.y, width: pipWidth, height: pipHeight)

    // Use NSPanel with nonactivatingPanel so it doesn't steal focus
    let panel = NSPanel(
      contentRect: pipFrame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .black
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let imageView = NSImageView(frame: NSRect(origin: .zero, size: pipFrame.size))
    imageView.imageScaling = .scaleProportionallyUpOrDown
    panel.contentView = imageView

    panel.orderFrontRegardless()
    pipPanel = panel

    // Capture timer on main run loop for UI safety (5fps to reduce CPU/memory pressure)
    pipTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 5.0, repeats: true) { [weak self] _ in
      self?.updatePIPCapture()
    }

    os_log("PIP: started software PIP from display %{public}@ on display %{public}@",
           type: .info, String(sourceDisplayID), String(targetDisplayID))
  }

  /// Stop the software PIP overlay
  func stopSoftwarePIP() {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.stopSoftwarePIP() }
      return
    }
    pipTimer?.invalidate()
    pipTimer = nil
    pipPanel?.orderOut(nil)
    pipPanel = nil
    sourceDisplayID = 0
  }

  /// Check if software PIP is active
  var isPIPActive: Bool {
    return pipPanel != nil
  }

  private func updatePIPCapture() {
    guard sourceDisplayID != 0, let panel = pipPanel, let imageView = panel.contentView as? NSImageView else { return }

    // Capture a region-limited screenshot to reduce memory pressure
    let bounds = CGDisplayBounds(sourceDisplayID)
    guard let cgImage = CGDisplayCreateImage(sourceDisplayID, rect: bounds) else { return }
    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    imageView.image = image
  }

  enum PIPPosition: String, CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
  }

  // MARK: - DDC PIP Control (Hardware)

  /// Toggle PIP on/off via DDC (manufacturer-specific).
  func toggleHardwarePIP(for display: OtherDisplay) {
    os_log("PIP: hardware PIP toggle requested for %{public}@ - requires monitor-specific VCP codes",
           type: .info, display.name)
  }
}
