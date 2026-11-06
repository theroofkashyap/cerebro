import Foundation

/// A head offset in degrees, in the sensor's own axes. Which way is positive is learned during calibration.
struct HeadVector: Codable, Equatable {
    var yaw: Double
    var pitch: Double

    static let zero = HeadVector(yaw: 0, pitch: 0)

    var length: Double { hypot(yaw, pitch) }

    static func + (a: HeadVector, b: HeadVector) -> HeadVector { HeadVector(yaw: a.yaw + b.yaw, pitch: a.pitch + b.pitch) }
    static func - (a: HeadVector, b: HeadVector) -> HeadVector { HeadVector(yaw: a.yaw - b.yaw, pitch: a.pitch - b.pitch) }
    static func * (v: HeadVector, scale: Double) -> HeadVector { HeadVector(yaw: v.yaw * scale, pitch: v.pitch * scale) }

    func dot(_ other: HeadVector) -> Double { yaw * other.yaw + pitch * other.pitch }

    /// The same direction, rescaled if needed so its length lies between `shortest` and `longest` degrees.
    func clamped(from shortest: Double, to longest: Double) -> HeadVector {
        guard length > 0 else { return self }
        return self * (min(max(length, shortest), longest) / length)
    }
}

enum Direction: String, CaseIterable, Codable {
    case left, right, up, down

    var title: String { "Look " + rawValue.capitalized }
}

/// One person's comfortable head turns, recorded on the calibration screen.
struct Calibration: Codable {
    var left: HeadVector
    var right: HeadVector
    var up: HeadVector
    var down: HeadVector
    /// The pose that switches listening on: up and to the left, held briefly.
    var activation: HeadVector

    /// Used until the user calibrates; assumes yaw grows turning left and pitch grows looking up.
    static let fallback = Calibration(
        left: HeadVector(yaw: 18, pitch: 0), right: HeadVector(yaw: -18, pitch: 0),
        up: HeadVector(yaw: 0, pitch: 12), down: HeadVector(yaw: 0, pitch: -12),
        activation: HeadVector(yaw: 15, pitch: 10))

    /// Rescales the recorded turns into a workable range: long enough that ordinary small movements
    /// don't trigger anything, short enough that a shortcut doesn't need a big turn.
    func withinLimits() -> Calibration {
        Calibration(left: left.clamped(from: 12, to: 25), right: right.clamped(from: 12, to: 25),
                    up: up.clamped(from: 8, to: 16), down: down.clamped(from: 8, to: 16),
                    activation: activation)
    }

    /// Where `offset` sits between the calibrated turns: x is +1 at a full look right and -1 at a full
    /// look left, y is +1 at a full look up and -1 at a full look down.
    ///
    /// The recorded turns are rarely at right angles (a look to the side usually dips a little), so this
    /// solves for the mix of the two nearest turns instead of measuring against each one separately.
    func coordinates(of offset: HeadVector) -> (x: Double, y: Double) {
        for (sideways, xSign) in [(right, 1.0), (left, -1.0)] {
            for (vertical, ySign) in [(up, 1.0), (down, -1.0)] {
                let determinant = sideways.yaw * vertical.pitch - sideways.pitch * vertical.yaw
                guard abs(determinant) > 1e-9 else { continue }
                let a = (offset.yaw * vertical.pitch - offset.pitch * vertical.yaw) / determinant
                let b = (sideways.yaw * offset.pitch - sideways.pitch * offset.yaw) / determinant
                if a >= -1e-9, b >= -1e-9 { return (a * xSign, b * ySign) }
            }
        }
        return (0, 0)
    }
}

/// Watches head movement for the activation pose, then for one look held in a direction.
final class GestureEngine {
    enum Event {
        case armed
        /// Head position while armed, as `Calibration.coordinates(of:)`.
        case moved(x: Double, y: Double, candidate: Direction?)
        case fired(Direction)
        /// Listening ended without a shortcut; the text says why, for the log.
        case cancelled(String)
    }

    var calibration = Calibration.fallback
    var onEvent: ((Event) -> Void)?

    var isArmed: Bool {
        if case .armed = state { return true }
        return false
    }

