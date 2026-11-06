import CoreGraphics
import Foundation

/// Converts head-rotation deltas into cursor movement and posts synthetic clicks.
final class Pointer {
    /// Cursor travel in points per radian of head rotation, at `referenceSpeed`.
    var sensitivity = 3600.0
    var invertX = false
    var invertY = false

    // Rotation slower than this (rad/s) is treated as sensor drift or tremor and ignored.
    private let deadSpeed = 0.012
    // Slower rotation than this (rad/s) gets less gain for precision, faster gets more for reach.
    private let referenceSpeed = 0.6

    // Motion samples arrive far slower than the display refreshes, so movement is queued
    // here and eased out by a faster timer.
    private var pending = CGVector.zero
    private var timer: Timer?
    private let tick: TimeInterval = 1.0 / 120
    // Fraction of the queued movement applied per tick (~35 ms time constant).
    private let easing = 0.21

    func move(dYaw: Double, dPitch: Double, dt: TimeInterval) {
        let speed = hypot(dYaw, dPitch) / dt
        guard speed > deadSpeed else { return }
        let gain = sensitivity * min(0.5 + 0.5 * speed / referenceSpeed, 2)
        // Yaw grows turning left and pitch grows looking up; screen x grows right and y grows down.
        pending.dx += (invertX ? dYaw : -dYaw) * gain
        pending.dy += (invertY ? dPitch : -dPitch) * gain

        if timer == nil {
            let timer = Timer(timeInterval: tick, repeats: true) { [weak self] _ in self?.flush() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    /// Drops any queued movement.
    func stop() {
        pending = .zero
        timer?.invalidate()
        timer = nil
    }

    func click(_ button: CGMouseButton) {
        guard let position = CGEvent(source: nil)?.location else { return }
        let types: [CGEventType] = button == .right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
        for type in types {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: position, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            event?.post(tap: .cghidEventTap)
        }
    }

    private func flush() {
        let dx = take(&pending.dx), dy = take(&pending.dy)
        // Moving relative to wherever the cursor is now lets a trackpad or mouse keep working alongside.
        if dx != 0 || dy != 0, let current = CGEvent(source: nil)?.location {
            let target = clamp(CGPoint(x: current.x + dx, y: current.y + dy))
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        if abs(pending.dx) < 1, abs(pending.dy) < 1 {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Removes a whole number of points from `pending`, leaving the sub-point remainder queued.
    private func take(_ pending: inout CGFloat) -> CGFloat {
        var step = (pending * easing).rounded()
        if step == 0, abs(pending) >= 1 { step = pending < 0 ? -1 : 1 }
        pending -= step
        return step
    }

    // Movement past a screen edge is discarded, so pushing into an edge re-centres your head.
    private func clamp(_ point: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(UInt32(displays.count), &displays, &count)
        let bounds = displays.prefix(Int(count)).reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
        guard !bounds.isNull else { return point }
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1),
                       y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }
}
