import AppKit
import SwiftUI

/// The visual aid shown while head shortcuts are listening: what each direction does, and where the head is.
final class Overlay {
    private let model = OverlayModel()

    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        // Never takes clicks or focus, so it can't get in the way of what the user is doing.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        return panel
    }()

    func show(labels: [Direction: String]) {
        model.labels = labels
        model.x = 0
        model.y = 0
        model.candidate = nil
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }
        panel.orderFrontRegardless()
    }

    /// `x` and `y` are in units of the calibrated reach, right and up positive.
    func update(x: Double, y: Double, candidate: Direction?) {
        model.x = x
        model.y = y
        if model.candidate != candidate { model.candidate = candidate }
    }

    func hide() {
        panel.orderOut(nil)
    }
}

final class OverlayModel: ObservableObject {
    @Published var labels: [Direction: String] = [:]
    @Published var x = 0.0
    @Published var y = 0.0
    @Published var candidate: Direction?
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    private let ringPixels = 8
    private let ringRadius = 20.0

    var body: some View {
        VStack(spacing: 0) {
            PixelTitleStrip(label: "LISTENING")

            ZStack {
                CosmicBackground(planet: false, nebula: 0.7, cell: 2, twinkle: false)

                // Marks the centre the head has to come back to.
                ForEach(0..<ringPixels, id: \.self) { index in
                    let angle = Double(index) / Double(ringPixels) * 2 * .pi
                    Rectangle()
                        .fill(Cosmic.muted)
                        .frame(width: 4, height: 4)
                        .offset(x: ringRadius * sin(angle), y: -ringRadius * cos(angle))
                }

                label(.left).offset(x: -170)
                label(.right).offset(x: 170)
                label(.up).offset(y: -92)
                label(.down).offset(y: 92)

                // The head position, so the user can see how far they still have to turn.
                // Its travel stops just short of the labels so it never covers their text.
                Rectangle()
                    .fill(Cosmic.accent)
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(45))
                    .offset(x: min(max(model.x, -1), 1) * 82, y: -min(max(model.y, -1), 1) * 62)
            }
        }
        .overlay(Rectangle().strokeBorder(Cosmic.ink, lineWidth: 2))
        .frame(width: 520, height: 300)
    }

    private func label(_ direction: Direction) -> some View {
        let chosen = model.candidate == direction
        return Text((model.labels[direction] ?? "").uppercased())
            .font(Cosmic.font(12, .bold))
            .tracking(1)
            .foregroundStyle(chosen ? Cosmic.void : Cosmic.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(chosen ? Cosmic.accent : Cosmic.void)
            .overlay(Rectangle().strokeBorder(chosen ? Cosmic.accent : Cosmic.ink, lineWidth: 2))
    }
}
