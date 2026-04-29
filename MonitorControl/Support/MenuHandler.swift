//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import AppKit
import os.log

class MenuHandler: NSMenu, NSMenuDelegate {
  var combinedSliderHandler: [Command: SliderHandler] = [:]
  var masterBrightnessSliderHandler: SliderHandler?

  var lastMenuRelevantDisplayId: CGDirectDisplayID = 0

  func clearMenu() {
    var items: [NSMenuItem] = []
    for i in 0 ..< self.items.count {
      items.append(self.items[i])
    }
    for item in items {
      self.removeItem(item)
    }
    self.combinedSliderHandler.removeAll()
    self.masterBrightnessSliderHandler = nil
  }

  func menuWillOpen(_: NSMenu) {
    self.updateMenuRelevantDisplay()
    app.keyboardShortcuts.disengage()
  }

  func closeMenu() {
    self.cancelTrackingWithoutAnimation()
  }

  func updateMenus(dontClose: Bool = false) {
    os_log("Menu update initiated", type: .info)
    if !dontClose {
      self.cancelTrackingWithoutAnimation()
    }
    let menuIconPref = prefs.integer(forKey: PrefKey.menuIcon.rawValue)
    var showIcon = false
    if menuIconPref == MenuIcon.show.rawValue {
      showIcon = true
    } else if menuIconPref == MenuIcon.externalOnly.rawValue {
      let externalDisplays = DisplayManager.shared.displays.filter {
        CGDisplayIsBuiltin($0.identifier) == 0
      }
      if externalDisplays.count > 0 {
        showIcon = true
      }
    }
    app.updateStatusItemVisibility(showIcon)
    self.clearMenu()
    let currentDisplay = DisplayManager.shared.getCurrentDisplay()
    let relevantID = currentDisplay.map { DisplayManager.resolveEffectiveDisplayID($0.identifier) }
    var displays = DisplayManager.shared.sortDisplaysByFriendlyName()
    if prefs.bool(forKey: PrefKey.hideAppleFromMenu.rawValue) {
      displays.removeAll { $0 is AppleDisplay }
    }
    let relevant = prefs.integer(forKey: PrefKey.multiSliders.rawValue) == MultiSliders.relevant.rawValue
    let combine = prefs.integer(forKey: PrefKey.multiSliders.rawValue) == MultiSliders.combine.rawValue
    let isHidden: (Display) -> Bool = { display in
      if display.isDummy { return true }
      if let other = display as? OtherDisplay, other.isDiscouraged { return true }
      return false
    }
    let numOfDisplays = displays.filter { !isHidden($0) }.count
    if numOfDisplays != 0 {
      let asSubMenu: Bool = (displays.count > 3 && !relevant && !combine && app.macOS10()) ? true : false
      var iterator = 0
      for display in displays where (!relevant || relevantID == DisplayManager.resolveEffectiveDisplayID(display.identifier)) && !isHidden(display) {
        iterator += 1
        if !relevant, !combine, iterator != 1, app.macOS10() {
          self.addItem(NSMenuItem.separator())
        }
        self.updateDisplayMenu(display: display, asSubMenu: asSubMenu, numOfDisplays: numOfDisplays)
      }
      if combine {
        self.addCombinedDisplayMenuBlock()
      }
    }
    if self.isMasterBrightnessLocked(), !self.brightnessControllableDisplays().isEmpty {
      self.addMasterBrightnessMenuBlock()
    }
    self.addDefaultMenuOptions()
  }

