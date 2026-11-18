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

// MARK: Dwell click, with the cursor updated at 60 Hz

struct DwellRun {
    let clicker = DwellClicker()
    var cursor = CGPoint(x: 500, y: 500)
    var clicks = 0
    var sawProgress = false
    private let step = 1.0 / 60

    /// The head carries the cursor by (dx, dy) over `seconds`.
    mutating func head(_ dx: Double, _ dy: Double, over seconds: Double) { advance(seconds, head: (dx, dy), cursor: (dx, dy)) }
    /// The trackpad carries the cursor.
    mutating func hand(_ dx: Double, _ dy: Double, over seconds: Double) { advance(seconds, head: (0, 0), cursor: (dx, dy)) }
    /// The head pushes against a screen edge, so the cursor stays where it is.
    mutating func push(_ dx: Double, _ dy: Double, over seconds: Double) { advance(seconds, head: (dx, dy), cursor: (0, 0)) }
    mutating func rest(_ seconds: Double) { advance(seconds, head: (0, 0), cursor: (0, 0)) }

    private mutating func advance(_ seconds: Double, head: (Double, Double), cursor by: (Double, Double)) {
        let steps = max(Int((seconds / step).rounded()), 1)
        for _ in 0..<steps {
            cursor.x += by.0 / Double(steps)
            cursor.y += by.1 / Double(steps)
            let travel = CGVector(dx: head.0 / Double(steps), dy: head.1 / Double(steps))
            switch clicker.update(position: cursor, headTravel: travel, dt: step) {
            case .click: clicks += 1
            case .progress: sawProgress = true
            case .idle: break
            }
        }
    }
}

var dwell = DwellRun()
dwell.rest(3)
check(dwell.clicks == 0, "dwell: a cursor the head never moved does not click")
dwell.head(200, 50, over: 0.5); dwell.rest(0.9)
check(dwell.clicks == 0 && dwell.sawProgress, "dwell: progress shows before the click")
dwell.rest(0.3)
check(dwell.clicks == 1, "dwell: the head moves the cursor, rests a second, and it clicks once")
dwell.rest(5)
check(dwell.clicks == 1, "dwell: staying put after a click does not click again")
dwell.head(20, 0, over: 0.2); dwell.rest(2)
check(dwell.clicks == 1, "dwell: a small shift after a click is not enough for another")
dwell.head(100, 0, over: 0.4); dwell.rest(1.2)
check(dwell.clicks == 2, "dwell: carrying the cursor away and resting clicks again")
dwell.head(150, 0, over: 0.4); dwell.head(-150, 0, over: 0.4); dwell.rest(1.2)
check(dwell.clicks == 3, "dwell: coming back to the same spot can click it a second time")

dwell = DwellRun()
dwell.head(200, 0, over: 0.5); dwell.rest(0.6); dwell.head(-150, 0, over: 0.4); dwell.rest(0.6); dwell.head(80, 0, over: 0.3)
check(dwell.clicks == 0, "dwell: short pauses on the way somewhere do not click")

dwell = DwellRun()
dwell.hand(300, 0, over: 0.5); dwell.rest(3)
check(dwell.clicks == 0, "dwell: a cursor parked by the trackpad does not click")

dwell = DwellRun()
dwell.head(200, 0, over: 0.5); dwell.rest(0.4); dwell.hand(60, 0, over: 0.3); dwell.rest(3)
check(dwell.clicks == 0, "dwell: taking over with the trackpad cancels the click")

dwell = DwellRun()
dwell.head(200, 0, over: 0.5); dwell.push(300, 0, over: 3)
check(dwell.clicks == 0, "dwell: pushing into a screen edge does not click")
dwell.rest(1.2)
check(dwell.clicks == 1, "dwell: resting at the edge afterwards does")

dwell = DwellRun()
dwell.head(200, 0, over: 0.5)
for _ in 0..<40 { dwell.head(1, -0.5, over: 0.017); dwell.head(-1, 0.5, over: 0.017) }
check(dwell.clicks == 1, "dwell: a slight tremor while resting still clicks")

dwell = DwellRun()
dwell.head(200, 0, over: 0.5); dwell.head(60, 0, over: 3)
check(dwell.clicks == 0, "dwell: a slow glide across the screen does not click")

