import AppKit
import SwiftUI

/// Runs dwell clicking for the head cursor: watches where the cursor rests, shows a ring filling up
/// around it, and clicks when the ring is full.
final class DwellController {
    /// True while something else is using head movement, so a resting cursor must not click.
    var isBlocked: () -> Bool = { false }

    var dwellTime: TimeInterval {
        get { clicker.dwellTime }
        set { clicker.dwellTime = newValue }
    }

    private let pointer: Pointer
    private let clicker = DwellClicker()
    private let indicator = DwellIndicator()
    private var timer: Timer?
    private var lastStep: TimeInterval = 0

    init(pointer: Pointer) {
        self.pointer = pointer
    }

    func setActive(_ active: Bool) {
        if active, timer == nil {
            _ = pointer.takeTravel()
            clicker.reset()
            lastStep = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !active, let timer {
            timer.invalidate()
            self.timer = nil
            indicator.hide()
        }
    }

    /// Something else just clicked, so a rest in progress must not click again on top of it.
    func clicked() {
        clicker.reset()
        indicator.hide()
    }

    private func step() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastStep
        lastStep = now
        let travel = pointer.takeTravel()
        guard !isBlocked() else {
            clicker.reset()
            indicator.hide()
            return
        }
        let position = NSEvent.mouseLocation
        switch clicker.update(position: position, headTravel: travel, dt: dt) {
        case .idle:
            indicator.hide()
        case .progress(let progress):
            indicator.show(progress: progress, at: position)
        case .click:
            indicator.flash(at: position)
            pointer.click(.left)
        }
    }
}

/// The ring drawn around the cursor while it rests, so a click never comes as a surprise.
final class DwellIndicator {
    static let size: CGFloat = 52
    static let pixels = 12

    private let model = DwellIndicatorModel()
    private var isFlashing = false

    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        // The click has to land on whatever is underneath, not on the ring.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: DwellRing(model: model))
        return panel
    }()

    /// `point` is the cursor position in AppKit screen coordinates.
    func show(progress: Double, at point: NSPoint) {
        guard !isFlashing else { return }
        let lit = Int(progress * Double(Self.pixels))
        if model.lit != lit { model.lit = lit }
        place(at: point)
    }

    /// Lights the whole ring for a moment to confirm a click.
    func flash(at point: NSPoint) {
        isFlashing = true
        model.clicked = true
        place(at: point)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            self.isFlashing = false
            self.model.clicked = false
            self.model.lit = 0
            self.panel.orderOut(nil)
        }
    }

    func hide() {
        guard !isFlashing, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func place(at point: NSPoint) {
        panel.setFrameOrigin(NSPoint(x: point.x - Self.size / 2, y: point.y - Self.size / 2))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

final class DwellIndicatorModel: ObservableObject {
    @Published var lit = 0
    @Published var clicked = false
}

private struct DwellRing: View {
    @ObservedObject var model: DwellIndicatorModel

    private let radius = 17.0

    var body: some View {
        ZStack {
            // A dark band behind the pixels keeps them readable on any window, while the middle
            // stays clear so the thing being aimed at is never covered.
            Circle()
                .stroke(Cosmic.void.opacity(0.7), lineWidth: 9)
                .frame(width: radius * 2, height: radius * 2)
            ForEach(0..<DwellIndicator.pixels, id: \.self) { index in
                let angle = Double(index) / Double(DwellIndicator.pixels) * 2 * .pi
                Rectangle()
                    .fill(model.clicked ? Cosmic.ink : index < model.lit ? Cosmic.accent : Cosmic.dim)
                    .frame(width: 4, height: 4)
                    .offset(x: radius * sin(angle), y: -radius * cos(angle))
            }
        }
        .frame(width: DwellIndicator.size, height: DwellIndicator.size)
    }
}
