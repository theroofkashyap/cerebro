import AppKit
import SwiftUI

/// The shared look: a dithered deep-space palette, monospaced type and hard pixel edges.
enum Cosmic {
    static let void = Color(red: 5 / 255, green: 4 / 255, blue: 12 / 255)
    /// Bone white, for text and lines.
    static let ink = Color(red: 241 / 255, green: 235 / 255, blue: 221 / 255)
    static let muted = Color(red: 154 / 255, green: 147 / 255, blue: 184 / 255)
    static let dim = Color(red: 58 / 255, green: 52 / 255, blue: 90 / 255)
    static let accent = Color(red: 127 / 255, green: 227 / 255, blue: 230 / 255)
    /// The logo's amber. Kept for the logo alone, so it is the one warm colour on screen.
    static let brand = Color(red: 255 / 255, green: 187 / 255, blue: 0 / 255)
    static let warning = Color(red: 255 / 255, green: 122 / 255, blue: 110 / 255)

    /// Side of one on-screen "pixel" of the dithered artwork, in points.
    static let cell: CGFloat = 3

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Draws the dithered space scene as a small bitmap, one pixel per on-screen cell.
enum CosmicArt {
    private typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

    // Each ramp runs from the void up to a highlight; dithering mixes neighbouring steps.
    private static let violet: [RGB] = [(5, 4, 12), (14, 10, 38), (31, 20, 82), (58, 36, 150), (107, 70, 224), (169, 140, 255)]
    private static let teal: [RGB] = [(5, 4, 12), (7, 26, 36), (11, 51, 68), (19, 96, 121), (35, 160, 179), (127, 227, 230)]
    private static let rock: [RGB] = [(5, 4, 12), (43, 36, 64), (108, 100, 136), (185, 177, 204), (241, 235, 221)]
    private static let star: RGB = (241, 235, 221)
    private static let faintStar: RGB = (142, 134, 184)
    private static let glow: RGB = (107, 70, 224)

    // 8×8 ordered-dither matrix.
    private static let bayer: [[Double]] = [
        [0, 32, 8, 40, 2, 34, 10, 42], [48, 16, 56, 24, 50, 18, 58, 26],
        [12, 44, 4, 36, 14, 46, 6, 38], [60, 28, 52, 20, 62, 30, 54, 22],
        [3, 35, 11, 43, 1, 33, 9, 41], [51, 19, 59, 27, 49, 17, 57, 25],
        [15, 47, 7, 39, 13, 45, 5, 37], [63, 31, 55, 23, 61, 29, 53, 21],
    ]

    private struct Key: Hashable {
        let columns: Int
        let rows: Int
        let planet: Bool
        let nebula: Double
    }

    private static var cache: [Key: CGImage] = [:]

    /// `nebula` scales the brightness of the clouds, 0...1.
    static func image(columns: Int, rows: Int, planet: Bool, nebula: Double) -> CGImage? {
        let key = Key(columns: columns, rows: rows, planet: planet, nebula: nebula)
        if let cached = cache[key] { return cached }
        let image = render(columns: columns, rows: rows, planet: planet, nebula: nebula)
        if cache.count > 6 { cache.removeAll() }
        cache[key] = image
        return image
    }

