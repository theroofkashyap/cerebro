import Combine
import Foundation

/// One reading from the earbuds' motion sensors.
struct MotionSample {
    typealias Axes = (x: Double, y: Double, z: Double)

    /// The sensor's own timestamp, in seconds.
    var time: TimeInterval
    /// Head orientation, in radians.
    var yaw: Double
    var pitch: Double
    var roll: Double
    /// Rotation rate, in radians per second.
    var rotation: Axes
    /// Acceleration with gravity removed, in g.
    var acceleration: Axes
    /// The direction of gravity, in g.
    var gravity: Axes
}

/// Walks the wearer through a script of small face and jaw movements while logging every motion
/// sample, to find out which of them the earbuds can feel. A jaw click can only be designed from this log.
final class SignalRecorder: ObservableObject {
    struct Action: Equatable {
        /// The name used in the log.
        let id: String
        let name: String
        let how: String
        let repeats: Int
        /// How long (s) each cue stays up, which is the time allowed to do the movement once.
        let cueTime: TimeInterval
        /// True for movements that must not be mistaken for a click.
        var isControl = false
    }

    enum Phase: String {
        case ready, intro, still, explain, cue, rest, done
    }

    static let actions = [
        Action(id: "teeth_tap", name: "Teeth tap", how: "Tap your back teeth together once, lightly.", repeats: 6, cueTime: 1.2),
        Action(id: "double_tap", name: "Double teeth tap", how: "Tap your teeth together twice, quickly.", repeats: 6, cueTime: 1.4),
        Action(id: "clench", name: "Jaw clench", how: "Bite down firmly for a moment, then let go.", repeats: 6, cueTime: 1.4),
        Action(id: "tongue_click", name: "Tongue click", how: "Click your tongue against the roof of your mouth.", repeats: 6, cueTime: 1.2),
        Action(id: "eyebrows", name: "Eyebrow raise", how: "Raise your eyebrows, then relax them.", repeats: 6, cueTime: 1.4),
        Action(id: "speak", name: "Speaking", how: "Say “one, two, three, four” at your normal volume.", repeats: 4, cueTime: 3, isControl: true),
        Action(id: "swallow", name: "Swallow", how: "Swallow once.", repeats: 4, cueTime: 2, isControl: true),
        Action(id: "head_turn", name: "Small head turn", how: "Turn your head a little, as if moving the cursor, and stop.", repeats: 4, cueTime: 1.6, isControl: true),
    ]

    @Published private(set) var phase = Phase.ready
    @Published private(set) var action: Action?
    @Published private(set) var rep = 0
    /// How far through the whole script, 0...1.
    @Published private(set) var progress = 0.0
    /// Whole seconds left in the current step.
    @Published private(set) var secondsLeft = 0
    /// True while no motion is arriving; the script waits.
    @Published private(set) var stalled = false
    @Published private(set) var savedTo: URL?
    @Published private(set) var summary = ""

    /// Where logs are written.
    var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cerebro/recordings", isDirectory: true)

    var isRunning: Bool { phase != .ready && phase != .done }

    /// The script's length in seconds.
    var totalTime: TimeInterval { segments.reduce(0) { $0 + $1.duration } }

    private struct Segment {
        let phase: Phase
        let action: Action?
        let rep: Int
        let duration: TimeInterval
    }

    private let segments: [Segment]
    private var index = 0
    private var inSegment: TimeInterval = 0
    private var elapsed: TimeInterval = 0
    private var sinceSample: TimeInterval = 0
    private var rows: [String] = []
    // What arrived while no script was running, so movements tried by hand are kept too. Capped at ten minutes.
    private var freeRows: [String] = []
    private let freeLimit = 30_000
    private var firstSample: TimeInterval?
    private var lastSample: TimeInterval = 0

    // A gap between cues long enough for the previous movement to die away.
    private static let restTime: TimeInterval = 1.8
    private static let header = "t,script_t,phase,action,rep,yaw,pitch,roll,rot_x,rot_y,rot_z,acc_x,acc_y,acc_z,grav_x,grav_y,grav_z"

