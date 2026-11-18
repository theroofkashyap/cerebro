import AppKit
import SwiftUI

/// The window for a signal check: a live view of what the earbuds feel, and a guided recording of
/// small jaw and face movements.
final class SignalCheck {
    let recorder = SignalRecorder()
    let live = LiveSignal()

    var isActive: Bool { window?.isVisible == true }

    private var window: NSWindow?
    private var timer: Timer?
    private var lastTick: TimeInterval = 0

    /// `biteThreshold` is the jolt, in g, that the head cursor currently counts as a bite.
    func show(biteThreshold: Double) {
        recorder.cancel()
        live.restart(threshold: biteThreshold)
        let window = self.window ?? makeWindow()
        self.window = window
        window.contentView = NSHostingView(rootView: SignalCheckView(recorder: recorder, live: live, close: { [weak self] in self?.close() }))
        if let frame = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        timer?.invalidate()
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func close() {
        timer?.invalidate()
        timer = nil
        recorder.cancel()
        if let file = recorder.saveFreeLog() { NSLog("Signal check: kept what was tried by hand in %@", file.path) }
        window?.orderOut(nil)
    }

    /// Takes one reading from the earbuds; ignored unless the window is open.
    func add(_ sample: MotionSample) {
        guard isActive else { return }
        live.feed(sample)
        recorder.add(sample)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let wasRunning = recorder.isRunning
        recorder.tick(dt: now - lastTick)
        live.tick(dt: now - lastTick)
        lastTick = now
        if wasRunning, !recorder.isRunning, let file = recorder.savedTo { NSLog("Signal check: recording saved to %@", file.path) }
    }

    private func makeWindow() -> NSWindow {
        let window = KeyableWindow(contentRect: NSRect(x: 0, y: 0, width: SignalCheckView.size.width, height: SignalCheckView.size.height),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        return window
    }
}

/// The last few seconds of what the earbuds feel, and the bites recognised in them, for drawing.
final class LiveSignal: ObservableObject {
    struct Trace {
        /// Jolts, in thousandths of a g.
        var jolt: [Double] = []
        /// Head speed, in degrees per second.
        var head: [Double] = []
    }

    /// Readings kept: six seconds at 50 a second.
    static let capacity = 300

    @Published private(set) var trace = Trace()
    @Published private(set) var last: BiteDetector.Bite?
    /// True for a moment after a bite, so the view can flash its name.
    @Published private(set) var justBit = false
    @Published private(set) var singles = 0
    @Published private(set) var doubles = 0
    /// False while no motion is arriving.
    @Published private(set) var receiving = false
    /// The jolt that counts as a bite, in thousandths of a g.
    @Published private(set) var threshold = 45.0

    var headIsMoving: Bool { (trace.head.last ?? 0) > BiteDetector.headLimit * 180 / .pi }

    private let detector = BiteDetector()
    private var sinceSample: TimeInterval = 0
    private var sinceBite: TimeInterval = 0

    init() {
        detector.onBite = { [weak self] bite, _ in
            guard let self else { return }
            self.last = bite
            self.justBit = true
            self.sinceBite = 0
            if bite == .single { self.singles += 1 } else { self.doubles += 1 }
        }
    }

    func restart(threshold: Double) {
        detector.reset()
        detector.threshold = threshold
        self.threshold = threshold * 1000
        trace = Trace()
        last = nil
        justBit = false
        singles = 0
        doubles = 0
    }

    func feed(_ sample: MotionSample) {
        sinceSample = 0
        if !receiving { receiving = true }
        detector.feed(sample)
        var next = trace
        next.jolt.append(detector.jolt * 1000)
        next.head.append(detector.headSpeed * 180 / .pi)
        if next.jolt.count > Self.capacity {
            next.jolt.removeFirst()
            next.head.removeFirst()
        }
        trace = next
    }

    func tick(dt: TimeInterval) {
        sinceSample += dt
        if receiving, sinceSample > 1 { receiving = false }
        sinceBite += dt
        if justBit, sinceBite > 1.2 { justBit = false }
    }
}

struct SignalCheckView: View {
    static let size = CGSize(width: 640, height: 680)

    @ObservedObject var recorder: SignalRecorder
    @ObservedObject var live: LiveSignal
    let close: () -> Void

    // The violet highlight from the artwork, so rotation reads apart from the accent used for acceleration.
    private let rotationColor = Color(red: 169 / 255, green: 140 / 255, blue: 255 / 255)

    var body: some View {
        PixelPanel(label: "SIGNAL CHECK") {
            VStack(alignment: .leading, spacing: 20) {
                liveView
                PixelDivider()
                switch recorder.phase {
                case .ready: ready
                case .done: done
                default: running
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 600)
        .frame(width: Self.size.width, height: Self.size.height)
        .preferredColorScheme(.dark)
    }

    // MARK: Live view

    private var liveView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                label("Live", Cosmic.muted)
                Spacer()
                label(status.text, status.color)
            }
            // `top` is the reading drawn at full height, and `line` is where the dotted line sits.
            lane("Jolt", live.trace.jolt, Cosmic.accent, top: 150, line: live.threshold)
            lane("Head speed", live.trace.head, rotationColor, top: 60, line: BiteDetector.headLimit * 180 / .pi)
            paragraph(readout)
                .frame(height: 38, alignment: .topLeading)
        }
    }

    private var status: (text: String, color: Color) {
        guard live.receiving else { return ("Waiting for earbuds", Cosmic.warning) }
        if live.justBit, let last = live.last { return (last == .single ? "Bite" : "Double bite", Cosmic.accent) }
        return live.headIsMoving ? ("Head moving · bites ignored", Cosmic.muted) : ("Still", Cosmic.muted)
    }

    private var readout: String {
        guard let last = live.last else {
            return "Bite once, then twice quickly, with your head still. A jolt above the dotted line is big enough to be a bite, and the corner names what was recognised."
        }
        return "Last: \(last == .single ? "one bite" : "a double bite"). \(live.singles) single and \(live.doubles) double so far. A single bite is named about half a second late, while it waits to see if a second follows."
    }

    /// One strip of the live view: each reading is a bar.
    private func lane(_ name: String, _ values: [Double], _ color: Color, top: Double, line: Double) -> some View {
        HStack(spacing: 12) {
            label(name, color)
                .frame(width: 112, alignment: .leading)
            Canvas { context, size in
                let step = size.width / Double(LiveSignal.capacity)
                let first = LiveSignal.capacity - values.count
                for (index, value) in values.enumerated() {
                    let height = (min(value, top) / top * size.height).rounded()
                    guard height >= 1 else { continue }
                    let x = (Double(first + index) * step).rounded(.down)
                    context.fill(Path(CGRect(x: x, y: size.height - height, width: max(step.rounded(.up), 1), height: height)),
                                 with: .color(color))
                }
                var rule = Path()
                let y = (size.height * (1 - min(line, top) / top)).rounded()
                rule.move(to: CGPoint(x: 0, y: y))
                rule.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(rule, with: .color(Cosmic.ink), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .frame(height: 52)
            .background(Cosmic.void)
            .overlay(Rectangle().strokeBorder(Cosmic.dim, lineWidth: 2))
        }
    }

    // MARK: Guided recording

    private var ready: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                heading("Find your click.")
                paragraph("Try a bite above first. The guided recording then takes you through eight small movements, such as a teeth tap, a jaw clench and an eyebrow raise, so they can be compared.")
                paragraph("It takes about \(Int((recorder.totalTime / 60).rounded())) minutes. Sit as you normally do, and keep your head still unless asked. Recordings stay on this Mac.")
            }
            PixelDivider()
            HStack(spacing: 14) {
                Button("Start Recording") { recorder.start() }
                    .buttonStyle(PixelButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                Button("Close", action: close)
                    .buttonStyle(PixelButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                label(caption, Cosmic.muted)
                Text(headline.uppercased())
                    .font(Cosmic.font(recorder.phase == .cue ? 64 : 30, .bold))
                    .foregroundStyle(recorder.phase == .cue ? Cosmic.accent : recorder.phase == .rest ? Cosmic.dim : Cosmic.ink)
                paragraph(detail)
            }
            // A fixed height, so the panel doesn't jump as the cues change.
            .frame(height: 170, alignment: .topLeading)

            if recorder.stalled { label("Waiting for motion from your earbuds", Cosmic.warning) }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Cosmic.dim)
                    Rectangle().fill(Cosmic.accent).frame(width: proxy.size.width * recorder.progress)
                }
            }
            .frame(height: 6)
            Button("Esc  Cancel", action: close)
                .buttonStyle(PixelButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                heading(recorder.savedTo == nil ? "Not saved." : "Recorded.")
                paragraph(recorder.summary)
                if let file = recorder.savedTo { paragraph(file.path) }
            }
            PixelDivider()
            HStack(spacing: 14) {
                if let file = recorder.savedTo {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        .buttonStyle(PixelButtonStyle())
                }
                Button("Done", action: close)
                    .buttonStyle(PixelButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var caption: String {
        guard let action = recorder.action else { return "Starting in \(recorder.secondsLeft)" }
        switch recorder.phase {
        case .explain: return (action.isControl ? "Next, for comparison" : "Next") + " · starts in \(recorder.secondsLeft)"
        default: return "\(action.name) · \(recorder.rep) of \(action.repeats)"
        }
    }

    private var headline: String {
        switch recorder.phase {
        case .intro: return "Get ready"
        case .still: return "Hold still"
        case .explain: return recorder.action?.name ?? ""
        case .cue: return "Now"
        default: return "· · ·"
        }
    }

    private var detail: String {
        switch recorder.phase {
        case .intro: return "Sit as you normally do. Keep your head still unless asked."
        case .still: return "Relax your jaw. This records a quiet baseline."
        case .explain: return (recorder.action?.how ?? "") + " Do it once each time NOW appears."
        case .cue: return recorder.action?.how ?? ""
        default: return "Relax and wait for the next one."
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(Cosmic.font(26, .bold))
            .foregroundStyle(Cosmic.ink)
    }

    private func label(_ text: String, _ color: Color) -> some View {
        Text(text.uppercased())
            .font(Cosmic.font(11, .bold))
            .tracking(1.5)
            .foregroundStyle(color)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(Cosmic.font(13))
            .foregroundStyle(Cosmic.muted)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }
}