    /// A repeating dither tile in violet on clear, for the offset glow behind panels.
    /// Sized for a 2× display, so use it with `scale: 2`.
    static let glowTile: CGImage? = {
        let pixelsPerCell = Int(Cosmic.cell) * 2
        let side = 8 * pixelsPerCell
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side where threshold(x / pixelsPerCell, y / pixelsPerCell) < 0.4 {
                let index = (y * side + x) * 4
                (pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3]) = (glow.r, glow.g, glow.b, 255)
            }
        }
        return makeImage(pixels, width: side, height: side, alpha: .premultipliedLast)
    }()

    private static func render(columns: Int, rows: Int, planet: Bool, nebula: Double) -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: columns * rows * 4)
        func put(_ x: Int, _ y: Int, _ color: RGB) {
            guard x >= 0, y >= 0, x < columns, y < rows else { return }
            let index = (y * columns + x) * 4
            (pixels[index], pixels[index + 1], pixels[index + 2]) = (color.r, color.g, color.b)
        }

        // Noise is sampled in units of the image height, so the scene keeps its scale on any screen shape.
        let unit = Double(rows)
        for y in 0..<rows {
            for x in 0..<columns {
                let px = Double(x) / unit, py = Double(y) / unit
                // A band of cloud from bottom-left to top-right, like the Milky Way, with a wavy edge.
                let across = (Double(x) / Double(columns) + Double(y) / Double(rows) - 1) / 2.0.squareRoot()
                let warp = (clouds(px * 1.3, py * 1.3, octaves: 3, seed: 11) - 0.5) * 0.35
                let band = exp(-pow((across + warp) / 0.22, 2))
                let cloud = clouds(px * 2.6, py * 2.6, octaves: 5, seed: 23)
                let body = smoothstep(0.30, 0.78, cloud)
                let wisps = smoothstep(0.55, 0.90, cloud) * 0.10
                let value = nebula * (band * (0.18 + 0.82 * body) * 0.92 + wisps)

                let hue = clouds(px * 1.1 + 9.7, py * 1.1 + 3.1, octaves: 3, seed: 57)
                let ramp = hue + (threshold(x + 3, y + 5) - 0.5) * 0.18 > 0.54 ? teal : violet
                put(x, y, dithered(value, ramp, x, y))

                let roll = hash(x, y, 101)
                if roll < 0.0030 {
                    put(x, y, star)
                } else if roll < 0.0085 {
                    put(x, y, faintStar)
                }
            }
        }

        // A few larger stars, drawn as plus signs.
        for index in 0..<max(columns * rows / 9000, 4) {
            let x = Int(hash(index, 1, 201) * Double(columns)), y = Int(hash(index, 2, 201) * Double(rows))
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] { put(x + dx, y + dy, faintStar) }
            put(x, y, star)
        }

        if planet { drawPlanet(columns: columns, rows: rows, put: put) }
        return makeImage(pixels, width: columns, height: rows, alpha: .noneSkipLast)
    }

    /// A ringed gas giant, lit from the upper left, sitting in the bottom-right corner.
    private static func drawPlanet(columns: Int, rows: Int, put: (Int, Int, RGB) -> Void) {
        let radius = Double(rows) * 0.26
        let cx = Double(columns) - radius * 0.75, cy = Double(rows) - radius * 0.62
        let tilt = -0.36
        let light = (x: -0.55, y: -0.60, z: 0.58)
        // How flat the ring looks from this angle.
        let ringSquash = 0.30

        for y in max(Int(cy - radius * 2.2), 0)..<rows {
            for x in max(Int(cx - radius * 2.2), 0)..<columns {
                let dx = (Double(x) + 0.5 - cx) / radius, dy = (Double(y) + 0.5 - cy) / radius
                let onDisc = dx * dx + dy * dy <= 1
                // Position in the ring's own tilted, flattened frame.
                let alongRing = dx * cos(tilt) + dy * sin(tilt)
                let latitude = -dx * sin(tilt) + dy * cos(tilt)
                let ringRadius = hypot(alongRing, latitude / ringSquash)
                let onRing = ringRadius > 1.38 && ringRadius < 1.95 && !(ringRadius > 1.60 && ringRadius < 1.67)
                // The near half of the ring passes in front of the planet; the far half goes behind it.
                let ringInFront = latitude > 0

                if onDisc, !(onRing && ringInFront) {
                    let nz = (1 - dx * dx - dy * dy).squareRoot()
                    let lit = max(dx * light.x + dy * light.y + nz * light.z, 0)
                    let stripes = 0.82 + 0.18 * sin(latitude * 11 + 2.5 * noise(dx * 3, dy * 3, 77))
                    put(x, y, dithered(pow(lit, 0.8) * stripes, rock, x, y))
                } else if onRing {
                    let streaks = 0.30 + 0.45 * noise(ringRadius * 40, 0, 88)
                    put(x, y, dithered(streaks, rock, x, y))
                }
            }
        }
    }

    private static func dithered(_ value: Double, _ ramp: [RGB], _ x: Int, _ y: Int) -> RGB {
        let scaled = min(max(value, 0), 1) * Double(ramp.count - 1)
        let index = min(Int(scaled), ramp.count - 2)
        return scaled - Double(index) > threshold(x, y) ? ramp[index + 1] : ramp[index]
    }

    private static func threshold(_ x: Int, _ y: Int) -> Double {
        (bayer[y & 7][x & 7] + 0.5) / 64
    }

    private static func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let t = min(max((value - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// A repeatable pseudo-random number in 0..<1 for a grid point.
    static func hash(_ x: Int, _ y: Int, _ seed: Int) -> Double {
        var h = UInt64(truncatingIfNeeded: x) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(truncatingIfNeeded: y) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= UInt64(truncatingIfNeeded: seed) &* 0x1656_67B1_9E37_79F9
        h ^= h >> 33
        h &*= 0xFF51_AFD7_ED55_8CCD
        h ^= h >> 33
        h &*= 0xC4CE_B9FE_1A85_EC53
        h ^= h >> 33
        return Double(h >> 11) / Double(1 << 53)
    }

    /// Smooth value noise in 0...1.
    private static func noise(_ x: Double, _ y: Double, _ seed: Int) -> Double {
        let x0 = x.rounded(.down), y0 = y.rounded(.down)
        let fx = x - x0, fy = y - y0
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let ix = Int(x0), iy = Int(y0)
        let top = hash(ix, iy, seed) * (1 - sx) + hash(ix + 1, iy, seed) * sx
        let bottom = hash(ix, iy + 1, seed) * (1 - sx) + hash(ix + 1, iy + 1, seed) * sx
        return top * (1 - sy) + bottom * sy
    }

    /// Several octaves of noise layered into cloud shapes, in 0...1.
    private static func clouds(_ x: Double, _ y: Double, octaves: Int, seed: Int) -> Double {
        var total = 0.0, range = 0.0, amplitude = 0.5, frequency = 1.0
        for octave in 0..<octaves {
            total += noise(x * frequency, y * frequency, seed + octave) * amplitude
            range += amplitude
            amplitude *= 0.5
            frequency *= 2
        }
        return total / range
    }

    private static func makeImage(_ pixels: [UInt8], width: Int, height: Int, alpha: CGImageAlphaInfo) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// The dithered starfield, scaled up with hard pixel edges.
struct CosmicBackground: View {
    var planet = true
    var nebula = 1.0
    var cell = Cosmic.cell
    var twinkle = true

    private let sparkles = 40
    private let beat = 0.45

    var body: some View {
        GeometryReader { proxy in
            let columns = max(Int(proxy.size.width / cell), 1), rows = max(Int(proxy.size.height / cell), 1)
            if let image = CosmicArt.image(columns: columns, rows: rows, planet: planet, nebula: nebula) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            if twinkle {
                TimelineView(.periodic(from: .now, by: beat)) { timeline in
                    Canvas { context, size in
                        draw(sparklesAt: Int(timeline.date.timeIntervalSinceReferenceDate / beat), in: &context, size: size)
                    }
                }
            }
        }
        .background(Cosmic.void)
    }

    /// A handful of stars that flare into a plus sign now and then, each on its own rhythm.
    private func draw(sparklesAt tick: Int, in context: inout GraphicsContext, size: CGSize) {
        for index in 0..<sparkles {
            let x = (CosmicArt.hash(index, 1, 301) * size.width / cell).rounded(.down) * cell
            let y = (CosmicArt.hash(index, 2, 301) * size.height / cell).rounded(.down) * cell
            // Keep them off the planet, where a blinking pixel would look like a glitch.
            if planet, x > size.width * 0.66, y > size.height * 0.48 { continue }
            let phase = (tick + index * 5) % (9 + index % 7)
            guard phase < 2 else { continue }
            context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(Cosmic.ink))
            guard phase == 0 else { continue }
            for (dx, dy) in [(-1.0, 0.0), (1, 0), (0, -1), (0, 1)] {
                context.fill(Path(CGRect(x: x + dx * cell, y: y + dy * cell, width: cell, height: cell)), with: .color(Cosmic.muted))
            }
        }
    }
}

/// The strip across the top of a panel: the logo on the left, a label for the current screen on the right.
struct PixelTitleStrip: View {
    let label: String

    var body: some View {
        HStack {
            LogoView(height: 15, color: Cosmic.void)
            Spacer()
            Text(label)
                .font(Cosmic.font(12, .bold))
                .tracking(2)
                .foregroundStyle(Cosmic.void)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Cosmic.ink)
    }
}

/// A hard-edged card with a title strip and an offset dither glow behind it.
struct PixelPanel<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PixelTitleStrip(label: label)

            content.padding(28)
        }
        .background(Cosmic.void)
        .overlay(Rectangle().strokeBorder(Cosmic.ink, lineWidth: 2))
        .background {
            if let tile = CosmicArt.glowTile {
                Image(decorative: tile, scale: 2)
                    .interpolation(.none)
                    .resizable(resizingMode: .tile)
                    .offset(x: 12, y: 12)
            }
        }
    }
}