    init() {
        var segments = [Segment(phase: .intro, action: nil, rep: 0, duration: 5),
                        Segment(phase: .still, action: nil, rep: 0, duration: 8)]
        for action in Self.actions {
            segments.append(Segment(phase: .explain, action: action, rep: 0, duration: 5))
            for rep in 1...action.repeats {
                segments.append(Segment(phase: .cue, action: action, rep: rep, duration: action.cueTime))
                segments.append(Segment(phase: .rest, action: action, rep: rep, duration: Self.restTime))
            }
        }
        self.segments = segments
    }

    func start() {
        index = 0
        inSegment = 0
        elapsed = 0
        sinceSample = 0
        rows = []
        firstSample = nil
        savedTo = nil
        summary = ""
        stalled = false
        publish()
    }

    /// Stops without saving.
    func cancel() {
        rows = []
        phase = .ready
        action = nil
        rep = 0
        progress = 0
        stalled = false
    }

    func add(_ sample: MotionSample) {
        guard isRunning else {
            if freeRows.count < freeLimit { freeRows.append(row(sample, scriptTime: 0, step: "free,,0")) }
            return
        }
        sinceSample = 0
        if firstSample == nil { firstSample = sample.time }
        lastSample = sample.time
        let segment = segments[index]
        rows.append(row(sample, scriptTime: elapsed, step: "\(segment.phase.rawValue),\(segment.action?.id ?? ""),\(segment.rep)"))
    }

    /// Saves what arrived outside the script, if it is long enough to be worth keeping, and starts afresh.
    @discardableResult
    func saveFreeLog() -> URL? {
        defer { freeRows = [] }
        guard freeRows.count >= 250 else { return nil }
        return try? write(freeRows, named: "live")
    }

    private func row(_ sample: MotionSample, scriptTime: TimeInterval, step: String) -> String {
        let values = [sample.yaw, sample.pitch, sample.roll,
                      sample.rotation.x, sample.rotation.y, sample.rotation.z,
                      sample.acceleration.x, sample.acceleration.y, sample.acceleration.z,
                      sample.gravity.x, sample.gravity.y, sample.gravity.z]
        return String(format: "%.4f,%.3f,", sample.time, scriptTime) + step + ","
            + values.map { String(format: "%.6f", $0) }.joined(separator: ",")
    }

    private func write(_ rows: [String], named name: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let file = directory.appendingPathComponent("\(name)-\(formatter.string(from: Date())).csv")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ([Self.header] + rows).joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Moves the script on by `dt` seconds. It waits while no motion is arriving, so a dropped
    /// connection can't leave a stretch of cues with nothing recorded.
    func tick(dt: TimeInterval) {
        guard isRunning else { return }
        sinceSample += dt
        let waiting = sinceSample > 1
        if stalled != waiting { stalled = waiting }
        guard !waiting else { return }

        inSegment += dt
        elapsed += dt
        while inSegment >= segments[index].duration {
            inSegment -= segments[index].duration
            index += 1
            if index == segments.count {
                finish()
                return
            }
        }
        publish()
    }

    private func publish() {
        let segment = segments[index]
        if phase != segment.phase { phase = segment.phase }
        if action != segment.action { action = segment.action }
        if rep != segment.rep { rep = segment.rep }
        let left = Int((segment.duration - inSegment).rounded(.up))
        if secondsLeft != left { secondsLeft = left }
        let fraction = min(elapsed / totalTime, 1)
        if abs(fraction - progress) >= 0.005 { progress = fraction }
    }

    private func finish() {
        progress = 1
        action = nil
        phase = .done
        do {
            savedTo = try write(rows, named: "signals")
            let span = lastSample - (firstSample ?? lastSample)
            let rate = span > 0 ? Double(rows.count - 1) / span : 0
            summary = String(format: "%d samples at %.0f per second.", rows.count, rate)
        } catch {
            summary = "Could not save the recording: \(error.localizedDescription)"
        }
    }
}
