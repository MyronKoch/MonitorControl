//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import IOKit.pwr_mgt
import os.log

/// Manages IOPMAssertion to prevent macOS sleep while external displays are connected.
/// Uses IOPMAssertionCreateWithName with kIOPMAssertPreventUserIdleSystemSleep to keep the system
/// awake when the user has enabled this preference and external displays are detected.
class SleepPrevention {
  static let shared = SleepPrevention()

  private var assertionID: IOPMAssertionID = 0
  private var isAssertionActive = false
  private let queue = DispatchQueue(label: "me.guillermo.MonitorControl.SleepPrevention")

  /// Call this whenever displays are reconfigured to evaluate whether the sleep assertion
  /// should be created or released.
  func update() {
    let shouldPrevent = prefs.bool(forKey: PrefKey.preventSleepWhenDisplayConnected.rawValue)
    let hasExternalDisplays = DisplayManager.shared.getOtherDisplays().count > 0

    queue.async {
      if shouldPrevent, hasExternalDisplays {
        self.createAssertionIfNeeded()
      } else {
        self.releaseAssertionIfNeeded()
      }
    }
  }

  /// Force-release the assertion (e.g., on quit)
  func release() {
    queue.sync {
      releaseAssertionIfNeeded()
    }
  }

  private func createAssertionIfNeeded() {
    guard !isAssertionActive else { return }
    let reason = "MonitorControl: External display connected - preventing sleep" as CFString
    let result = IOPMAssertionCreateWithName(
      kIOPMAssertPreventUserIdleSystemSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      reason,
      &assertionID
    )
    if result == kIOReturnSuccess {
      isAssertionActive = true
      os_log("Sleep prevention: assertion created (ID=%{public}@)", type: .info, String(assertionID))
    } else {
      os_log("Sleep prevention: failed to create assertion (error=%{public}@)", type: .error, String(result))
    }
  }

  private func releaseAssertionIfNeeded() {
    guard isAssertionActive else { return }
    let result = IOPMAssertionRelease(assertionID)
    if result == kIOReturnSuccess {
      isAssertionActive = false
      os_log("Sleep prevention: assertion released", type: .info)
    } else {
      os_log("Sleep prevention: failed to release assertion (error=%{public}@)", type: .error, String(result))
    }
  }
}
