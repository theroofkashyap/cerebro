import CoreMotion

/// Streams head rotation from motion-capable headphones as per-sample yaw/pitch deltas.
final class HeadTracker: NSObject, CMHeadphoneMotionManagerDelegate {
    enum State: String {
        case unsupported = "motion not supported on this Mac"
        case denied = "motion access denied"
        case waiting = "not connected"
        case connected = "connected, no motion data yet"
        case streaming = "tracking"
    }

    /// Called on the main queue with the rotation (radians) since the previous sample.
    var onDelta: ((_ dYaw: Double, _ dPitch: Double, _ dt: TimeInterval) -> Void)?
    var onStateChange: ((State) -> Void)?

    private(set) var state = State.waiting {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    /// Samples per second, measured over the last second or so; 0 until known.
    private(set) var sampleRate = 0.0

    var statusText: String {
        state == .streaming && sampleRate > 0
            ? "\(state.rawValue) · \(Int(sampleRate.rounded())) Hz"
            : state.rawValue
    }

    private let manager = CMHeadphoneMotionManager()
    private var last: (yaw: Double, pitch: Double, time: TimeInterval)?
    private var window: (start: TimeInterval, count: Int)?
    private var isConnected = false
    // System uptime when the latest sample arrived.
    private var lastArrival: TimeInterval = 0
    // A longer silence than this means the stream restarted, so the next delta would be bogus.
    private let maxGap: TimeInterval = 0.5
    // Samples normally arrive every 20 ms or so; this long without one means the stream has stopped.
    private let staleAfter: TimeInterval = 1

    func start() {
        guard manager.isDeviceMotionAvailable else {
            state = .unsupported
            return
        }
        manager.delegate = self
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self else { return }
            guard let motion else {
                if let error { NSLog("Head tracking error: %@", error.localizedDescription) }
                if CMHeadphoneMotionManager.authorizationStatus() == .denied { self.state = .denied }
                return
            }
            self.handle(motion)
        }
        // The disconnect callback can be overtaken by a late sample or never arrive, so also watch for silence.
        let watchdog = Timer(timeInterval: staleAfter, repeats: true) { [weak self] _ in self?.checkForSilence() }
        RunLoop.main.add(watchdog, forMode: .common)
    }

    private func checkForSilence() {
        guard state == .streaming, ProcessInfo.processInfo.systemUptime - lastArrival > staleAfter else { return }
        state = isConnected ? .connected : .waiting
        resetStream()
    }

    private func resetStream() {
        last = nil
        window = nil
        sampleRate = 0
    }

    private func handle(_ motion: CMDeviceMotion) {
        state = .streaming
        lastArrival = ProcessInfo.processInfo.systemUptime
        let yaw = motion.attitude.yaw, pitch = motion.attitude.pitch, time = motion.timestamp
        defer { last = (yaw, pitch, time) }
        measureRate(at: time)

        guard let last, time > last.time, time - last.time < maxGap else { return }
        // Yaw wraps at ±π; take the short way round.
        let dYaw = atan2(sin(yaw - last.yaw), cos(yaw - last.yaw))
        onDelta?(dYaw, pitch - last.pitch, time - last.time)
    }

    private func measureRate(at time: TimeInterval) {
        guard let current = window else {
            window = (time, 0)
            return
        }
        let count = current.count + 1
        if time - current.start >= 1 {
            if sampleRate == 0 { NSLog("Head tracking: receiving %.0f samples/s", Double(count) / (time - current.start)) }
            sampleRate = Double(count) / (time - current.start)
            window = (time, 0)
        } else {
            window = (current.start, count)
        }
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        isConnected = true
        if state != .streaming { state = .connected }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        isConnected = false
        state = .waiting
        resetStream()
    }
}
