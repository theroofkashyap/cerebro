import Foundation

/// Recognises a bite, and two bites in a row, from the jolt they give the earbud.
///
/// Teeth meeting is an impact: the earbud's acceleration jumps for a sample or two and rings down.
/// Slow movement (a head turn, a nod in time to music) changes smoothly from one sample to the
/// next, so the detector looks only at how sharply the acceleration bends, and ignores the rest.
///
/// The numbers below come from one recording of one person on Powerbeats Pro 2 at 50 samples a
/// second: bites gave jolts of 35 to 285 mg (typically 60 to 125), speech up to 42 mg, and a
/// resting head about 3 mg. They are a starting point, not a general result.
final class BiteDetector {
    enum Bite: Equatable {
        case single, double
    }

    /// Above this smoothed rotation speed (rad/s, about 20°/s) the head is moving and bites are ignored.
    static let headLimit = 0.35

    /// A jolt (g) at least this big counts as a bite.
    var threshold = 0.045
    /// When false, a bite is reported at once instead of after the wait for a second one.
    var listensForDouble = true
    /// Called with the kind of bite and the sensor time of its first jolt.
    var onBite: ((Bite, TimeInterval) -> Void)?

    /// The latest jolt (g) and smoothed head speed (rad/s), for the live view.
    private(set) var jolt = 0.0
    private(set) var headSpeed = 0.0

    private let headTau = 0.15
    // The head speed is read this many samples before the jolt, because a bite shakes the earbud too.
    private let headLag = 3
    // After a bite, jolts for this long (s) are its own ringing.
    private let refractory = 0.18
    // Ringing dies away. A jolt this large a share of the bite, this soon after it, means a run of
    // jolts instead: chewing, swallowing or talking.
    private let ringShare = 0.7
    // A second bite counts if it comes between these gaps (s) after the first.
    private let doubleMin = 0.2
    private let doubleMax = 0.6
    // After a second bite, wait this long (s) to be sure a third jolt doesn't follow.
    private let settle = 0.25
    // A bite stands alone: for this long (s) before it, no jolt may reach this share of the threshold.
    private let quietWindow = 0.4
    private let quietShare = 0.7
    // After a run of jolts, nothing counts until it has been quiet for this long (s).
    private let muteTime = 0.6

    private typealias Reading = (time: TimeInterval, jolt: Double, head: Double)
    private typealias Hit = (time: TimeInterval, size: Double)

    private var lastTime: TimeInterval?
    private var recent: [[Double]] = []
    private var history: [Reading] = []
    private var first: Hit?
    private var second: Hit?
    private var lastBite: Hit = (-.infinity, 0)
    private var mutedUntil = -Double.infinity

    func feed(_ sample: MotionSample) {
        let acceleration = [sample.acceleration.x, sample.acceleration.y, sample.acceleration.z]
        guard let previous = lastTime, sample.time > previous, sample.time - previous < 0.2 else {
            // The first sample, or the stream restarted.
            reset()
            lastTime = sample.time
            recent = [acceleration]
            return
        }
        let dt = sample.time - previous
        lastTime = sample.time

        let rotation = sample.rotation
        let speed = (rotation.x * rotation.x + rotation.y * rotation.y + rotation.z * rotation.z).squareRoot()
        headSpeed += (speed - headSpeed) * min(dt / headTau, 1)

        recent.append(acceleration)
        if recent.count > 3 { recent.removeFirst() }
        guard recent.count == 3 else { return }
        // How sharply the acceleration bends at the middle of the last three samples.
        var bend = 0.0
        for axis in 0..<3 {
            let value = recent[2][axis] - 2 * recent[1][axis] + recent[0][axis]
            bend += value * value
        }
        jolt = bend.squareRoot()
        history.append((sample.time, jolt, headSpeed))
        if history.count > 40 { history.removeFirst() }

        report(now: sample.time)
        // The reading before this one is a peak only once this one has come in lower.
        guard history.count >= 3 else { return }
        let index = history.count - 2
        let peak = history[index]
        guard peak.jolt >= threshold, peak.jolt >= history[index - 1].jolt, peak.jolt >= history[index + 1].jolt else { return }

        if peak.time < mutedUntil {
            mutedUntil = peak.time + muteTime
            return
        }
        let sinceBite = peak.time - lastBite.time
        if sinceBite < refractory {
            if sinceBite > 0.05, peak.jolt >= ringShare * lastBite.size { abandon(at: peak.time) }
            return
        }

        let still = history[max(index - headLag, 0)].head < Self.headLimit
        if first == nil {
            let before = history[..<index].filter { peak.time - $0.time > 0.05 && peak.time - $0.time <= quietWindow }
            guard still, (before.map(\.jolt).max() ?? 0) < quietShare * threshold else { return }
            first = (peak.time, peak.jolt)
            lastBite = (peak.time, peak.jolt)
            if !listensForDouble { emit(.single) }
        } else if second == nil {
            guard let first, peak.time - first.time >= doubleMin, still else { return }
            second = (peak.time, peak.jolt)
            lastBite = (peak.time, peak.jolt)
        } else {
            // A third strong jolt: not a gesture.
            abandon(at: peak.time)
        }
    }

    /// Forgets anything in progress, e.g. when bites should stop counting for a while.
    func reset() {
        lastTime = nil
        recent = []
        history = []
        first = nil
        second = nil
        lastBite = (-.infinity, 0)
        mutedUntil = -.infinity
        jolt = 0
        headSpeed = 0
    }

    private func report(now: TimeInterval) {
        if let second {
            if now - second.time > settle { emit(.double) }
        } else if let first, now - first.time > doubleMax {
            emit(.single)
        }
    }

    private func emit(_ bite: Bite) {
        guard let time = first?.time else { return }
        first = nil
        second = nil
        onBite?(bite, time)
    }

    private func abandon(at time: TimeInterval) {
        first = nil
        second = nil
        mutedUntil = time + muteTime
    }
}
