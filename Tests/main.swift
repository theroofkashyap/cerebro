import Foundation

// Simulated 50 Hz head motion fed through the real GestureEngine and Calibrator.

let dt = 0.02
var failures = 0

extension Calibration {
    subscript(direction: Direction) -> HeadVector {
        switch direction {
        case .left: return left
        case .right: return right
        case .up: return up
        case .down: return down
        }
    }
}

func check(_ condition: Bool, _ name: String) {
    print(condition ? "PASS" : "FAIL", name)
    if !condition { failures += 1 }
}

/// Moves the head by `by` over `seconds`, in equal steps.
func move(_ by: HeadVector, over seconds: Double, feed: (HeadVector, Double) -> Void) {
    let steps = max(Int(seconds / dt), 1)
    for _ in 0..<steps { feed(by * (1.0 / Double(steps)), dt) }
}

func hold(_ seconds: Double, feed: (HeadVector, Double) -> Void) {
    for _ in 0..<Int(seconds / dt) { feed(.zero, dt) }
}

// MARK: Gesture engine

func runEngine(_ script: (GestureEngine, (HeadVector, Double) -> Void) -> Void) -> [String] {
    let engine = GestureEngine()
    var events: [String] = []
    engine.onEvent = { event in
        switch event {
        case .armed: events.append("armed")
        case .moved: break
        case .fired(let direction): events.append("fired \(direction.rawValue)")
        case .cancelled: events.append("cancelled")
        }
    }
    script(engine) { delta, dt in engine.feed(delta, dt: dt) }
    return events
}

let cal = Calibration.fallback
let activation = cal.activation * 0.9

for direction in Direction.allCases {
    let events = runEngine { _, feed in
        move(activation, over: 0.25, feed: feed); hold(0.7, feed: feed)
        move(activation * -1, over: 0.25, feed: feed); hold(0.3, feed: feed)
        move(cal[direction] * 0.8, over: 0.25, feed: feed); hold(0.6, feed: feed)
        move(cal[direction] * -0.8, over: 0.25, feed: feed); hold(0.3, feed: feed)
    }
    check(events == ["armed", "fired \(direction.rawValue)"], "activate then look \(direction.rawValue): \(events)")
}

check(runEngine { _, feed in
    move(cal.left * 0.9, over: 0.25, feed: feed); hold(0.5, feed: feed)
    move(cal.left * -0.9, over: 0.25, feed: feed); hold(0.5, feed: feed)
} == [], "looking left without activating does nothing")

check(runEngine { _, feed in
    move(activation, over: 0.15, feed: feed); hold(0.2, feed: feed)
    move(activation * -1, over: 0.15, feed: feed); hold(1, feed: feed)
} == [], "a brief glance up-left does not activate")

check(runEngine { _, feed in
    move(activation, over: 0.25, feed: feed); hold(0.7, feed: feed)
    move(activation * -1, over: 0.25, feed: feed); hold(7, feed: feed)
} == ["armed", "cancelled"], "activating and then doing nothing times out")

check(runEngine { _, feed in
    move(activation, over: 0.25, feed: feed); hold(0.7, feed: feed)
    // Straight from the activation pose to the right, without settling at centre first.
    move(activation * -1 + cal.right * 0.8, over: 0.3, feed: feed); hold(0.6, feed: feed)
    move(cal.right * -0.8, over: 0.25, feed: feed); hold(0.3, feed: feed)
} == ["armed", "fired right"], "sweeping from activation through centre to the right still fires right")

check(runEngine { _, feed in
    // Slow sideways drift of 1 degree per second for a minute.
    move(HeadVector(yaw: 60, pitch: 0), over: 60, feed: feed)
} == [], "slow sensor drift never activates")

let stayed = runEngine { _, feed in
    // Turn to a second screen up and to the left and stay there.
    move(cal.activation * 1.2, over: 0.4, feed: feed); hold(20, feed: feed)
}
check(stayed == ["armed", "cancelled"], "staying turned up-left activates once, then cancels and stays quiet: \(stayed)")

func near(_ a: HeadVector?, _ b: HeadVector) -> Bool {
    guard let a else { return false }
    return (a - b).length < 1e-6
}

// MARK: Calibrator, with the sensor's axes reversed from the fallback assumption

let calibrator = Calibrator()
var result: Calibration?
calibrator.onFinish = { result = $0 }
let feedCal: (HeadVector, Double) -> Void = { delta, dt in calibrator.feed(delta, dt: dt) }

calibrator.begin()
hold(1, feed: feedCal)
check(calibrator.step == .direction(.left), "centre is captured after holding still")