// MARK: Signal check script, with motion arriving at 50 Hz

let recorder = SignalRecorder()
recorder.directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("cerebro-test-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
recorder.start()
for _ in 0..<100 { recorder.tick(dt: 0.05) }
check(recorder.phase == .intro && recorder.stalled, "signal check: the script waits while no motion arrives")

var clock = 0.0
var cuesSeen: [String: Set<Int>] = [:]
while recorder.isRunning, clock < 600 {
    clock += 0.02
    recorder.add(MotionSample(time: clock, yaw: 0, pitch: 0, roll: 0, rotation: (0, 0, 0),
                              acceleration: (0, 0, 0), gravity: (0, 0, -1)))
    recorder.tick(dt: 0.02)
    if recorder.phase == .cue, let action = recorder.action { cuesSeen[action.id, default: []].insert(recorder.rep) }
}
check(recorder.phase == .done && !recorder.stalled, "signal check: the script runs to the end once motion arrives")
check(SignalRecorder.actions.allSatisfy { cuesSeen[$0.id]?.count == $0.repeats },
      "signal check: every movement is cued the right number of times")
let logLines = (recorder.savedTo.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "").split(separator: "\n")
check(logLines.first?.hasPrefix("t,script_t,phase,action,rep,yaw") == true, "signal check: the log starts with its header")
// One second of the script ran before the motion stopped arriving above.
check(abs(Double(logLines.count - 1) - (recorder.totalTime - 1) / 0.02) <= 10,
      "signal check: every sample is logged: \(logLines.count - 1) rows for \(Int(recorder.totalTime)) s")
check(logLines.contains { $0.contains(",cue,clench,3,") } && logLines.contains { $0.contains(",still,,0,") },
      "signal check: each row carries the step it was recorded in")
check(recorder.summary.contains("at 50 per second"), "signal check: the summary reports the sample rate: \(recorder.summary)")

// Outside the script, what arrives is kept as a free log, but only if there is enough of it.
for index in 0..<100 { recorder.add(MotionSample(time: 1000 + Double(index) * 0.02, yaw: 0, pitch: 0, roll: 0, rotation: (0, 0, 0),
                                                 acceleration: (0, 0, 0), gravity: (0, 0, -1))) }
check(recorder.saveFreeLog() == nil, "signal check: two seconds tried by hand are not worth a file")
for index in 0..<300 { recorder.add(MotionSample(time: 2000 + Double(index) * 0.02, yaw: 0, pitch: 0, roll: 0, rotation: (0, 0, 0),
                                                 acceleration: (0, 0, 0), gravity: (0, 0, -1))) }
let freeLog = recorder.saveFreeLog()
let freeLines = (freeLog.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "").split(separator: "\n")
check(freeLog?.lastPathComponent.hasPrefix("live-") == true && freeLines.count == 301 && freeLines.last?.contains(",free,,0,") == true,
      "signal check: six seconds tried by hand are saved as a free log: \(freeLines.count) lines")
if let file = recorder.savedTo { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

// MARK: Bite detector, against a simulated earbud at 50 Hz

/// An earbud with sensor noise and, optionally, the steady head bob seen in a real recording.
final class EarbudSim {
    let detector = BiteDetector()
    var bites: [BiteDetector.Bite] = []
    /// How long after each bite's first jolt it was reported.
    var delays: [Double] = []
    var bobbing = false
    private var time = 0.0
    private var seed: UInt64 = 42

    init() {
        detector.onBite = { [unowned self] bite, at in
            self.bites.append(bite)
            self.delays.append(self.time - at)
        }
    }

    /// Runs for `seconds`. `turn` is the head's rotation rate (rad/s) and `jolts` lists the sharp
    /// knocks to the earbud as (time since the start of this run, size in g).
    func run(_ seconds: Double, turn: (Double) -> Double = { _ in 0 }, jolts: [(at: Double, size: Double)] = []) {
        for step in 0..<Int((seconds / 0.02).rounded()) {
            let t = Double(step) * 0.02
            time += 0.02
            // A one-sample spike of half the size bends the acceleration by the full size.
            let knock = jolts.filter { abs($0.at - t) < 0.005 }.reduce(0) { $0 + $1.size / 2 }
            let bob = bobbing ? sin(2 * .pi * 2.6 * time) : 0
            detector.feed(MotionSample(
                time: time, yaw: 0, pitch: 0, roll: 0,
                rotation: (gaussian() * 0.004 + 0.2 * bob, gaussian() * 0.004, gaussian() * 0.004 + turn(t)),
                acceleration: (gaussian() * 0.0008, gaussian() * 0.0008 + 0.02 * bob + knock, gaussian() * 0.0008),
                gravity: (0, 0, -1)))
        }
    }

    private func uniform() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return (Double(seed >> 11) + 0.5) / Double(1 << 53)
    }

    private func gaussian() -> Double {
        (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
    }
}

var earbud = EarbudSim()
earbud.bobbing = true
earbud.run(60)
check(earbud.bites.isEmpty, "bite: a minute of nodding along to music is not a bite: \(earbud.bites)")

earbud.run(2, jolts: [(0.5, 0.1)])
check(earbud.bites == [.single] && earbud.delays[0] > 0.5, "bite: one bite reads as single, after waiting for a second one: \(earbud.bites) \(earbud.delays)")

earbud.bites = []
earbud.run(2, jolts: [(0.5, 0.1), (0.86, 0.08)])
check(earbud.bites == [.double], "bite: two bites a third of a second apart read as double: \(earbud.bites)")

earbud.bites = []
earbud.run(3, jolts: [(0.5, 0.1), (1.7, 0.1)])
check(earbud.bites == [.single, .single], "bite: two bites over a second apart read as two singles: \(earbud.bites)")

earbud.bites = []
earbud.run(2, jolts: [(0.5, 0.12), (0.62, 0.045)])
check(earbud.bites == [.single], "bite: the ringing after a bite is not a second bite: \(earbud.bites)")

earbud.bites = []
earbud.run(2, jolts: [(0.5, 0.03), (0.9, 0.035), (1.2, 0.04)])
check(earbud.bites.isEmpty, "bite: jolts the size of speech are ignored: \(earbud.bites)")

earbud.bites = []
earbud.run(3, jolts: [(0.5, 0.055), (0.6, 0.05), (0.7, 0.055), (0.8, 0.05), (0.9, 0.06), (1.0, 0.05)])
check(earbud.bites.isEmpty, "bite: a run of jolts, as in swallowing or chewing, is ignored: \(earbud.bites)")

earbud.bites = []
earbud.run(3, jolts: [(0.5, 0.1), (0.86, 0.1), (1.06, 0.1)])
check(earbud.bites.isEmpty, "bite: a third jolt straight after two cancels the double: \(earbud.bites)")

earbud.bites = []
earbud.run(2, jolts: [(0.5, 0.04), (0.7, 0.1)])
check(earbud.bites.isEmpty, "bite: a jolt that follows another one closely is not a bite: \(earbud.bites)")

earbud.bites = []
earbud.run(3, turn: { $0 >= 0.3 && $0 < 1.5 ? 0.8 : 0 }, jolts: [(1.0, 0.1)])
check(earbud.bites.isEmpty, "bite: a jolt while the head is turning is ignored: \(earbud.bites)")
earbud.run(2, jolts: [(0.5, 0.1)])
check(earbud.bites == [.single], "bite: and one after the head has stopped counts again: \(earbud.bites)")

earbud = EarbudSim()
earbud.detector.listensForDouble = false
earbud.run(2, jolts: [(0.5, 0.1)])
check(earbud.bites == [.single] && earbud.delays[0] < 0.05, "bite: with nothing on the double bite, a single is reported at once: \(earbud.delays)")

earbud = EarbudSim()
earbud.detector.threshold = 0.06
earbud.run(2, jolts: [(0.5, 0.05)])
check(earbud.bites.isEmpty, "bite: lower sensitivity ignores a gentle bite")
earbud.detector.threshold = 0.035
earbud.run(2, jolts: [(0.5, 0.05)])
check(earbud.bites == [.single], "bite: higher sensitivity catches it: \(earbud.bites)")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