/// A rectangle with each corner stepped in by one "pixel".
struct NotchedRectangle: Shape {
    var notch = Cosmic.cell

    func path(in rect: CGRect) -> Path {
        let n = notch
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + n, y: rect.minY))
        for point in [
            CGPoint(x: rect.maxX - n, y: rect.minY), CGPoint(x: rect.maxX - n, y: rect.minY + n),
            CGPoint(x: rect.maxX, y: rect.minY + n), CGPoint(x: rect.maxX, y: rect.maxY - n),
            CGPoint(x: rect.maxX - n, y: rect.maxY - n), CGPoint(x: rect.maxX - n, y: rect.maxY),
            CGPoint(x: rect.minX + n, y: rect.maxY), CGPoint(x: rect.minX + n, y: rect.maxY - n),
            CGPoint(x: rect.minX, y: rect.maxY - n), CGPoint(x: rect.minX, y: rect.minY + n),
            CGPoint(x: rect.minX + n, y: rect.minY + n),
        ] {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

/// Uppercase monospaced buttons with stepped corners. The primary one is filled; pressing inverts either.
struct PixelButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        PixelButton(configuration: configuration, primary: primary)
    }

    // A separate view, because a button style can't read the environment itself.
    private struct PixelButton: View {
        let configuration: Configuration
        let primary: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let filled = primary != configuration.isPressed
            configuration.label
                .font(Cosmic.font(12, .bold))
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundStyle(filled ? Cosmic.void : Cosmic.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(NotchedRectangle().fill(filled ? Cosmic.ink : Cosmic.void))
                .overlay(NotchedRectangle().stroke(Cosmic.ink, lineWidth: 2))
                .opacity(isEnabled ? 1 : 0.35)
                .contentShape(Rectangle())
        }
    }
}

/// A dotted horizontal rule.
struct PixelDivider: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: proxy.size.width, y: 1))
            }
            .stroke(Cosmic.dim, style: StrokeStyle(lineWidth: 2, dash: [Cosmic.cell, Cosmic.cell]))
        }
        .frame(height: 2)
    }
}