  func addSliderItem(monitorSubMenu: NSMenu, sliderHandler: SliderHandler, append: Bool = false) {
    let item = NSMenuItem()
    item.view = sliderHandler.view
    if append {
      if app.macOS10() {
        let sliderHeaderItem = NSMenuItem()
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.systemGray, .font: NSFont.systemFont(ofSize: 12)]
        sliderHeaderItem.attributedTitle = NSAttributedString(string: sliderHandler.title, attributes: attrs)
        monitorSubMenu.addItem(sliderHeaderItem)
      }
      monitorSubMenu.addItem(item)
      return
    }
    monitorSubMenu.insertItem(item, at: 0)
    if app.macOS10() {
      let sliderHeaderItem = NSMenuItem()
      let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.systemGray, .font: NSFont.systemFont(ofSize: 12)]
      sliderHeaderItem.attributedTitle = NSAttributedString(string: sliderHandler.title, attributes: attrs)
      monitorSubMenu.insertItem(sliderHeaderItem, at: 0)
    }
  }

  func setupMenuSliderHandler(command: Command, display: Display, title: String) -> SliderHandler {
    if prefs.integer(forKey: PrefKey.multiSliders.rawValue) == MultiSliders.combine.rawValue, let combinedHandler = self.combinedSliderHandler[command] {
      combinedHandler.addDisplay(display)
      display.sliderHandler[command] = combinedHandler
      return combinedHandler
    } else {
      let sliderHandler = SliderHandler(display: display, command: command, title: title)
      if prefs.integer(forKey: PrefKey.multiSliders.rawValue) == MultiSliders.combine.rawValue {
        self.combinedSliderHandler[command] = sliderHandler
      }
      display.sliderHandler[command] = sliderHandler
      return sliderHandler
    }
  }

  func addDisplayMenuBlock(addedSliderHandlers: [SliderHandler], blockName: String, monitorSubMenu: NSMenu, numOfDisplays: Int, asSubMenu: Bool, display: Display? = nil) {
    if monitorSubMenu === self, app.macOS10() {
      self.appendMenuHeader(friendlyName: blockName, monitorSubMenu: monitorSubMenu, asSubMenu: asSubMenu, numOfDisplays: numOfDisplays)
      for addedSliderHandler in addedSliderHandlers.reversed() {
        self.addSliderItem(monitorSubMenu: monitorSubMenu, sliderHandler: addedSliderHandler, append: true)
      }
      return
    }
    if numOfDisplays > 1, prefs.integer(forKey: PrefKey.multiSliders.rawValue) != MultiSliders.relevant.rawValue, !DEBUG_MACOS10, #available(macOS 11.0, *) {
      class BlockView: NSView {
        override func draw(_: NSRect) {
          let radius = prefs.bool(forKey: PrefKey.showTickMarks.rawValue) ? CGFloat(4) : CGFloat(11)
          let outerMargin = CGFloat(15)
          let blockRect = self.frame.insetBy(dx: outerMargin, dy: outerMargin / 2 + 2).offsetBy(dx: 0, dy: outerMargin / 2 * -1 + 7)
          for i in 1 ... 5 {
            let blockPath = NSBezierPath(roundedRect: blockRect.insetBy(dx: CGFloat(i) * -1, dy: CGFloat(i) * -1), xRadius: radius + CGFloat(i) * 0.5, yRadius: radius + CGFloat(i) * 0.5)
            NSColor.black.withAlphaComponent(0.1 / CGFloat(i)).setStroke()
            blockPath.stroke()
          }
          let blockPath = NSBezierPath(roundedRect: blockRect, xRadius: radius, yRadius: radius)
          if [NSAppearance.Name.darkAqua, NSAppearance.Name.vibrantDark].contains(effectiveAppearance.name) {
            NSColor.systemGray.withAlphaComponent(0.3).setStroke()
            blockPath.stroke()
          }
          if ![NSAppearance.Name.darkAqua, NSAppearance.Name.vibrantDark].contains(effectiveAppearance.name) {
            NSColor.white.withAlphaComponent(0.5).setFill()
            blockPath.fill()
          }
        }
      }
      var contentWidth: CGFloat = 0
      var contentHeight: CGFloat = 0
      for addedSliderHandler in addedSliderHandlers {
        contentWidth = max(addedSliderHandler.view!.frame.width, contentWidth)
        contentHeight += addedSliderHandler.view!.frame.height
      }
      let margin = CGFloat(13)
      var blockNameView: NSTextField?
      if blockName != "" {
        contentHeight += 21
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.textColor, .font: NSFont.boldSystemFont(ofSize: 12)]
        blockNameView = NSTextField(labelWithAttributedString: NSAttributedString(string: blockName, attributes: attrs))
        blockNameView?.frame.size.width = contentWidth - margin * 2
        blockNameView?.alphaValue = 0.5
      }
      let itemView = BlockView(frame: NSRect(x: 0, y: 0, width: contentWidth + margin * 2, height: contentHeight + margin * 2))
      var sliderPosition = CGFloat(margin * -1 + 1)
      for addedSliderHandler in addedSliderHandlers {
        addedSliderHandler.view!.setFrameOrigin(NSPoint(x: margin, y: margin + sliderPosition + 13))
        itemView.addSubview(addedSliderHandler.view!)
        sliderPosition += addedSliderHandler.view!.frame.height
      }
      if let blockNameView = blockNameView {
        blockNameView.setFrameOrigin(NSPoint(x: margin + 13, y: contentHeight - 8))
        itemView.addSubview(blockNameView)
        // Add input/power icon buttons in the block header, right-aligned with the name
        if let otherDisplay = display as? OtherDisplay, !otherDisplay.isSw() {
          let iconSize = CGFloat(13)
          let iconSpacing = CGFloat(5)
          let rightPadding = margin + 13  // match the block's inner right edge
          var iconX = itemView.frame.width - rightPadding - iconSize
          let iconY = blockNameView.frame.origin.y + (blockNameView.frame.height - iconSize) / 2
          let showPower = !otherDisplay.readPrefAsBool(key: .unavailableDDC, for: .powerMode)
          let showInput = !otherDisplay.readPrefAsBool(key: .unavailableDDC, for: .inputSelect)
          if showPower {
            let powerBtn = NSButton(frame: NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize))
            powerBtn.bezelStyle = .regularSquare
            powerBtn.isBordered = false
            powerBtn.setButtonType(.momentaryChange)
            powerBtn.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Power")
            powerBtn.imageScaling = .scaleProportionallyUpOrDown
            powerBtn.alphaValue = 0.35
            powerBtn.tag = Int(otherDisplay.identifier)
            powerBtn.action = #selector(showPowerPopup(_:))
            powerBtn.target = self
            itemView.addSubview(powerBtn)
            iconX -= (iconSize + iconSpacing)
          }
          if showInput {
            let inputBtn = NSButton(frame: NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize))
            inputBtn.bezelStyle = .regularSquare
            inputBtn.isBordered = false
            inputBtn.setButtonType(.momentaryChange)
            inputBtn.image = NSImage(systemSymbolName: "rectangle.connected.to.line.below", accessibilityDescription: "Input Source")
            inputBtn.imageScaling = .scaleProportionallyUpOrDown
            inputBtn.alphaValue = 0.35
            inputBtn.tag = Int(otherDisplay.identifier)
            inputBtn.action = #selector(showInputPopup(_:))
            inputBtn.target = self
            itemView.addSubview(inputBtn)
          }
        }
      }
      let item = NSMenuItem()
      item.view = itemView
      if addedSliderHandlers.count != 0 {
        if monitorSubMenu === self {
          monitorSubMenu.addItem(item)
        } else {
          monitorSubMenu.insertItem(item, at: 0)
        }
      }
    } else {
      for addedSliderHandler in addedSliderHandlers {
        self.addSliderItem(monitorSubMenu: monitorSubMenu, sliderHandler: addedSliderHandler)
      }
      // For macOS 10 / non-block layout, add input/power as submenu items
      if let otherDisplay = display as? OtherDisplay, !otherDisplay.isSw() {
        self.addInputAndPowerMenuItems(for: otherDisplay, to: monitorSubMenu)
      }
    }
    self.appendMenuHeader(friendlyName: blockName, monitorSubMenu: monitorSubMenu, asSubMenu: asSubMenu, numOfDisplays: numOfDisplays)
  }

  func addCombinedDisplayMenuBlock() {
    if let sliderHandler = self.combinedSliderHandler[.audioSpeakerVolume] {
      self.addSliderItem(monitorSubMenu: self, sliderHandler: sliderHandler)
    }
    if let sliderHandler = self.combinedSliderHandler[.colorTemperatureRequest] {
      self.addSliderItem(monitorSubMenu: self, sliderHandler: sliderHandler)
    }
    if let sliderHandler = self.combinedSliderHandler[.contrast] {
      self.addSliderItem(monitorSubMenu: self, sliderHandler: sliderHandler)
    }
    if let sliderHandler = self.combinedSliderHandler[.brightness] {
      self.addSliderItem(monitorSubMenu: self, sliderHandler: sliderHandler)
    }
  }

  func updateDisplayMenu(display: Display, asSubMenu: Bool, numOfDisplays: Int) {
    os_log("Addig menu items for display %{public}@", type: .info, "\(display.identifier)")
    let monitorSubMenu: NSMenu = asSubMenu ? NSMenu() : self
    var addedSliderHandlers: [SliderHandler] = []
    let isMasterBrightnessLocked = self.isMasterBrightnessLocked()
    display.sliderHandler[.audioSpeakerVolume] = nil
    if let otherDisplay = display as? OtherDisplay, !otherDisplay.isSw(), !display.readPrefAsBool(key: .unavailableDDC, for: .audioSpeakerVolume), !prefs.bool(forKey: PrefKey.hideVolume.rawValue) {
      let title = NSLocalizedString("Volume", comment: "Shown in menu")
      addedSliderHandlers.append(self.setupMenuSliderHandler(command: .audioSpeakerVolume, display: display, title: title))
    }
    display.sliderHandler[.contrast] = nil
    if let otherDisplay = display as? OtherDisplay, !otherDisplay.isSw(), !display.readPrefAsBool(key: .unavailableDDC, for: .contrast), prefs.bool(forKey: PrefKey.showContrast.rawValue) {
      let title = NSLocalizedString("Contrast", comment: "Shown in menu")
      addedSliderHandlers.append(self.setupMenuSliderHandler(command: .contrast, display: display, title: title))
    }
    display.sliderHandler[.colorTemperatureRequest] = nil
    if let otherDisplay = display as? OtherDisplay, !otherDisplay.isSw(), !display.readPrefAsBool(key: .unavailableDDC, for: .colorTemperatureRequest), prefs.bool(forKey: PrefKey.showColorTemperature.rawValue) {
      let title = NSLocalizedString("Color Temperature", comment: "Shown in menu")
      addedSliderHandlers.append(self.setupMenuSliderHandler(command: .colorTemperatureRequest, display: display, title: title))
    }
    display.sliderHandler[.brightness] = nil
    if !display.readPrefAsBool(key: .unavailableDDC, for: .brightness), !prefs.bool(forKey: PrefKey.hideBrightness.rawValue) {
      let title = NSLocalizedString("Brightness", comment: "Shown in menu")
      let sliderHandler = self.setupMenuSliderHandler(command: .brightness, display: display, title: title)
      if isMasterBrightnessLocked {
        sliderHandler.setEnabled(false)
      }
      addedSliderHandlers.append(sliderHandler)
    }
    if prefs.integer(forKey: PrefKey.multiSliders.rawValue) != MultiSliders.combine.rawValue {
      self.addDisplayMenuBlock(addedSliderHandlers: addedSliderHandlers, blockName: display.readPrefAsString(key: .friendlyName) != "" ? display.readPrefAsString(key: .friendlyName) : display.name, monitorSubMenu: monitorSubMenu, numOfDisplays: numOfDisplays, asSubMenu: asSubMenu, display: display)
    }
    if addedSliderHandlers.count > 0, prefs.integer(forKey: PrefKey.menuIcon.rawValue) == MenuIcon.sliderOnly.rawValue {
      app.updateStatusItemVisibility(true)
    }
  }

  // MARK: - Input Switching & Power Control Menu Items

  func addInputAndPowerMenuItems(for display: OtherDisplay, to targetMenu: NSMenu) {
    guard !DEBUG_MACOS10, #available(macOS 11.0, *) else { return }

    let showInputSwitching = !display.readPrefAsBool(key: .unavailableDDC, for: .inputSelect)
    let showPowerControl = !display.readPrefAsBool(key: .unavailableDDC, for: .powerMode)

    guard showInputSwitching || showPowerControl else { return }

    // Use display's friendly name (or raw name) so items are identifiable per-display
    let displayName = display.readPrefAsString(key: .friendlyName) != "" ? display.readPrefAsString(key: .friendlyName) : display.name

    // Input Source submenu
    if showInputSwitching {
      let inputItem = NSMenuItem()
      inputItem.title = "\(NSLocalizedString("Input Source", comment: "Shown in menu")) — \(displayName)"
      let inputMenu = NSMenu()
      for inputSource in Command.InputSource.common {
        let sourceItem = NSMenuItem()
        sourceItem.title = inputSource.displayName
        sourceItem.tag = Int(inputSource.rawValue)
        sourceItem.representedObject = display
        sourceItem.action = #selector(inputSourceSelected(_:))
        sourceItem.target = self
        // Mark current input if known
        if let lastInput = display.getLastInputSource(), lastInput == inputSource {
          sourceItem.state = .on
        }
        inputMenu.addItem(sourceItem)
      }
      // Add "All Inputs" submenu for less common inputs
      inputMenu.addItem(NSMenuItem.separator())
      let allInputsItem = NSMenuItem()
      allInputsItem.title = NSLocalizedString("All Inputs", comment: "Shown in menu")
      let allInputsMenu = NSMenu()
      for inputSource in Command.InputSource.allCases where !Command.InputSource.common.contains(inputSource) {
        let sourceItem = NSMenuItem()
        sourceItem.title = inputSource.displayName
        sourceItem.tag = Int(inputSource.rawValue)
        sourceItem.representedObject = display
        sourceItem.action = #selector(inputSourceSelected(_:))
        sourceItem.target = self
        allInputsMenu.addItem(sourceItem)
      }
      allInputsItem.submenu = allInputsMenu
      inputMenu.addItem(allInputsItem)
      inputItem.submenu = inputMenu
      if !DEBUG_MACOS10, #available(macOS 11.0, *) {
        inputItem.image = NSImage(systemSymbolName: "rectangle.connected.to.line.below", accessibilityDescription: "Input Source")
      }
      targetMenu.addItem(inputItem)
    }

    // Power control submenu
    if showPowerControl {
      let powerItem = NSMenuItem()
      powerItem.title = "\(NSLocalizedString("Power", comment: "Shown in menu")) — \(displayName)"
      let powerMenu = NSMenu()
      for powerMode in [Command.PowerMode.on, .standby, .off] {
        let modeItem = NSMenuItem()
        modeItem.title = powerMode.displayName
        modeItem.tag = Int(powerMode.rawValue)
        modeItem.representedObject = display
        modeItem.action = #selector(powerModeSelected(_:))
        modeItem.target = self
        powerMenu.addItem(modeItem)
      }
      powerItem.submenu = powerMenu
      if !DEBUG_MACOS10, #available(macOS 11.0, *) {
        powerItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Power")
      }
      targetMenu.addItem(powerItem)
    }
  }

  @objc func showInputPopup(_ sender: NSButton) {
    guard let display = DisplayManager.shared.getOtherDisplays().first(where: { Int($0.identifier) == sender.tag }) else { return }
    let menu = NSMenu()
    for inputSource in Command.InputSource.common {
      let sourceItem = NSMenuItem()
      sourceItem.title = inputSource.displayName
      sourceItem.tag = Int(inputSource.rawValue)
      sourceItem.representedObject = display
      sourceItem.action = #selector(inputSourceSelected(_:))
      sourceItem.target = self
      if let lastInput = display.getLastInputSource(), lastInput == inputSource {
        sourceItem.state = .on
      }
      menu.addItem(sourceItem)
    }
    menu.addItem(NSMenuItem.separator())
    let allInputsItem = NSMenuItem()
    allInputsItem.title = NSLocalizedString("All Inputs", comment: "Shown in menu")
    let allInputsMenu = NSMenu()
    for inputSource in Command.InputSource.allCases where !Command.InputSource.common.contains(inputSource) {
      let sourceItem = NSMenuItem()
      sourceItem.title = inputSource.displayName
      sourceItem.tag = Int(inputSource.rawValue)
      sourceItem.representedObject = display
      sourceItem.action = #selector(inputSourceSelected(_:))
      sourceItem.target = self
      allInputsMenu.addItem(sourceItem)
    }
    allInputsItem.submenu = allInputsMenu
    menu.addItem(allInputsItem)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
  }

  @objc func showPowerPopup(_ sender: NSButton) {
    guard let display = DisplayManager.shared.getOtherDisplays().first(where: { Int($0.identifier) == sender.tag }) else { return }
    let menu = NSMenu()
    for powerMode in [Command.PowerMode.on, .standby, .off] {
      let modeItem = NSMenuItem()
      modeItem.title = powerMode.displayName
      modeItem.tag = Int(powerMode.rawValue)
      modeItem.representedObject = display
      modeItem.action = #selector(powerModeSelected(_:))
      modeItem.target = self
      menu.addItem(modeItem)
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
  }

  @objc func inputSourceSelected(_ sender: NSMenuItem) {
    guard let display = sender.representedObject as? OtherDisplay,
          let inputSource = Command.InputSource(rawValue: UInt16(sender.tag)) else { return }
    os_log("User selected input source: %{public}@", type: .info, inputSource.displayName)
    display.setInputSource(inputSource)
    // Update the menu checkmarks
    if let parentMenu = sender.menu {
      for item in parentMenu.items {
        item.state = (item.tag == sender.tag) ? .on : .off
      }
    }
  }

  @objc func powerModeSelected(_ sender: NSMenuItem) {
    guard let display = sender.representedObject as? OtherDisplay,
          let powerMode = Command.PowerMode(rawValue: UInt16(sender.tag)) else { return }
    os_log("User selected power mode: %{public}@", type: .info, powerMode.displayName)
    display.setPowerMode(powerMode)
  }

  private func appendMenuHeader(friendlyName: String, monitorSubMenu: NSMenu, asSubMenu: Bool, numOfDisplays: Int) {
    let monitorMenuItem = NSMenuItem()
    if asSubMenu {
      monitorMenuItem.title = "\(friendlyName)"
      monitorMenuItem.submenu = monitorSubMenu
      self.addItem(monitorMenuItem)
    } else if app.macOS10(), numOfDisplays > 1 {
      let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.systemGray, .font: NSFont.boldSystemFont(ofSize: 12)]
      monitorMenuItem.attributedTitle = NSAttributedString(string: "\(friendlyName)", attributes: attrs)
      self.addItem(monitorMenuItem)
    }
  }

  func updateMenuRelevantDisplay() {
    if prefs.integer(forKey: PrefKey.multiSliders.rawValue) == MultiSliders.relevant.rawValue {
      if let display = DisplayManager.shared.getCurrentDisplay(), display.identifier != self.lastMenuRelevantDisplayId {
        os_log("Menu must be refreshed as relevant display changed since last time.")
        self.lastMenuRelevantDisplayId = display.identifier
        self.updateMenus(dontClose: true)
      }
    }
  }

  func isMasterBrightnessLocked() -> Bool {
    prefs.bool(forKey: PrefKey.masterBrightnessLocked.rawValue)
  }

  func masterBrightnessValue() -> Float {
    if prefs.object(forKey: PrefKey.masterBrightnessValue.rawValue) == nil {
      return 1
    }
    return max(0, min(1, prefs.float(forKey: PrefKey.masterBrightnessValue.rawValue)))
  }

  func brightnessControllableDisplays() -> [Display] {
    DisplayManager.shared.displays.filter { display in
      guard !display.isDummy else {
        return false
      }
      if let otherDisplay = display as? OtherDisplay {
        return !otherDisplay.isDiscouraged && (otherDisplay.isSw() || !otherDisplay.readPrefAsBool(key: .unavailableDDC, for: .brightness))
      }
      return display is AppleDisplay
    }
  }

  func masterBrightnessBaseline(for display: Display) -> Float {
    if display.prefExists(key: .masterBrightnessBaseline) {
      return display.readPrefAsFloat(key: .masterBrightnessBaseline)
    }
    let baseline = display.getBrightness()
    display.savePref(baseline, key: .masterBrightnessBaseline)
    return baseline
  }

  func applyMasterBrightness(value: Float) {
    for display in self.brightnessControllableDisplays() {
      let targetBrightness = self.masterBrightnessBaseline(for: display) * value
      if display.setBrightness(targetBrightness), let sliderHandler = display.sliderHandler[.brightness] {
        sliderHandler.setValue(targetBrightness, displayID: display.identifier)
      }
    }
  }

  func makeMenuIconButton(symbolName: String, alternateSymbolName: String? = nil, accessibilityDescription: String, action: Selector, target: AnyObject? = nil, alphaValue: CGFloat = 0.3) -> NSButton {
    let button = NSButton()
    button.bezelStyle = .regularSquare
    button.isBordered = false
    button.setButtonType(.momentaryChange)
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
      if let alternateSymbolName = alternateSymbolName {
        button.alternateImage = NSImage(systemSymbolName: alternateSymbolName, accessibilityDescription: accessibilityDescription)
      }
    }
    button.alphaValue = alphaValue
    button.imageScaling = .scaleProportionallyUpOrDown
    button.toolTip = accessibilityDescription
    button.action = action
    button.target = target
    return button
  }

  func addMasterBrightnessMenuBlock() {
    let title = NSLocalizedString("Master Brightness", comment: "Shown in menu")
    let sliderHandler = SliderHandler(display: nil, command: .brightness, title: title)
    sliderHandler.setValue(self.masterBrightnessValue())
    if let slider = sliderHandler.slider {
      slider.target = self
      slider.action = #selector(masterBrightnessValueChanged)
    }
    self.masterBrightnessSliderHandler = sliderHandler
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      class BlockView: NSView {
        override func draw(_: NSRect) {
          let radius = prefs.bool(forKey: PrefKey.showTickMarks.rawValue) ? CGFloat(4) : CGFloat(11)
          let outerMargin = CGFloat(15)
          let blockRect = self.frame.insetBy(dx: outerMargin, dy: outerMargin / 2 + 2).offsetBy(dx: 0, dy: outerMargin / 2 * -1 + 7)
          for i in 1 ... 5 {
            let blockPath = NSBezierPath(roundedRect: blockRect.insetBy(dx: CGFloat(i) * -1, dy: CGFloat(i) * -1), xRadius: radius + CGFloat(i) * 0.5, yRadius: radius + CGFloat(i) * 0.5)
            NSColor.black.withAlphaComponent(0.1 / CGFloat(i)).setStroke()
            blockPath.stroke()
          }
          let blockPath = NSBezierPath(roundedRect: blockRect, xRadius: radius, yRadius: radius)
          if [NSAppearance.Name.darkAqua, NSAppearance.Name.vibrantDark].contains(effectiveAppearance.name) {
            NSColor.systemGray.withAlphaComponent(0.3).setStroke()
            blockPath.stroke()
          }
          if ![NSAppearance.Name.darkAqua, NSAppearance.Name.vibrantDark].contains(effectiveAppearance.name) {
            NSColor.white.withAlphaComponent(0.5).setFill()
            blockPath.fill()
          }
        }
      }
      let contentWidth = sliderHandler.view?.frame.width ?? 200
      var contentHeight = sliderHandler.view?.frame.height ?? 22
      contentHeight += 21
      let margin = CGFloat(13)
      let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.textColor, .font: NSFont.boldSystemFont(ofSize: 12)]
      let blockNameView = NSTextField(labelWithAttributedString: NSAttributedString(string: title, attributes: attrs))
      blockNameView.frame.size.width = contentWidth - margin * 2
      blockNameView.alphaValue = 0.5
      let itemView = BlockView(frame: NSRect(x: 0, y: 0, width: contentWidth + margin * 2, height: contentHeight + margin * 2))
      sliderHandler.view?.setFrameOrigin(NSPoint(x: margin, y: margin + (margin * -1 + 1) + 13))
      if let sliderView = sliderHandler.view {
        itemView.addSubview(sliderView)
      }
      blockNameView.setFrameOrigin(NSPoint(x: margin + 13, y: contentHeight - 8))
      itemView.addSubview(blockNameView)
      let unlockButtonSize = CGFloat(13)
      let unlockButton = self.makeMenuIconButton(symbolName: "lock.fill", accessibilityDescription: NSLocalizedString("Unlock Levels", comment: "Shown in menu"), action: #selector(unlockMasterBrightnessLevels), target: self, alphaValue: 0.35)
      unlockButton.frame = NSRect(x: itemView.frame.width - margin - 13 - unlockButtonSize, y: blockNameView.frame.origin.y + (blockNameView.frame.height - unlockButtonSize) / 2, width: unlockButtonSize, height: unlockButtonSize)
      itemView.addSubview(unlockButton)
      let item = NSMenuItem()
      item.view = itemView
      self.insertItem(item, at: 0)
    } else {
      self.addSliderItem(monitorSubMenu: self, sliderHandler: sliderHandler)
      if app.macOS10() {
        let headerItem = NSMenuItem()
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.systemGray, .font: NSFont.systemFont(ofSize: 12)]
        headerItem.attributedTitle = NSAttributedString(string: title, attributes: attrs)
        self.insertItem(headerItem, at: 0)
      }
      let unlockItem = NSMenuItem(title: NSLocalizedString("Unlock Levels", comment: "Shown in menu"), action: #selector(unlockMasterBrightnessLevels), keyEquivalent: "")
      unlockItem.target = self
      self.insertItem(unlockItem, at: 0)
    }
  }

  @objc func masterBrightnessValueChanged(slider: NSSlider) {
    guard app.sleepID == 0, app.reconfigureID == 0 else {
      return
    }
    var value = slider.floatValue
    if prefs.bool(forKey: PrefKey.enableSliderSnap.rawValue) {
      let intPercent = Int(value * 100)
      let snapInterval = 25
      let snapThreshold = 3
      let closest = (intPercent + snapInterval / 2) / snapInterval * snapInterval
      if abs(closest - intPercent) <= snapThreshold {
        value = Float(closest) / 100
        slider.floatValue = value
      }
    }
    prefs.set(value, forKey: PrefKey.masterBrightnessValue.rawValue)
    self.masterBrightnessSliderHandler?.setValue(value)
    self.applyMasterBrightness(value: value)
  }

  @objc func lockMasterBrightnessLevels(_: AnyObject) {
    let displays = self.brightnessControllableDisplays()
    guard !displays.isEmpty else {
      return
    }
    for display in displays {
      display.savePref(display.getBrightness(), key: .masterBrightnessBaseline)
    }
    prefs.set(true, forKey: PrefKey.masterBrightnessLocked.rawValue)
    prefs.set(Float(1), forKey: PrefKey.masterBrightnessValue.rawValue)
    self.updateMenus(dontClose: true)
  }

  @objc func unlockMasterBrightnessLevels(_: AnyObject) {
    prefs.set(false, forKey: PrefKey.masterBrightnessLocked.rawValue)
    self.updateMenus(dontClose: true)
  }

  func isDimmingPaused() -> Bool {
    prefs.bool(forKey: PrefKey.dimmingPaused.rawValue)
  }

  @objc func toggleDimmingPause(_: AnyObject) {
    let wasPaused = self.isDimmingPaused()
    if wasPaused {
      prefs.set(false, forKey: PrefKey.dimmingPaused.rawValue)
      for display in self.brightnessControllableDisplays() {
        let savedValue = display.readPrefAsFloat(for: .brightness)
        _ = display.setBrightness(savedValue)
        if let slider = display.sliderHandler[.brightness] {
          slider.setValue(savedValue, displayID: display.identifier)
        }
      }
    } else {
      prefs.set(true, forKey: PrefKey.dimmingPaused.rawValue)
      for display in self.brightnessControllableDisplays() {
        _ = display.setDirectBrightness(1)
      }
    }
    self.updateMenus(dontClose: true)
  }

  func addDefaultMenuOptions() {
    let menuItemStyle = prefs.integer(forKey: PrefKey.menuItemStyle.rawValue)
    let showLockControl = !self.isMasterBrightnessLocked() && !self.brightnessControllableDisplays().isEmpty
    if !DEBUG_MACOS10, #available(macOS 11.0, *), menuItemStyle == MenuItemStyle.icon.rawValue {
      let iconSize = CGFloat(18)
      let viewWidth = max(130, self.size.width)
      var compensateForBlock: CGFloat = 0
      if viewWidth > 230 { // if there are display blocks, we need to compensate a bit for the negative inset of the blocks
        compensateForBlock = 4
      }

      let menuItemView = NSView(frame: NSRect(x: 0, y: 0, width: viewWidth, height: iconSize + 10))

      let settingsIcon = self.makeMenuIconButton(symbolName: "gearshape", alternateSymbolName: "gearshape.fill", accessibilityDescription: NSLocalizedString("Settings…", comment: "Shown in menu"), action: #selector(app.prefsClicked))
      let lockIcon = self.makeMenuIconButton(symbolName: "lock.open.fill", accessibilityDescription: NSLocalizedString("Lock Levels", comment: "Shown in menu"), action: #selector(lockMasterBrightnessLevels), target: self)
      var symbolName = prefs.bool(forKey: PrefKey.showTickMarks.rawValue) ? "arrow.left.arrow.right.square" : "arrow.triangle.2.circlepath.circle"
      let updateIcon = self.makeMenuIconButton(symbolName: symbolName, alternateSymbolName: symbolName + ".fill", accessibilityDescription: NSLocalizedString("Check for updates…", comment: "Shown in menu"), action: #selector(app.updaterController.checkForUpdates(_:)), target: app.updaterController)
      symbolName = prefs.bool(forKey: PrefKey.showTickMarks.rawValue) ? "multiply.square" : "xmark.circle"
      let quitIcon = self.makeMenuIconButton(symbolName: symbolName, alternateSymbolName: symbolName + ".fill", accessibilityDescription: NSLocalizedString("Quit", comment: "Shown in menu"), action: #selector(app.quitClicked))

      let isPaused = self.isDimmingPaused()
      let pauseSymbol = isPaused ? "play.fill" : "pause.fill"
      let pauseLabel = isPaused ? NSLocalizedString("Resume Dimming", comment: "Shown in menu") : NSLocalizedString("Pause Dimming", comment: "Shown in menu")
      let pauseIcon = self.makeMenuIconButton(symbolName: pauseSymbol, accessibilityDescription: pauseLabel, action: #selector(toggleDimmingPause), target: self, alphaValue: isPaused ? 0.6 : 0.3)
      var buttons = [quitIcon, updateIcon, settingsIcon, pauseIcon]
      if showLockControl {
        buttons.append(lockIcon)
      }
      var currentX = menuItemView.frame.maxX - iconSize - 17 + compensateForBlock
      for button in buttons {
        button.frame = NSRect(x: currentX, y: menuItemView.frame.origin.y + 5, width: iconSize, height: iconSize)
        menuItemView.addSubview(button)
        currentX -= iconSize + 8
      }
      let item = NSMenuItem()
      item.view = menuItemView
      self.insertItem(item, at: self.items.count)
    } else if showLockControl || menuItemStyle != MenuItemStyle.hide.rawValue {
      if self.items.count > 0, (app.macOS10() || menuItemStyle == MenuItemStyle.hide.rawValue) {
        self.insertItem(NSMenuItem.separator(), at: self.items.count)
      }
      let pauseTitle = self.isDimmingPaused() ? NSLocalizedString("Resume Dimming", comment: "Shown in menu") : NSLocalizedString("Pause Dimming", comment: "Shown in menu")
      let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(toggleDimmingPause), keyEquivalent: "")
      pauseItem.target = self
      self.insertItem(pauseItem, at: self.items.count)
      if showLockControl {
        let lockItem = NSMenuItem(title: NSLocalizedString("Lock Levels", comment: "Shown in menu"), action: #selector(lockMasterBrightnessLevels), keyEquivalent: "")
        lockItem.target = self
        self.insertItem(lockItem, at: self.items.count)
      }
      if menuItemStyle != MenuItemStyle.hide.rawValue {
        self.insertItem(withTitle: NSLocalizedString("Settings…", comment: "Shown in menu"), action: #selector(app.prefsClicked), keyEquivalent: ",", at: self.items.count)
        let updateItem = NSMenuItem(title: NSLocalizedString("Check for updates…", comment: "Shown in menu"), action: #selector(app.updaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = app.updaterController
        self.insertItem(updateItem, at: self.items.count)
        self.insertItem(withTitle: NSLocalizedString("Quit", comment: "Shown in menu"), action: #selector(app.quitClicked), keyEquivalent: "q", at: self.items.count)
      }
    }
  }
}