let turns: [(Direction, HeadVector)] = [
    (.left, HeadVector(yaw: -20, pitch: 1)), (.right, HeadVector(yaw: 22, pitch: -1)),
    (.up, HeadVector(yaw: 1, pitch: -11)), (.down, HeadVector(yaw: 0, pitch: 13)),
]
var position = HeadVector.zero
for (direction, target) in turns {
    hold(1, feed: feedCal)
    check(calibrator.step == .direction(direction), "\(direction.rawValue): holding the previous pose is not accepted")
    move(target - position, over: 0.5, feed: feedCal); hold(1, feed: feedCal)
    position = target
}
check(calibrator.step == .activation, "all four directions captured")

hold(1, feed: feedCal)
check(calibrator.step == .activation, "holding the down pose is not accepted as the activation pose")
let corner = HeadVector(yaw: -14, pitch: -8)
move(corner - position, over: 0.5, feed: feedCal); hold(1, feed: feedCal)
check(calibrator.step == .done, "activation pose captured")
check(near(result?.left, HeadVector(yaw: -20, pitch: 1)) && near(result?.right, HeadVector(yaw: 22, pitch: -1)),
      "left and right recorded with reversed yaw")
check(near(result?.up, HeadVector(yaw: 1, pitch: -11)) && near(result?.down, HeadVector(yaw: 0, pitch: 13)),
      "up and down recorded with reversed pitch")
check(abs((result?.activation.length ?? 0) - corner.length) < 0.01, "activation recorded")

// The calibration just recorded must drive the engine correctly even though its axes are reversed.
if let result {
    let engine = GestureEngine()
    engine.calibration = result
    var events: [String] = []
    engine.onEvent = { if case .fired(let d) = $0 { events.append(d.rawValue) } else if case .armed = $0 { events.append("armed") } }
    let feed: (HeadVector, Double) -> Void = { delta, dt in engine.feed(delta, dt: dt) }
    move(result.activation * 0.9, over: 0.25, feed: feed); hold(0.7, feed: feed)
    move(result.activation * -0.9, over: 0.25, feed: feed); hold(0.3, feed: feed)
    move(HeadVector(yaw: -16, pitch: 0), over: 0.25, feed: feed); hold(0.6, feed: feed)
    move(HeadVector(yaw: 16, pitch: 0), over: 0.25, feed: feed); hold(0.3, feed: feed)
    check(events == ["armed", "left"], "reversed-axis calibration: turning toward recorded left fires left: \(events)")
}

// A timid calibration is stretched so gestures don't fire on tiny movements.
let timid = Calibrator()
var timidResult: Calibration?
timid.onFinish = { timidResult = $0 }
let feedTimid: (HeadVector, Double) -> Void = { delta, dt in timid.feed(delta, dt: dt) }
timid.begin()
hold(1, feed: feedTimid)
var at = HeadVector.zero
for target in [HeadVector(yaw: 6, pitch: 0), HeadVector(yaw: -6, pitch: 0), HeadVector(yaw: 0, pitch: 5.5),
               HeadVector(yaw: 0, pitch: -5.5)] {
    move(target - at, over: 0.5, feed: feedTimid); hold(1, feed: feedTimid)
    at = target
}
// A corner pose with too little upward tilt is refused, with a nudge.
move(HeadVector(yaw: 8, pitch: 2) - at, over: 0.5, feed: feedTimid); hold(1.5, feed: feedTimid)
at = HeadVector(yaw: 8, pitch: 2)
check(timid.step == .activation && timid.hint == "Lift your chin a little more", "a flat corner pose is refused with a nudge: \(String(describing: timid.hint))")
move(HeadVector(yaw: 6, pitch: 6.5) - at, over: 0.5, feed: feedTimid); hold(1, feed: feedTimid)
check(timid.step == .done, "timid calibration completes")
check(abs((timidResult?.left.length ?? 0) - 12) < 0.01 && abs((timidResult?.up.length ?? 0) - 8) < 0.01,
      "timid turns are stretched to the minimum lengths")

// MARK: A calibration recorded from real Powerbeats Pro 2

let real = Calibration(
    left: HeadVector(yaw: 32.8, pitch: -2.6), right: HeadVector(yaw: -13.5, pitch: -2.7),
    up: HeadVector(yaw: 2.3, pitch: 7.7), down: HeadVector(yaw: 4.4, pitch: -9.9),
    activation: HeadVector(yaw: 21.7, pitch: 4.2)).withinLimits()

func runReal(_ script: ((HeadVector, Double) -> Void) -> Void) -> [String] {
    let engine = GestureEngine()
    engine.calibration = real
    var events: [String] = []
    engine.onEvent = { event in
        switch event {
        case .armed: events.append("armed")
        case .moved: break
        case .fired(let direction): events.append("fired \(direction.rawValue)")
        case .cancelled: events.append("cancelled")
        }
    }
    script { delta, dt in engine.feed(delta, dt: dt) }
    return events
}

