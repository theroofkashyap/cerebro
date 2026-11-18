import CoreGraphics
import Foundation

/// Decides when a cursor that the head has brought to rest should click.
///
/// Only head-driven movement counts: a cursor left somewhere by the trackpad never clicks, and after a
/// click the head has to carry the cursor away before the next one can start.
final class DwellClicker {
    enum Event: Equatable {
        /// Nothing to show.
        case idle
        /// The cursor is resting, this far (0...1) toward a click.
        case progress(Double)
        case click
    }

    /// How long (s) the cursor must rest before it clicks.
    var dwellTime = 1.0

    // The cursor may wander this far (points) from where it came to rest and still count as resting.
    private let radius = 12.0
    // Rest this long (s) before reporting progress, so nothing flickers during slow movement.
    private let settle = 0.25
    // How far (points) the head must carry the cursor from the last click before another can start.
    private let rearmDistance = 40.0
    // The cursor can still be settling this long (s) after the head's last movement; any later movement is by hand.
    private let handGrace = 0.15
    // Faster than this (points/s) the head is still carrying the cursor somewhere, not resting.
    private let travelSpeed = 120.0

    private var armed = false
    // Head-driven movement since the last click, and since the cursor came to rest.
    private var travel = CGVector.zero
    private var drift = CGVector.zero
    private var anchor: CGPoint?
    private var restedFor = 0.0
    private var headQuietFor = 0.0
    private var last: CGPoint?

    /// `headTravel` is how far the head has tried to move the cursor since the previous call, which is
    /// more than the cursor moved if it is pressed against a screen edge. `position` is where the cursor is now.
    func update(position: CGPoint, headTravel: CGVector, dt: TimeInterval) -> Event {
        defer { last = position }
        headQuietFor = headTravel == .zero ? headQuietFor + dt : 0
        if let last, headQuietFor > handGrace, hypot(position.x - last.x, position.y - last.y) > 1 {
            reset()
            return .idle
        }

        travel.dx += headTravel.dx
        travel.dy += headTravel.dy
        if !armed {
            guard hypot(travel.dx, travel.dy) >= rearmDistance else { return .idle }
            armed = true
        }

        drift.dx += headTravel.dx
        drift.dy += headTravel.dy
        // The rest starts where the cursor slows down, not somewhere along the way there. Pushing into a
        // screen edge leaves the cursor in place, so the head's own movement is checked as well.
        let travelling = hypot(headTravel.dx, headTravel.dy) > travelSpeed * dt
        guard let anchor, !travelling, hypot(position.x - anchor.x, position.y - anchor.y) <= radius,
              hypot(drift.dx, drift.dy) <= radius else {
            anchor = position
            drift = .zero
            restedFor = 0
            return .idle
        }

        restedFor += dt
        if restedFor >= dwellTime {
            reset()
            return .click
        }
        return restedFor > settle ? .progress((restedFor - settle) / (dwellTime - settle)) : .idle
    }

    /// Forgets any rest in progress; the head must move the cursor again before the next click.
    func reset() {
        armed = false
        travel = .zero
        drift = .zero
        anchor = nil
        restedFor = 0
    }
}
