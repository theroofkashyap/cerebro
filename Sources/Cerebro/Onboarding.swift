import AppKit
import SwiftUI

/// The welcome and calibration screen. It covers the whole display so the targets sit at its edges.
final class Onboarding {
    let calibrator = Calibrator()

    var isActive: Bool { window?.isVisible == true }

    private var window: NSWindow?

    /// `shortcuts` lists what each direction does, for the summary at the end.
    func show(shortcuts: [(look: String, action: String)]) {
        calibrator.restart()
        let window = self.window ?? makeWindow()
        self.window = window
        if let screen = NSScreen.main { window.setFrame(screen.frame, display: true) }
        window.contentView = NSHostingView(rootView: OnboardingView(
            calibrator: calibrator, shortcuts: shortcuts, close: { [weak self] in self?.close() }))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = KeyableWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        return window
    }
}

// Borderless windows refuse key status by default, which would leave the buttons dead.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

struct OnboardingView: View {
    @ObservedObject var calibrator: Calibrator
    let shortcuts: [(look: String, action: String)]
    let close: () -> Void

    // Distance of the edge targets from the screen edges; the top needs more to clear the menu bar.
    private let margin = 90.0
    private let topMargin = 120.0

    var body: some View {
        ZStack {
            CosmicBackground()
            switch calibrator.step {
            case .welcome: welcome
            case .done: done
            default: calibration
            }
        }
        .overlay(alignment: .topTrailing) {
            Button("Esc  Close", action: close)
                .buttonStyle(PixelButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padding(.top, 56)
                .padding(.trailing, 36)
        }
        .preferredColorScheme(.dark)
    }

    private var welcome: some View {
        VStack(spacing: 34) {
            LogoView(height: 72)
            welcomePanel
        }
    }

    private var welcomePanel: some View {
        PixelPanel(label: "SETUP") {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Shortcuts, by turning your head.")
                        .font(Cosmic.font(26, .bold))
                        .foregroundStyle(Cosmic.ink)
                    paragraph("Cerebro reads the motion sensors in your earbuds. A short calibration teaches it how you move.")
                }
                PixelDivider()

                checkRow(done: calibrator.earbudsReady, title: "Earbuds",
                         detail: calibrator.earbudsReady
                             ? "Receiving head motion."
                             : "Put your earbuds in and connect them to this Mac.")
                checkRow(done: calibrator.accessibilityGranted, title: "Accessibility access",
                         detail: calibrator.accessibilityGranted
                             ? "Cerebro can send shortcuts."
                             : "Needed to send shortcuts. Switch Cerebro on in the list. If it is already on, remove it with the minus button and add it again.")
                if !calibrator.accessibilityGranted {
                    Button("Open Accessibility Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .buttonStyle(PixelButtonStyle())
                    .padding(.leading, 34)
                }
                PixelDivider()

                HStack(spacing: 16) {
                    Button("Start Calibration") { calibrator.begin() }
                        .buttonStyle(PixelButtonStyle(primary: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!calibrator.earbudsReady)
                    if !calibrator.earbudsReady { notice("Waiting for earbuds") }
                }
            }
        }
        .frame(width: 600)
    }

    private var calibration: some View {
        GeometryReader { proxy in
            PixelPanel(label: "CALIBRATION · " + calibrator.stepLabel.uppercased()) {
                HStack(alignment: .top, spacing: 18) {
                    // Points the way to the target, which may be at the far edge of the screen.
                    Text(arrow)
                        .font(Cosmic.font(34, .bold))
                        .foregroundStyle(Cosmic.accent)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(calibrator.instruction)
                            .font(Cosmic.font(19, .bold))
                            .foregroundStyle(Cosmic.ink)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                        paragraph(calibrator.detail)
                        if !calibrator.earbudsReady {
                            notice("Waiting for motion from your earbuds")
                        } else if let hint = calibrator.hint {
                            notice("▲ " + hint)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 560)
            // Sits below the target on the centre step, and in the middle of the screen otherwise.
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2 + (calibrator.step == .centre ? 190 : 0))

            CalibrationTarget(progress: calibrator.holdProgress)
                .position(targetPoint(in: proxy.size))
        }
    }

    private var done: some View {
        VStack(spacing: 34) {
            LogoView(height: 72)
            donePanel
        }
    }

    private var donePanel: some View {
        PixelPanel(label: "READY") {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("You're set.")
                        .font(Cosmic.font(26, .bold))
                        .foregroundStyle(Cosmic.ink)
                    paragraph("Shortcuts are live now, so you can try one right here.")
                }
                VStack(alignment: .leading, spacing: 9) {
                    numbered("1", "Look up and to the left, and hold for half a second.")
                    numbered("2", "When the panel appears, come back to centre.")
                    numbered("3", "Look one way and hold. The shortcut fires.")
                }
                PixelDivider()

                VStack(spacing: 10) {
                    ForEach(shortcuts.indices, id: \.self) { index in
                        HStack(spacing: 10) {
                            Text(shortcuts[index].look.uppercased())
                                .font(Cosmic.font(12, .bold))
                                .tracking(1.5)
                                .foregroundStyle(Cosmic.ink)
                            PixelDivider()
                            Text(shortcuts[index].action)
                                .font(Cosmic.font(13))
                                .foregroundStyle(Cosmic.accent)
                        }
                    }
                }
                PixelDivider()

                HStack(spacing: 14) {
                    Button("Calibrate Again") { calibrator.begin() }
                        .buttonStyle(PixelButtonStyle())
                    Button("Done", action: close)
                        .buttonStyle(PixelButtonStyle(primary: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(width: 600)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(Cosmic.font(13))
            .foregroundStyle(Cosmic.muted)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func notice(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Cosmic.font(11, .bold))
            .tracking(1.5)
            .foregroundStyle(Cosmic.warning)
    }

    private func numbered(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number)
                .font(Cosmic.font(13, .bold))
                .foregroundStyle(Cosmic.accent)
            Text(text)
                .font(Cosmic.font(13))
                .foregroundStyle(Cosmic.ink)
        }
    }

    private func checkRow(done: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Rectangle().strokeBorder(done ? Cosmic.accent : Cosmic.muted, lineWidth: 2)
                if done { Rectangle().fill(Cosmic.accent).padding(5) }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 5) {
                Text(title.uppercased())
                    .font(Cosmic.font(12, .bold))
                    .tracking(1.5)
                    .foregroundStyle(Cosmic.ink)
                paragraph(detail)
            }
        }
    }

    private var arrow: String {
        switch calibrator.step {
        case .direction(.left): return "←"
        case .direction(.right): return "→"
        case .direction(.up): return "↑"
        case .direction(.down): return "↓"
        case .activation: return "↖"
        case .welcome, .centre, .done: return "✦"
        }
    }

    private func targetPoint(in size: CGSize) -> CGPoint {
        switch calibrator.step {
        case .direction(.left): return CGPoint(x: margin, y: size.height / 2)
        case .direction(.right): return CGPoint(x: size.width - margin, y: size.height / 2)
        case .direction(.up): return CGPoint(x: size.width / 2, y: topMargin)
        case .direction(.down): return CGPoint(x: size.width / 2, y: size.height - margin)
        case .activation: return CGPoint(x: margin, y: topMargin)
        case .welcome, .centre, .done: return CGPoint(x: size.width / 2, y: size.height / 2)
        }
    }
}

/// The thing to look at: a star whose ring of pixels fills up while the head is held still.
private struct CalibrationTarget: View {
    let progress: Double