func activateReal(_ feed: (HeadVector, Double) -> Void) {
    move(real.activation, over: 0.3, feed: feed); hold(0.7, feed: feed)
    move(real.activation * -1, over: 0.3, feed: feed); hold(0.3, feed: feed)
}

let leftCoords = real.coordinates(of: real.left)
check(abs(leftCoords.x + 1) < 1e-6 && abs(leftCoords.y) < 1e-6, "real: a full look left reads as x -1, y 0")
check(abs(real.left.length - 25) < 1e-6, "real: the 33 degree left turn is capped at 25")

for share in [0.5, 0.7, 0.9, 1.2] {
    let events = runReal { feed in
        move(real.left * share, over: 0.3, feed: feed); hold(2, feed: feed)
        move(real.left * -share, over: 0.3, feed: feed); hold(1, feed: feed)
    }
    check(events == [], "real: a plain look left (\(Int(share * 100))% of a full turn) does not activate: \(events)")
}

check(runReal { feed in
    move(HeadVector(yaw: 22, pitch: 0), over: 0.3, feed: feed); hold(2, feed: feed)
} == [], "real: a level 22 degree turn to the left does not activate")

check(runReal { feed in activateReal(feed) } == ["armed"], "real: the recorded activation pose activates")

for (name, turn) in [("left", real.left * 0.8), ("right", real.right * 0.8), ("up", real.up * 0.9), ("down", real.down * 0.9),
                     ("left", HeadVector(yaw: 18, pitch: 0)), ("right", HeadVector(yaw: -10, pitch: 0))] {
    let events = runReal { feed in
        activateReal(feed)
        move(turn, over: 0.3, feed: feed); hold(0.6, feed: feed)
        move(turn * -1, over: 0.3, feed: feed); hold(0.3, feed: feed)
    }
    check(events == ["armed", "fired \(name)"], "real: after activating, turning (\(turn.yaw), \(turn.pitch)) fires \(name): \(events)")
}

check(runReal { feed in
    activateReal(feed)
    // Look left and simply stay there, as people did on the real hardware.
    move(real.left * 0.8, over: 0.3, feed: feed); hold(5, feed: feed)
    move(real.left * -0.8, over: 0.3, feed: feed); hold(3, feed: feed)
} == ["armed", "fired left"], "real: holding a look fires once, and coming back afterwards does nothing")

check(runReal { feed in
    activateReal(feed)
    // A glance that passes through "right" without stopping.
    move(real.right * 0.9, over: 0.15, feed: feed); hold(0.1, feed: feed)
    move(real.right * -0.9, over: 0.15, feed: feed); hold(6, feed: feed)
} == ["armed", "cancelled"], "real: a passing glance to the right fires nothing")

// A later calibration from the same hardware, repeating the activation pose with less chin lift than recorded.
let latest = Calibration(
    left: HeadVector(yaw: 14.8, pitch: 1.3), right: HeadVector(yaw: -13.8, pitch: 1.2),
    up: HeadVector(yaw: -0.8, pitch: 14.9), down: HeadVector(yaw: 2.6, pitch: -12.2),
    activation: HeadVector(yaw: 19.9, pitch: 12.7)).withinLimits()
for (pose, expected) in [(HeadVector(yaw: 19.9, pitch: 12.7), ["armed"]), (HeadVector(yaw: 17, pitch: 10), ["armed"]),
                         (HeadVector(yaw: 20, pitch: 2), []), (HeadVector(yaw: 0, pitch: 13), [])] {
    let engine = GestureEngine()
    engine.calibration = latest
    var events: [String] = []
    engine.onEvent = { if case .armed = $0 { events.append("armed") } }
    let feed: (HeadVector, Double) -> Void = { delta, dt in engine.feed(delta, dt: dt) }
    move(pose, over: 0.4, feed: feed); hold(0.8, feed: feed)
    check(events == expected, "latest: holding (\(pose.yaw), \(pose.pitch)) gives \(expected): \(events)")
}

check(runReal { feed in
    activateReal(feed)
    // A diagonal look is ambiguous, so it must not pick a direction.
    move(real.left * 0.7 + real.up * 0.7, over: 0.3, feed: feed); hold(0.3, feed: feed)
    move((real.left * 0.7 + real.up * 0.7) * -1, over: 0.3, feed: feed); hold(6, feed: feed)
} == ["armed", "cancelled"], "real: a diagonal look after activating fires nothing")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
