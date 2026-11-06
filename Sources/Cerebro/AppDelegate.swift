import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let sensitivities: [(name: String, pointsPerRadian: Double)] = [
        ("Low", 2400), ("Medium", 3600), ("High", 5400),
    ]

    private let tracker = HeadTracker()
    private let pointer = Pointer()
    private let buttons = RemoteButtons()
    private let gestures = GestureEngine()
    private let overlay = Overlay()
    private let onboarding = Onboarding()
    private var hotKey: HotKey?
    private let testSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let defaults = UserDefaults.standard

    private var paused = false
    private var shortcutsEnabled = true
    private var headCursorEnabled = false
    private var accessibilityGranted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["sensitivity": pointer.sensitivity, "shortcutsEnabled": true])
        pointer.sensitivity = defaults.double(forKey: "sensitivity")
        pointer.invertX = defaults.bool(forKey: "invertX")
        pointer.invertY = defaults.bool(forKey: "invertY")
        shortcutsEnabled = defaults.bool(forKey: "shortcutsEnabled")
        headCursorEnabled = defaults.bool(forKey: "headCursorEnabled")

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        // Synthetic keystrokes and mouse events are silently dropped until the user grants Accessibility access.
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(prompt)
        onboarding.calibrator.accessibilityGranted = accessibilityGranted
        NSLog("Accessibility access: %@", accessibilityGranted ? "granted" : "not granted")
        // The grant can change while the app is running, so keep checking.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkAccessibility() }

        tracker.onStateChange = { [weak self] in self?.trackerChanged(to: $0) }
        tracker.onDelta = { [weak self] dYaw, dPitch, dt in self?.headMoved(dYaw: dYaw, dPitch: dPitch, dt: dt) }
        tracker.start()
        NSLog("Head tracking: %@", tracker.state.rawValue)

        gestures.onEvent = { [weak self] in self?.handle($0) }
        let saved = defaults.data(forKey: "calibration").flatMap { try? JSONDecoder().decode(Calibration.self, from: $0) }
        if let saved { gestures.calibration = saved.withinLimits() }
        onboarding.calibrator.onFinish = { [weak self] in self?.save($0) }

        buttons.onSinglePress = { [weak self] in self?.pointer.click(.left) }
        buttons.onDoublePress = { [weak self] in self?.pointer.click(.right) }
        buttons.onTriplePress = { [weak self] in self?.togglePause() }
        buttons.start()
        buttons.setActive(headCursorEnabled)

        hotKey = HotKey(keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey) { [weak self] in self?.togglePause() }
        if hotKey == nil { NSLog("Could not register the ⌃⌥M hotkey") }

        // For testing keystroke delivery without the earbuds: `kill -USR1 <pid>` fires the Look Down shortcut.
        signal(SIGUSR1, SIG_IGN)
        testSignal.setEventHandler { [weak self] in self?.handle(.fired(.down)) }
        testSignal.resume()

        if saved == nil { showOnboarding() }
    }

    // MARK: Head input

    private func headMoved(dYaw: Double, dPitch: Double, dt: TimeInterval) {
        guard !paused else { return }
        let delta = HeadVector(yaw: dYaw * 180 / .pi, pitch: dPitch * 180 / .pi)
        // Once calibration has finished, shortcuts are live even with its window still open,
        // so the finish screen is a place to try them.
        if onboarding.isActive, onboarding.calibrator.step != .done {
            onboarding.calibrator.feed(delta, dt: dt)
            return
        }
        if shortcutsEnabled { gestures.feed(delta, dt: dt) }
        // While shortcuts are listening, head movement picks a direction instead of moving the cursor.
        if headCursorEnabled, !gestures.isArmed { pointer.move(dYaw: dYaw, dPitch: dPitch, dt: dt) }
    }

    private func trackerChanged(to state: HeadTracker.State) {
        NSLog("Head tracking: %@", state.rawValue)
        onboarding.calibrator.earbudsReady = state == .streaming
        if state != .streaming { gestures.reset() }
    }

    private func handle(_ event: GestureEngine.Event) {
        switch event {
        case .armed:
            NSLog("Gesture: activated")
            overlay.show(labels: Dictionary(uniqueKeysWithValues: Direction.allCases.map { ($0, shortcut(for: $0).title) }))
        case let .moved(x, y, candidate):
            overlay.update(x: x, y: y, candidate: candidate)
        case let .fired(direction):
            let shortcut = shortcut(for: direction)
            NSLog("Gesture: %@ fired %@", direction.rawValue, shortcut.title)
            overlay.hide()
            // Give the overlay a moment to leave the screen so it isn't caught in a screenshot.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { shortcut.perform() }
        case .cancelled(let reason):
            NSLog("Gesture: cancelled, %@", reason)
            overlay.hide()
        }
    }

    private func shortcut(for direction: Direction) -> ShortcutAction {
        ShortcutAction.named(defaults.string(forKey: "shortcut.\(direction.rawValue)"))
            ?? ShortcutAction.named(ShortcutAction.defaults[direction])
            ?? ShortcutAction.all[0]
    }

    private func save(_ calibration: Calibration) {
        gestures.calibration = calibration
        defaults.set(try? JSONEncoder().encode(calibration), forKey: "calibration")
        // Calibration shows which way the sensor's axes run, so the head cursor no longer has to guess.
        pointer.invertX = calibration.left.yaw < 0
        pointer.invertY = calibration.up.pitch < 0
        defaults.set(pointer.invertX, forKey: "invertX")
        defaults.set(pointer.invertY, forKey: "invertY")
        let describe = { (vector: HeadVector) in String(format: "(%.1f, %.1f)", vector.yaw, vector.pitch) }
        NSLog("Calibration saved (yaw, pitch in degrees): left %@ right %@ up %@ down %@ activation %@",
              describe(calibration.left), describe(calibration.right), describe(calibration.up),
              describe(calibration.down), describe(calibration.activation))
    }

    private func checkAccessibility() {
        let granted = AXIsProcessTrusted()
        guard granted != accessibilityGranted else { return }
        accessibilityGranted = granted
        onboarding.calibrator.accessibilityGranted = granted
        NSLog("Accessibility access: %@", granted ? "granted" : "not granted")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Headphones: \(tracker.statusText)", action: nil, keyEquivalent: "")
        if !accessibilityGranted {
            menu.addItem(withTitle: "Grant Accessibility Access…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        }
        menu.addItem(.separator())

        menu.addItem(withTitle: "Head Shortcuts", action: #selector(toggleShortcuts), keyEquivalent: "")
            .state = shortcutsEnabled ? .on : .off
        let shortcuts = NSMenu()
        for direction in Direction.allCases {
            let current = shortcut(for: direction)
            let choices = NSMenu()
            for option in ShortcutAction.all {
                let item = choices.addItem(withTitle: option.menuTitle, action: #selector(setShortcut(_:)), keyEquivalent: "")
                item.representedObject = [direction.rawValue, option.id]
                item.state = option.id == current.id ? .on : .off
            }
            shortcuts.addItem(withTitle: "\(direction.title): \(current.title)", action: nil, keyEquivalent: "").submenu = choices
        }
        menu.addItem(withTitle: "Shortcuts", action: nil, keyEquivalent: "").submenu = shortcuts
        menu.addItem(withTitle: "Calibrate…", action: #selector(showOnboarding), keyEquivalent: "")
        menu.addItem(.separator())

        let cursor = NSMenu()
        cursor.addItem(withTitle: "Move Cursor With Head", action: #selector(toggleHeadCursor), keyEquivalent: "")
            .state = headCursorEnabled ? .on : .off
        cursor.addItem(.separator())
        let sensitivity = NSMenu()
        for option in Self.sensitivities {
            let item = sensitivity.addItem(withTitle: option.name, action: #selector(setSensitivity(_:)), keyEquivalent: "")
            item.representedObject = option.pointsPerRadian
            item.state = option.pointsPerRadian == pointer.sensitivity ? .on : .off
        }
        cursor.addItem(withTitle: "Sensitivity", action: nil, keyEquivalent: "").submenu = sensitivity
        cursor.addItem(withTitle: "Invert Horizontal", action: #selector(toggleInvertX), keyEquivalent: "")
            .state = pointer.invertX ? .on : .off
        cursor.addItem(withTitle: "Invert Vertical", action: #selector(toggleInvertY), keyEquivalent: "")
            .state = pointer.invertY ? .on : .off
        cursor.addItem(withTitle: "Reclaim Headphone Buttons", action: #selector(reclaimButtons), keyEquivalent: "")
        menu.addItem(withTitle: "Head Cursor", action: nil, keyEquivalent: "").submenu = cursor
        menu.addItem(.separator())

        let pause = menu.addItem(withTitle: paused ? "Resume Tracking" : "Pause Tracking",
                                 action: #selector(togglePause), keyEquivalent: "m")
        pause.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(withTitle: "Quit Cerebro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func refreshIcon() {
        // The logo's mark, dimmed while paused. Without a logo file, a system symbol stands in.
        let symbol = paused ? "cursorarrow.slash" : "cursorarrow.motionlines"
        let image = Logo.markImage(height: 16) ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.accessibilityDescription = "Cerebro"
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = paused
    }

    // MARK: Actions

    @objc private func togglePause() {
        paused.toggle()
        if paused {
            pointer.stop()
            gestures.reset()
        } else if headCursorEnabled {
            buttons.claim()
        }
        refreshIcon()
    }

    @objc private func showOnboarding() {
        pointer.stop()
        gestures.reset()
        onboarding.calibrator.earbudsReady = tracker.state == .streaming
        onboarding.show(shortcuts: Direction.allCases.map { ($0.title, shortcut(for: $0).title) })
    }

    @objc private func toggleShortcuts() {
        shortcutsEnabled.toggle()
        defaults.set(shortcutsEnabled, forKey: "shortcutsEnabled")
        if !shortcutsEnabled { gestures.reset() }
    }

    @objc private func setShortcut(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? [String], choice.count == 2 else { return }
        defaults.set(choice[1], forKey: "shortcut.\(choice[0])")
    }

    @objc private func toggleHeadCursor() {
        headCursorEnabled.toggle()
        defaults.set(headCursorEnabled, forKey: "headCursorEnabled")
        buttons.setActive(headCursorEnabled)
        if !headCursorEnabled { pointer.stop() }
    }

    @objc private func reclaimButtons() {
        buttons.setActive(headCursorEnabled)
    }

    @objc private func setSensitivity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        pointer.sensitivity = value
        defaults.set(value, forKey: "sensitivity")
    }

    @objc private func toggleInvertX() {
        pointer.invertX.toggle()
        defaults.set(pointer.invertX, forKey: "invertX")
    }

    @objc private func toggleInvertY() {
        pointer.invertY.toggle()
        defaults.set(pointer.invertY, forKey: "invertY")
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