    private enum State {
        case idle(held: TimeInterval)
        case armed(elapsed: TimeInterval, centred: Bool, candidate: Direction?, held: TimeInterval)
    }

    private var state = State.idle(held: 0)
    // Head offset from its resting pose.
    private var offset = HeadVector.zero
    // The furthest the head got from centre while armed, to explain a timeout in the log.
    private var furthest = 0.0

    // While idle the resting pose follows the head with this time constant (s), so the pose is
    // always "relative to wherever you were facing" and sideways sensor drift is absorbed.
    private let restingTau = 5.0
    // Fraction of the calibrated activation pose that must be reached, and for how long (s).
    // People repeat a pose less emphatically than they recorded it, hence well under 1.
    private let activationReach = 0.6
    private let activationHold = 0.5
    // Fractions of a calibrated turn that count as looking that way, and as back at centre.
    private let directionReach = 0.6
    private let centreReach = 0.3
    // How long (s) a direction must be held before its shortcut fires, so a passing glance doesn't count.
    private let directionHold = 0.4
    // A look only counts toward a direction if the off-axis part is at most this fraction of it.
    private let maxStray = 0.6
    // Listening ends after this long (s) without a shortcut firing.
    private let armedTimeout = 6.0
    // After activating, the head must come back to centre within this long (s).
    private let centreTimeout = 3.0

    func feed(_ delta: HeadVector, dt: TimeInterval) {
        offset = offset + delta

        switch state {
        case .idle(let held):
            offset = offset * exp(-dt / restingTau)
            let now = calibration.coordinates(of: offset)
            let pose = calibration.coordinates(of: calibration.activation)
            // Both parts of the pose must be there, so a plain look to one side doesn't count.
            let atPose = reaches(now.x, pose.x) && reaches(now.y, pose.y)
            let nowHeld = atPose ? held + dt : 0
            if nowHeld >= activationHold {
                furthest = 0
                state = .armed(elapsed: 0, centred: false, candidate: nil, held: 0)
                onEvent?(.armed)
            } else {
                state = .idle(held: nowHeld)
            }

        case .armed(let elapsed, var centred, var candidate, var held):
            guard elapsed + dt < armedTimeout, centred || elapsed + dt < centreTimeout else {
                cancel(centred ? String(format: "no direction held, furthest was %.0f%% of a full turn", furthest * 100)
                    : "head stayed at the activation pose")
                return
            }
            let (x, y) = calibration.coordinates(of: offset)
            let reach = max(abs(x), abs(y))
            if !centred {
                // The activation pose itself points left and up, so wait for the head to come back first.
                centred = reach < centreReach
            } else {
                furthest = max(furthest, reach)
                if reach >= directionReach, min(abs(x), abs(y)) <= reach * maxStray {
                    let pointed: Direction = abs(x) >= abs(y) ? (x > 0 ? .right : .left) : (y > 0 ? .up : .down)
                    held = pointed == candidate ? held + dt : 0
                    candidate = pointed
                    if held >= directionHold {
                        // The head is still turned; treat that as the new resting pose so coming back does nothing.
                        offset = .zero
                        state = .idle(held: 0)
                        onEvent?(.fired(pointed))
                        return
                    }
                } else {
                    candidate = nil
                    held = 0
                }
            }
            state = .armed(elapsed: elapsed + dt, centred: centred, candidate: candidate, held: held)
            onEvent?(.moved(x: x, y: y, candidate: candidate))
        }
    }

    /// Forgets the current pose, e.g. after the motion stream stops.
    func reset() {
        if isArmed {
            cancel("tracking stopped")
        } else {
            offset = .zero
            state = .idle(held: 0)
        }
    }

    private func reaches(_ value: Double, _ target: Double) -> Bool {
        // The pose's own coordinates are capped at a full turn, so an extreme calibration stays reachable.
        value * (target < 0 ? -1 : 1) >= activationReach * min(abs(target), 1)
    }

    private func cancel(_ reason: String) {
        // Whatever the head is doing now becomes the resting pose, so a pose that is simply being
        // held (say, looking at a second screen) can't activate again straight away.
        offset = .zero
        state = .idle(held: 0)
        onEvent?(.cancelled(reason))
    }
}