    private let pixels = 20
    private let radius = 44.0

    var body: some View {
        ZStack {
            // Clears the artwork behind the target so it reads against any part of the scene.
            Circle()
                .fill(Cosmic.void)
                .frame(width: 128, height: 128)
            ForEach(0..<pixels, id: \.self) { index in
                let angle = Double(index) / Double(pixels) * 2 * .pi
                Rectangle()
                    .fill(Double(index) < progress * Double(pixels) ? Cosmic.accent : Cosmic.muted)
                    .frame(width: 6, height: 6)
                    .offset(x: radius * sin(angle), y: -radius * cos(angle))
            }
            Rectangle().fill(Cosmic.ink).frame(width: 30, height: 6)
            Rectangle().fill(Cosmic.ink).frame(width: 6, height: 30)
            // Viewfinder corners, so the target stands out from the stars around it.
            Viewfinder()
                .stroke(Cosmic.ink, style: StrokeStyle(lineWidth: 3, lineCap: .square, lineJoin: .miter))
                .frame(width: 132, height: 132)
        }
    }
}

private struct Viewfinder: Shape {
    var arm = 18.0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (x, dx) in [(rect.minX, arm), (rect.maxX, -arm)] {
            for (y, dy) in [(rect.minY, arm), (rect.maxY, -arm)] {
                path.move(to: CGPoint(x: x + dx, y: y))
                path.addLine(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: y + dy))
            }
        }
        return path
    }
}
