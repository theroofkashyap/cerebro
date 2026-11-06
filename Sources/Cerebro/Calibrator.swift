import Combine
import Foundation

/// Walks the user through the calibration targets and records how far they turn for each.
final class Calibrator: ObservableObject {
    enum Step: Equatable {
        case welcome, centre, direction(Direction), activation, done
    }

    private static let targets: [Step] = [
        .centre, .direction(.left), .direction(.right), .direction(.up), .direction(.down), .activation,
    ]

    @Published private(set) var step = Step.welcome
    /// 0...1 while the head is held still on the current target.
    @Published private(set) var holdProgress = 0.0
    /// A nudge shown when the head is resting somewhere that can't be accepted.
    @Published private(set) var hint: String?
    @Published var earbudsReady = false
    @Published var accessibilityGranted = false

    var onFinish: ((Calibration) -> Void)?

    var stepLabel: String {
        guard let index = Self.targets.firstIndex(of: step) else { return "" }
        return "Step \(index + 1) of \(Self.targets.count)"
    }

    var instruction: String {
        switch step {
        case .welcome, .done: return ""
        case .centre: return "Look at the centre dot and hold still"
        case .direction(let direction): return "Turn your head toward the dot \(Self.place(direction)), then hold still"
        case .activation: return "Turn left and lift your chin toward the top-left circle, then hold still"
        }
    }

    var detail: String {
        switch step {
        case .welcome, .done: return ""
        case .centre: return "Sit the way you normally do. This becomes your resting position."
        case .direction: return "Move your head, not just your eyes. Go only as far as feels comfortable."
        case .activation: return "This is your activation gesture. Holding it switches head shortcuts on."
        }
    }

    // Raw head pose accumulated since calibration began, and its value at the centre dot.
    private var pose = HeadVector.zero
    private var centre = HeadVector.zero
    private var recorded: [Direction: HeadVector] = [:]
    private var heldFor: TimeInterval = 0

    private let holdTime: TimeInterval = 0.8
    // Moving slower than this (°/s) counts as holding still.
    private let stillSpeed = 15.0
    // Turns smaller than this (°) are too close to resting to tell apart.
    private let minExcursion = 5.0
    // How much of a full look up, and of a full look left, the activation pose must contain.
    // Without a clear upward part, an ordinary look to the left would set it off.
    private let minActivationUp = 0.7
    private let minActivationLeft = 0.4

    /// Returns to the welcome step.
    func restart() {
        step = .welcome
        holdProgress = 0
        hint = nil
    }

    func begin() {
        pose = .zero
        centre = .zero
        recorded = [:]
        heldFor = 0
        holdProgress = 0
        hint = nil
        step = .centre
    }

    func feed(_ delta: HeadVector, dt: TimeInterval) {
        guard dt > 0 else { return }
        pose = pose + delta
        let still = delta.length / dt < stillSpeed
        let offset = pose - centre

        switch step {
        case .welcome, .done:
            return
        case .centre:
            hold(still, dt: dt) { centre = pose }
        case .direction(let direction):
            hold(still && accepts(offset, for: direction), dt: dt) { recorded[direction] = offset }
        case .activation:
            guard let left = recorded[.left], let right = recorded[.right],
                  let up = recorded[.up], let down = recorded[.down] else { return }
            let calibration = Calibration(left: left, right: right, up: up, down: down, activation: offset).withinLimits()
            let (x, y) = calibration.coordinates(of: offset)
            let highEnough = y >= minActivationUp, farEnough = x <= -minActivationLeft
            // Only nudge once the head is resting somewhere toward the corner, not while it is still on its way.
            let resting = still && (x <= -0.2 || y >= 0.3)
            let nudge = !resting ? nil : !highEnough ? "Lift your chin a little more" : !farEnough ? "Turn a little further left" : nil
            if hint != nudge { hint = nudge }
            hold(still && highEnough && farEnough, dt: dt) { onFinish?(calibration) }
        }
    }

    /// Counts up while `condition` holds; once it has held long enough, records the target and moves on.
    private func hold(_ condition: Bool, dt: TimeInterval, record: () -> Void) {
        heldFor = condition ? heldFor + dt : 0
        let progress = min(heldFor / holdTime, 1)
        if progress != holdProgress { holdProgress = progress }
        guard heldFor >= holdTime else { return }

        record()
        heldFor = 0
        holdProgress = 0
        hint = nil
        let index = Self.targets.firstIndex(of: step)!
        step = index + 1 < Self.targets.count ? Self.targets[index + 1] : .done
    }

    // The sensor's sign conventions aren't known up front, so the first turn on each axis is taken
    // on trust and the opposite one must point the other way.
    private func accepts(_ offset: HeadVector, for direction: Direction) -> Bool {
        guard offset.length >= minExcursion else { return false }
        let sideways = abs(offset.yaw) > abs(offset.pitch)
        switch direction {
        case .left: return sideways
        case .right: return sideways && offset.dot(recorded[.left] ?? .zero) < 0
        case .up: return !sideways
        case .down: return !sideways && offset.dot(recorded[.up] ?? .zero) < 0
        }
    }

    private static func place(_ direction: Direction) -> String {
        switch direction {
        case .left: return "on the left"
        case .right: return "on the right"
        case .up: return "at the top"
        case .down: return "at the bottom"
        }
    }
}
