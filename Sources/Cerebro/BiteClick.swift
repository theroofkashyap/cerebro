import CoreGraphics
import Foundation

/// Turns bites into clicks for the head cursor.
final class BiteClick {
    enum Action: String, CaseIterable {
        case none, click, rightClick, doubleClick

        var title: String {
            switch self {
            case .none: return "Nothing"
            case .click: return "Click"
            case .rightClick: return "Right Click"
            case .doubleClick: return "Double Click"
            }
        }
    }

    var single = Action.click
    var double = Action.rightClick {
        // With nothing to do on a double bite, there is no reason to make a single one wait for it.
        didSet { detector.listensForDouble = double != .none }
    }
    var threshold: Double {
        get { detector.threshold }
        set { detector.threshold = newValue }
    }
    /// True while something else is using head movement, so bites must not click.
    var isBlocked: () -> Bool = { false }
    var onClick: (() -> Void)?

    private let pointer: Pointer
    private let detector = BiteDetector()
    // Where the cursor has been over the last second or so, by sensor time.
    private var trail: [(time: TimeInterval, position: CGPoint)] = []
    // A bite shakes the earbud, which nudges the cursor, so the click goes where the cursor was this long (s) before it.
    private let lead = 0.1

    init(pointer: Pointer) {
        self.pointer = pointer
        detector.onBite = { [weak self] bite, time in self?.act(on: bite, at: time) }
    }

    func feed(_ sample: MotionSample) {
        guard !isBlocked() else {
            reset()
            return
        }
        if let position = pointer.position {
            trail.append((sample.time, position))
            if trail.count > 100 { trail.removeFirst() }
        }
        detector.feed(sample)
    }

    func reset() {
        detector.reset()
        trail = []
    }

    private func act(on bite: BiteDetector.Bite, at time: TimeInterval) {
        let action = bite == .single ? single : double
        guard action != .none else { return }
        let position = trail.last { $0.time <= time - lead }?.position
        // Drop whatever movement the bite itself queued, so the cursor stays where the click lands.
        pointer.stop()
        switch action {
        case .none: break
        case .click: pointer.click(.left, at: position)
        case .rightClick: pointer.click(.right, at: position)
        case .doubleClick: pointer.click(.left, at: position, count: 2)
        }
        NSLog("Bite: %@ -> %@", bite == .single ? "single" : "double", action.title)
        onClick?()
    }
}
